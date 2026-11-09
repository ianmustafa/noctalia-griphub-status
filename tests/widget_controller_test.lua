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
callbacks[2]({ ok = true, status = 200, body = { account = { creditsBalance = 32.55458 } } })
assertEqual(controller:getState().status, "success", "valid primary response succeeds")
assertEqual(controller:getState().remaining, 32.55458, "primary balance is normalized")
assertEqual(controller:getState().text, "32.6", "bar uses configured precision")
assertEqual(controller:getState().hover, "32.55458", "hover keeps exact balance")

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

local function failureController(token)
  local failureConfig = { token = token, refresh_seconds = 30, precision = 1, glyph = "lightning" }
  local failureCallbacks, failureRenders = {}, {}
  local failure = Controller.new({
    host = {
      getConfig = function(_, key) return failureConfig[key] end,
      render = function(_, state) failureRenders[#failureRenders + 1] = state end,
    },
    http = function(_, callback)
      failureCallbacks[#failureCallbacks + 1] = callback
      return true
    end,
  })
  return failure, failureCallbacks, failureRenders
end

local malformed, malformedCallbacks, malformedRenders = failureController("malformed-secret")
malformed:start()
malformedCallbacks[1]({ ok = true, status = 200, body = { account = { creditsBalance = "not-a-number" }, leaked = "response-secret" } })
assertEqual(malformed:getState().status, "malformed", "malformed response is classified")
assertEqual(malformed:getState().remaining, nil, "malformed response does not fabricate balance")
assertEqual(malformed:getState().hover, "Invalid response", "malformed response is user-safe")
assertEqual(malformedRenders[#malformedRenders].hover:find("response%-secret", 1, false), nil, "response content is not rendered")

local auth, authCallbacks, authRenders = failureController("auth-secret")
auth:start()
authCallbacks[1]({ ok = false, status = 401, body = "auth-secret response body" })
assertEqual(auth:getState().status, "authentication_failed", "authentication failure is classified")
assertEqual(auth:getState().hover, "Authentication failed", "authentication failure is user-safe")
assertEqual(authRenders[#authRenders].hover:find("auth%-secret", 1, false), nil, "credential is not rendered after auth failure")

local unsupported, unsupportedCallbacks = failureController("unsupported-secret")
unsupported:start()
unsupportedCallbacks[1]({ ok = false, status = 404, body = "unsupported-secret response body" })
assertEqual(unsupported:getState().status, "unsupported", "unsupported response is classified")
assertEqual(unsupported:getState().hover, "Unsupported response", "unsupported response is user-safe")

print("widget controller tests passed")
-- An unsupported primary contract probes the fallback exactly once and caches it.
local fallbackRequests, fallbackCallbacks = {}, {}
local fallback = Controller.new({
  host = {
    getConfig = function(_, key) return ({ token = "fallback-secret", refresh_seconds = 30, precision = 1, glyph = "lightning" })[key] end,
    render = function() end,
  },
  http = function(request, callback)
    fallbackRequests[#fallbackRequests + 1] = request
    fallbackCallbacks[#fallbackCallbacks + 1] = callback
    return true
  end,
})
fallback:start()
assertEqual(#fallbackRequests, 1, "fallback starts with primary request")
fallbackCallbacks[1]({ ok = false, status = 404, body = "unsupported primary" })
assertEqual(#fallbackRequests, 2, "unsupported primary requests fallback once")
assertEqual(fallbackRequests[2].url, "https://griphubrouter.web.id/v1/credits", "fallback endpoint")
fallbackCallbacks[2]({ ok = true, status = 200, body = { balance = { remaining = 32.55458 } } })
assertEqual(fallback:getState().status, "success", "fallback response succeeds")
assertEqual(fallback:getState().remaining, 32.55458, "fallback balance is normalized")
assertEqual(fallback:getState().text, "32.6", "fallback balance uses primary rendering")
assertEqual(fallback:getState().hover, "32.55458", "fallback hover keeps exact balance")
fallback:tick()
assertEqual(#fallbackRequests, 3, "cached fallback contract refreshes directly")
assertEqual(fallbackRequests[3].url, "https://griphubrouter.web.id/v1/credits", "cached fallback endpoint")
fallbackCallbacks[3]({ ok = true, status = 200, body = { balance = { remaining = 31.5 } } })
assertEqual(fallback:getState().remaining, 31.5, "cached fallback refresh updates balance")

-- A malformed fallback payload is terminal and does not probe either contract again.
local badFallbackRequests, badFallbackCallbacks = {}, {}
local badFallback = Controller.new({
  host = {
    getConfig = function(_, key) return ({ token = "bad-fallback-secret", refresh_seconds = 30, precision = 1, glyph = "lightning" })[key] end,
    render = function() end,
  },
  http = function(request, callback)
    badFallbackRequests[#badFallbackRequests + 1] = request
    badFallbackCallbacks[#badFallbackCallbacks + 1] = callback
    return true
  end,
})
badFallback:start()
badFallbackCallbacks[1]({ ok = false, status = 404 })
badFallbackCallbacks[2]({ ok = true, status = 200, body = { balance = { remaining = "not-a-number" } } })
assertEqual(#badFallbackRequests, 2, "malformed fallback does not probe again")
assertEqual(badFallback:getState().status, "malformed", "malformed fallback is classified")

-- An unsupported fallback response does not loop or probe a third endpoint.
local unsupportedFallbackRequests, unsupportedFallbackCallbacks = {}, {}
local unsupportedFallback = Controller.new({
  host = {
    getConfig = function(_, key) return ({ token = "unsupported-fallback-secret", refresh_seconds = 30, precision = 1, glyph = "lightning" })[key] end,
    render = function() end,
  },
  http = function(request, callback)
    unsupportedFallbackRequests[#unsupportedFallbackRequests + 1] = request
    unsupportedFallbackCallbacks[#unsupportedFallbackCallbacks + 1] = callback
    return true
  end,
})
unsupportedFallback:start()
unsupportedFallbackCallbacks[1]({ ok = false, status = 404 })
unsupportedFallbackCallbacks[2]({ ok = false, status = 404 })
assertEqual(#unsupportedFallbackRequests, 2, "unsupported fallback does not loop")
assertEqual(unsupportedFallback:getState().status, "unsupported", "unsupported fallback is classified")

-- Only an explicitly unsupported primary response may trigger fallback.
local function assertNoFallback(status, body, expectedStatus)
  local requestsForCase, callbacksForCase = {}, {}
  local case = Controller.new({
    host = {
      getConfig = function(_, key) return ({ token = "failure-secret", refresh_seconds = 30, precision = 1, glyph = "lightning" })[key] end,
      render = function() end,
    },
    http = function(request, callback)
      requestsForCase[#requestsForCase + 1] = request
      callbacksForCase[#callbacksForCase + 1] = callback
      return true
    end,
  })
  case:start()
  callbacksForCase[1]({ ok = status == 200, status = status, body = body })
  assertEqual(#requestsForCase, 1, "non-unsupported primary does not probe fallback")
  assertEqual(case:getState().status, expectedStatus, "primary failure classification")
end
assertNoFallback(401, "auth response", "authentication_failed")
assertNoFallback(429, "rate response", "service_unavailable")
assertNoFallback(500, "server response", "service_unavailable")
assertNoFallback(0, "network response", "service_unavailable")
assertNoFallback(200, { account = { creditsBalance = "not-a-number" } }, "malformed")

print("fallback behavior tests passed")
