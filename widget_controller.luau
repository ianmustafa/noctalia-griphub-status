local M = {}

local PORTAL_URL = "https://griphubrouter.web.id/portal"
local PRIMARY_URL = "https://griphubrouter.web.id/api/user-usage"
local FALLBACK_URL = "https://griphubrouter.web.id/v1/credits"

local function finite(value)
  local n = tonumber(value)
  if n == nil or n ~= n or n == math.huge or n == -math.huge then return nil end
  return n
end
local function trim(value) return tostring(value or ""):match("^%s*(.-)%s*$") end
local function getConfig(host, key)
  if type(host.getConfig) == "function" then return host:getConfig(key) end
  return nil
end
local function exactBalance(value) return tostring(value) end
local function rounded(value, precision)
  local factor = 10 ^ precision
  local result = math.floor(math.abs(value) * factor + 0.5) / factor
  if value < 0 then result = -result end
  return result == 0 and 0 or result
end
local function fixedBalance(value, precision)
  return string.format("%." .. tostring(precision) .. "f", rounded(value, precision))
end
local function displayBalance(value, precision)
  local magnitude = math.abs(value)
  if magnitude < 1000 then return fixedBalance(value, precision) end
  local suffixes = { "", "K", "M", "B", "T" }
  local index, divisor = 1, 1
  while index < #suffixes and magnitude >= divisor * 1000 do
    divisor, index = divisor * 1000, index + 1
  end
  return fixedBalance(value / divisor, precision) .. suffixes[index]
end
local function parseExpiry(value)
  if value == nil or value == "" then return nil, true end
  local numeric = finite(value)
  if numeric ~= nil then return numeric, true end
  if type(value) ~= "string" then return nil, false end
  local year, month, day, hour, minute, second = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)")
  if not year then return nil, false end
  local localEpoch = os.time({ year = tonumber(year), month = tonumber(month), day = tonumber(day),
    hour = tonumber(hour), min = tonumber(minute), sec = tonumber(second), isdst = false })
  if localEpoch == nil then return nil, false end
  local utcEpoch = os.time(os.date("!*t", localEpoch))
  if utcEpoch == nil then return nil, false end
  return localEpoch + os.difftime(localEpoch, utcEpoch), true
end
local function localTime(host, epoch)
  if type(host.formatLocalTime) == "function" then
    local ok, value = pcall(function() return host.formatLocalTime(epoch) end)
    if ok and value ~= nil then return tostring(value) end
  end
  return os.date("%Y-%m-%d %H:%M:%S", epoch)
end
local function humanizeReason(value)
  local reason = trim(value)
  if reason == "" then return "Reason unavailable" end
  reason = reason:gsub("[_%-]+", " "):gsub("%s+", " ")
  return reason:gsub("^%l", string.upper)
end
local function batchIdentity(batch, amount, rawExpiry)
  -- The observed payload has no batch id; these fields form its stable identity.
  return table.concat({ tostring(amount), tostring(batch.receivedAt or ""), tostring(rawExpiry or ""),
    tostring(batch.reason or "") }, "\31")
end
local function activeBatches(account, now, host)
  local result, source, seen = {}, account and account.batches, {}
  if type(source) ~= "table" then return result end
  now = finite(now) or os.time()
  for index, batch in ipairs(source) do
    if type(batch) == "table" then
      local amount = finite(batch.credits or batch.amount)
      local rawExpiry = batch.expiresAt
      if rawExpiry == nil then rawExpiry = batch.expires_at end
      if rawExpiry == nil then rawExpiry = batch.expiry end
      local expiry, validExpiry = parseExpiry(rawExpiry)
      local identity = amount ~= nil and batchIdentity(batch, amount, rawExpiry) or nil
      if amount ~= nil and amount > 0 and validExpiry and (expiry == nil or expiry > now) and not seen[identity] then
        seen[identity] = true
        result[#result + 1] = { amount = amount, expiry = expiry, reason = humanizeReason(batch.reason), order = index }
      end
    end
  end
  table.sort(result, function(left, right)
    if left.expiry == nil then return right.expiry ~= nil end
    if right.expiry == nil then return false end
    if left.expiry == right.expiry then return left.order < right.order end
    return left.expiry < right.expiry
  end)
  return result
end
local function breakdownText(batches, host)
  if type(batches) ~= "table" or #batches == 0 then return nil end
  local lines = { "Active batches:" }
  for _, batch in ipairs(batches) do
    local expiry = batch.expiry == nil and "No expiry reported" or "expires " .. localTime(host, batch.expiry)
    lines[#lines + 1] = "- " .. exactBalance(batch.amount) .. " credits; " .. expiry .. "; reason " .. batch.reason
  end
  return table.concat(lines, "\n")
end
local function appendBreakdown(hover, batches, host)
  local details = breakdownText(batches, host)
  return details == nil and hover or hover .. "\n" .. details
end
local function stateView(state)
  local text = state.text or "—"
  return { text = text, bar = text, glyph = state.glyph, hover = state.hover,
    hoverText = state.hover, status = state.status, remaining = state.remaining,
    stale = state.stale == true, failureClass = state.failureClass,
    lastSuccessAt = state.lastSuccessAt, lastSuccessTime = state.lastSuccessAt,
    suspended = state.suspended == true, suspendedUntil = state.suspendedUntil,
    batches = state.batches }
end

function M.new(adapters)
  adapters = adapters or {}
  local host = adapters.host or {}
  local notify = adapters.notify
  local openPortal = adapters.openPortal
  local http = adapters.http
  local clock = adapters.now
  local self = { host = host, notify = notify, openPortal = openPortal, http = http,
    inFlight = false, generation = 0, warningSent = false, endpoint = nil, configuration = nil,
    state = { status = "unconfigured", text = "—", glyph = "lightning", hover = "Token not configured",
      remaining = nil, batches = {}, stale = false, failureClass = nil, lastSuccessAt = nil, suspended = false, suspendedUntil = nil } }

  function self:now()
    local value
    if type(clock) == "function" then
      local ok, result = pcall(clock)
      if ok then value = result end
    return value ~= nil and value or os.time()
  end
  end
  function self:setNeutral(status, hover)
    self.state.status, self.state.text, self.state.bar = status, "—", "—"
    self.state.remaining, self.state.hover, self.state.stale, self.state.failureClass = nil, hover, false, nil
    self.state.lastSuccessAt, self.state.suspended, self.state.suspendedUntil = nil, false, nil
    self.state.batches = {}
    self:render()
  end
  function self:setSuccess(balance, precision, account)
    account = account or {}
    self.state.status = account.suspended == true and "suspended" or "success"
    self.state.remaining = balance
    self.state.text, self.state.bar = displayBalance(balance, precision), displayBalance(balance, precision)
    self.state.lastSuccessAt, self.state.stale, self.state.failureClass = self:now(), false, nil
    self.state.suspended, self.state.suspendedUntil = account.suspended == true, account.suspendedUntil
    self.state.batches = activeBatches(account, self:now(), host)
    self.state.hover = exactBalance(balance)
    if self.state.suspended then
      self.state.hover = self.state.hover .. " (Suspended"
      if self.state.suspendedUntil ~= nil then self.state.hover = self.state.hover .. "; suspendedUntil " .. tostring(self.state.suspendedUntil) end
      self.state.hover = self.state.hover .. ")"
    end
    self.state.hover = appendBreakdown(self.state.hover, self.state.batches, host)
    self:render()
  end
  function self:setFailure(status, message)
    local known = self.state.remaining
    self.state.status, self.state.stale, self.state.failureClass = status, known ~= nil, status
    if known == nil then
      self.state.text, self.state.bar, self.state.hover = "—", "—", message
    else
      self.state.hover = exactBalance(known) .. " (" .. message
      if self.state.lastSuccessAt ~= nil then self.state.hover = self.state.hover .. "; last successful at " .. tostring(self.state.lastSuccessAt) end
      self.state.hover = self.state.hover .. ")"
      self.state.hover = appendBreakdown(self.state.hover, self.state.batches, host)
    end
    self:render()
  end

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
  function self:decode(response)
    local body = response and response.body
    if type(body) == "table" then return body end
    if type(host.decode) ~= "function" or type(body) ~= "string" then return nil end
    local ok, decoded = pcall(function() return host:decode(body) end)
    if ok and type(decoded) == "table" then return decoded end
    return nil
  end
  function self:applyResponse(response, precision, endpoint)
    local status = response and tonumber(response.status)
    if status == 401 or status == 403 then
      self:setFailure("authentication_failed", "Authentication failed")
      return "complete"
    end
    if status == 404 or status == 405 or status == 501 then
      self:setFailure("unsupported", "Unsupported response")
      return "unsupported"
    end
    if status == 429 then
      self:setFailure("rate_limited", "Rate limited")
      return "complete"
    end
    if response == nil or response.ok == false or (status ~= nil and (status < 200 or status >= 300)) then
      self:setFailure("service_unavailable", "Service unavailable")
      return "complete"
    end
    local payload = self:decode(response)
    local account = payload and payload.account
    local balance
    if endpoint == FALLBACK_URL then
      local fallbackBalance = payload and payload.balance
      balance = type(fallbackBalance) == "table" and finite(fallbackBalance.remaining) or nil
    else
      balance = type(account) == "table" and finite(account.creditsBalance) or nil
    end
    if balance == nil and type(account) == "table" and account.suspended == true and self.state.remaining ~= nil then
      balance = self.state.remaining
    end
    if balance == nil then
      self:setFailure("malformed", "Invalid response")
      return "complete"
    end
    if type(account) ~= "table" then account = {} end
    self.endpoint = endpoint
    self:setSuccess(balance, precision, account)
    return "complete"
  end
  function self:request(token, generation, endpoint, attempted)
    attempted = attempted or { [endpoint] = true }
    local request = { url = endpoint, method = "GET",
      headers = { "Authorization: Bearer " .. token, "Accept: application/json" } }
    local function completed(response)
      if generation ~= self.generation then return end
      local _, _, precision = self:config()
      local outcome = self:applyResponse(response, precision, endpoint)
      if outcome == "unsupported" then
        local alternate = endpoint == PRIMARY_URL and FALLBACK_URL or PRIMARY_URL
        if not attempted[alternate] then
          attempted[alternate] = true
          self:request(token, generation, alternate, attempted)
          return
        end
      end
      self.inFlight = false
    end
    local accepted
    if type(http) == "function" then accepted = http(request, completed)
    elseif type(http) == "table" and type(http.request) == "function" then accepted = http:request(request, completed) end
    if accepted == false then completed({ ok = false, status = 0 }) end
  end
  function self:refresh()
    local token, interval, precision, glyph = self:config()
    local configuration = table.concat({ token, tostring(interval), tostring(precision), glyph }, "\0")
    if self.configuration ~= configuration then
      self.configuration = configuration
      self.endpoint = nil
      self.inFlight = false
      self.generation = self.generation + 1
    end
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
    self:request(token, self.generation, self.endpoint or PRIMARY_URL)
  end
  function self:start() return self:refresh() end
  function self:tick() return self:refresh() end
  function self:onConfigChanged()
    self.inFlight = false
    self.generation = self.generation + 1
    return self:refresh()
  end
  function self:click() if type(openPortal) == "function" then openPortal(PORTAL_URL) end end
  function self:getState() return stateView(self.state) end
  return self
end
M.PORTAL_URL, M.PRIMARY_URL = PORTAL_URL, PRIMARY_URL
M.FALLBACK_URL = FALLBACK_URL
return M
