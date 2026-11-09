local function assertEqual(actual, expected, message)
  if actual ~= expected then error((message or "values differ") .. ": got " .. tostring(actual) .. ", expected " .. tostring(expected), 2) end
end
local function assertTrue(value, message) assertEqual(value, true, message) end

package.path = "./?.lua;./?.luau;" .. package.path
local Controller = require("widget_controller")
local config = { token = "", refresh_seconds = 30, precision = 1, glyph = "lightning" }
local requests, callbacks, notifications, portals, renders = {}, {}, {}, {}, {}
local interval
local host = {
  getConfig = function(_, key) return config[key] end,
  setUpdateInterval = function(_, milliseconds) interval = milliseconds end,
  render = function(_, state) renders[#renders + 1] = state end,
}
local http = function(request, callback)
  requests[#requests + 1] = request
  callbacks[#callbacks + 1] = callback
  return true
end
local controller = Controller.new({
  host = host,
  http = http,
  notify = function(title, body) notifications[#notifications + 1] = { title = title, body = body } end,
  openPortal = function(url) portals[#portals + 1] = url end,
})

-- An absent token is neutral and does not infer a zero balance or make a request.
controller:start()
assertEqual(renders[#renders].text, "—", "missing token is neutral")
assertEqual(renders[#renders].remaining, nil, "missing token has no balance")
assertEqual(renders[#renders].hover, "Token not configured", "missing token tooltip")
assertEqual(#requests, 0, "missing token does not request")

-- Portal opening is fixed and credential-free.
controller:click()
assertEqual(portals[1], "https://griphubrouter.web.id/portal", "portal URL")
assertEqual(#portals, 1, "one portal action")
assertEqual(portals[1]:find("?", 1, true), nil, "portal has no query")
assertEqual(portals[1]:find("#", 1, true), nil, "portal has no fragment")

-- Configured operation uses injected HTTP and keeps credentials out of every UI surface.
config.token = "secret-token"
controller:onConfigChanged()
assertEqual(#requests, 1, "configured token requests")
assertEqual(requests[1].url, "https://griphubrouter.web.id/api/user-usage", "primary endpoint")
assertEqual(requests[1].headers[1], "Authorization: Bearer secret-token", "auth header")
assertTrue(not requests[1].url:find("secret-token", 1, true), "token absent from URL")
assertEqual(renders[#renders].text:find("secret%-token", 1, false), nil, "token absent from widget")
assertEqual(renders[#renders].hover:find("secret%-token", 1, false), nil, "token absent from hover")

-- In-flight requests do not overlap; a late response from an old generation is ignored.
controller:tick()
assertEqual(#requests, 1, "tick skips in-flight request")
controller:onConfigChanged()
assertEqual(#requests, 2, "config change starts a new generation")
callbacks[1]({ ok = true, status = 200, body = "secret-token" })
assertEqual(controller:getState().status, "loading", "stale response does not commit")
callbacks[2]({ ok = true, status = 200, body = "secret-token" })
assertEqual(controller:getState().status, "loading", "response body is not rendered")

-- Bounds, glyph default, and one-time low-interval warning are deterministic.
config.refresh_seconds = 86401
config.precision = 9
config.glyph = ""
controller:onConfigChanged()
assertEqual(interval, 86400000, "interval is capped at one day")
assertEqual(controller:getState().glyph, "lightning", "empty glyph uses lightning")
config.refresh_seconds = 0
controller:onConfigChanged()
assertEqual(interval, 1000, "interval is bounded at one second")
assertEqual(#notifications, 1, "low interval warning is emitted once")
controller:tick()
assertEqual(#notifications, 1, "low interval warning is deduplicated")

for _, render in ipairs(renders) do
  assertEqual(render.text:find("secret%-token", 1, false), nil, "token absent from captured widget output")
  assertEqual(render.hover:find("secret%-token", 1, false), nil, "token absent from captured hover output")
end
for _, notification in ipairs(notifications) do
  assertEqual((notification.title .. notification.body):find("secret%-token", 1, false), nil, "token absent from notification")
end

print("widget controller tests passed")
