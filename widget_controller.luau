local M = {}

local PORTAL_URL = "https://griphubrouter.web.id/portal"
local PRIMARY_URL = "https://griphubrouter.web.id/api/user-usage"

local function finite(value)
  local n = tonumber(value)
  if n == nil or n ~= n or n == math.huge or n == -math.huge then return nil end
  return n
end
local function trim(value) return tostring(value or ""):match("^%s*(.-)%s*$") end
local function getConfig(host, key)
  if type(host.getConfig) == "function" then return host:getConfig(key) end
  if type(host.config) == "function" then return host:config(key) end
  return nil
end
local function exactBalance(value) return tostring(value) end
local function displayBalance(value, precision)
  return string.format("%." .. tostring(precision) .. "f", value)
end
local function stateView(state)
  local text = state.text or "—"
  return { text = text, bar = text, glyph = state.glyph, hover = state.hover,
    hoverText = state.hover, status = state.status, remaining = state.remaining,
    stale = state.stale == true }
end

function M.new(adapters)
  adapters = adapters or {}
  local host = adapters.host or {}
  local notify = adapters.notify or adapters.notification
  local openPortal = adapters.openPortal or adapters.portal
  local http = adapters.http
  local self = { host = host, notify = notify, openPortal = openPortal, http = http,
    inFlight = false, generation = 0, warningSent = false,
    state = { status = "unconfigured", text = "—", glyph = "lightning", hover = "Token not configured" } }

  function self:config()
    local token = trim(getConfig(host, "token"))
    local interval = math.floor(finite(getConfig(host, "refresh_seconds")) or 30)
    local precision = math.floor(finite(getConfig(host, "precision")) or 1)
    local glyph = trim(getConfig(host, "glyph"))
    if interval < 1 then interval = 1 elseif interval > 86400 then interval = 86400 end
    if precision < 0 then precision = 0 elseif precision > 4 then precision = 4 end
    if glyph == "" then glyph = "lightning" end
    return token, interval, precision, glyph
  end
  function self:render()
    local snapshot = stateView(self.state)
    self.lastRender = snapshot
    if type(host.render) == "function" then host:render(snapshot) end
    if type(host.setText) == "function" then host:setText(snapshot.text) end
    if type(host.setGlyph) == "function" then host:setGlyph(snapshot.glyph) end
    if type(host.setTooltip) == "function" then host:setTooltip(snapshot.hover) end
    return snapshot
  end
  function self:setNeutral(status, hover)
    self.state.status, self.state.text, self.state.bar = status, "—", "—"
    self.state.remaining, self.state.hover, self.state.stale = nil, hover, false
    self:render()
  end
  function self:setSuccess(balance, precision)
    self.state.status, self.state.remaining = "success", balance
    self.state.text, self.state.bar = displayBalance(balance, precision), displayBalance(balance, precision)
    self.state.hover, self.state.stale = exactBalance(balance), false
    self:render()
  end
  function self:setFailure(status, message)
    local known = self.state.remaining
    self.state.status, self.state.stale = status, known ~= nil
    if known == nil then
      self.state.text, self.state.bar, self.state.hover = "—", "—", message
    else
      self.state.hover = exactBalance(known) .. " (" .. message .. ")"
    end
    self:render()
  end
  function self:decode(response)
    local body = response and response.body
    if type(body) == "table" then return body end
    if type(host.decode) ~= "function" or type(body) ~= "string" then return nil end
    local ok, decoded = pcall(function() return host:decode(body) end)
    if ok and type(decoded) == "table" then return decoded end
    return nil
  end
  function self:applyResponse(response, precision)
    local status = response and tonumber(response.status)
    if status == 401 or status == 403 then
      self:setFailure("authentication_failed", "Authentication failed")
      return
    end
    if status == 404 or status == 405 or status == 501 then
      self:setFailure("unsupported", "Unsupported response")
      return
    end
    if response == nil or response.ok == false or (status ~= nil and (status < 200 or status >= 300)) then
      self:setFailure("service_unavailable", "Service unavailable")
      return
    end
    local payload = self:decode(response)
    local account = payload and payload.account
    local balance = type(account) == "table" and finite(account.creditsBalance) or nil
    if balance == nil then
      self:setFailure("malformed", "Invalid response")
      return
    end
    self:setSuccess(balance, precision)
  end
  function self:request(token, generation)
    local request = { url = PRIMARY_URL, method = "GET",
      headers = { "Authorization: Bearer " .. token, "Accept: application/json" } }
    local function completed(response)
      if generation ~= self.generation then return end
      self.inFlight = false
      local _, _, precision = self:config()
      self:applyResponse(response, precision)
    end
    local accepted
    if type(http) == "function" then accepted = http(request, completed)
    elseif type(http) == "table" and type(http.request) == "function" then accepted = http:request(request, completed) end
    if accepted == false then completed({ ok = false, status = 0 }) end
  end
  function self:refresh()
    local token, interval, _, glyph = self:config()
    self.state.glyph = glyph
    if type(host.setUpdateInterval) == "function" then host:setUpdateInterval(interval * 1000) end
    if interval < 30 and not self.warningSent then
      self.warningSent = true
      if type(notify) == "function" then notify("GripHub status", "Refresh interval below 30 seconds may increase traffic") end
    end
    if token == "" then
      self.inFlight = false
      self:setNeutral("unconfigured", "Token not configured")
      return
    end
    if self.inFlight then return end
    self.inFlight, self.generation = true, self.generation + 1
    self.state.status = "loading"
    if self.state.remaining == nil then
      self.state.hover = "Loading"
      self.state.text, self.state.bar = "—", "—"
    end
    self:render()
    self:request(token, self.generation)
  end
  function self:start() return self:refresh() end
  function self:tick() return self:refresh() end
  function self:onConfigChanged() self.inFlight = false; return self:refresh() end
  function self:click() if type(openPortal) == "function" then openPortal(PORTAL_URL) end end
  function self:getState() return stateView(self.state) end
  return self
end
M.PORTAL_URL, M.PRIMARY_URL = PORTAL_URL, PRIMARY_URL
return M
