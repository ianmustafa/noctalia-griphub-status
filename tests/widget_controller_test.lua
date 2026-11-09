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
-- Clearing a token invalidates the in-flight generation and returns to neutral.
local clearedConfig = { token = "clear-secret", refresh_seconds = 30, precision = 1, glyph = "lightning" }
local clearedCallbacks = {}
local cleared = Controller.new({
  host = {
    getConfig = function(_, key) return clearedConfig[key] end,
    render = function() end,
  },
  http = function(_, callback)
    clearedCallbacks[#clearedCallbacks + 1] = callback
    return true
  end,
})
cleared:start()
clearedConfig.token = ""
cleared:onConfigChanged()
clearedCallbacks[1]({ ok = true, status = 200, body = { account = { creditsBalance = 99 } } })
assertEqual(cleared:getState().status, "unconfigured", "clearing token stays neutral after a late response")
assertEqual(cleared:getState().remaining, nil, "clearing token discards the old generation balance")

-- Changing credentials renegotiates the primary contract rather than reusing a prior fallback.
local credentialConfig = { token = "first-secret", refresh_seconds = 30, precision = 1, glyph = "lightning" }
local credentialRequests, credentialCallbacks = {}, {}
local credential = Controller.new({
  host = {
    getConfig = function(_, key) return credentialConfig[key] end,
    render = function() end,
  },
  http = function(request, callback)
    credentialRequests[#credentialRequests + 1] = request
    credentialCallbacks[#credentialCallbacks + 1] = callback
    return true
  end,
})
credential:start()
credentialCallbacks[1]({ ok = false, status = 404 })
credentialCallbacks[2]({ ok = true, status = 200, body = { balance = { remaining = 4 } } })
credentialConfig.token = "second-secret"
credential:onConfigChanged()
assertEqual(credentialRequests[3].url, "https://griphubrouter.web.id/api/user-usage", "new credentials start primary negotiation")
credentialCallbacks[3]({ ok = true, status = 200, body = { account = { creditsBalance = 5 } } })
assertEqual(credential:getState().remaining, 5, "new credentials accept the primary response")

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
local function requestController(token, requestsForCase, callbacksForCase)
  return Controller.new({
    host = {
      getConfig = function(_, key) return ({ token = token, refresh_seconds = 30, precision = 1, glyph = "lightning" })[key] end,
      render = function() end,
    },
    http = function(request, callback)
      requestsForCase[#requestsForCase + 1] = request
      callbacksForCase[#callbacksForCase + 1] = callback
      return true
    end,
  })
end

-- An unsupported primary contract probes the fallback exactly once and caches it.
local fallbackRequests, fallbackCallbacks = {}, {}
local fallback = requestController("fallback-secret", fallbackRequests, fallbackCallbacks)
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
local badFallback = requestController("bad-fallback-secret", badFallbackRequests, badFallbackCallbacks)
badFallback:start()
badFallbackCallbacks[1]({ ok = false, status = 404 })
badFallbackCallbacks[2]({ ok = true, status = 200, body = { balance = { remaining = "not-a-number" } } })
assertEqual(#badFallbackRequests, 2, "malformed fallback does not probe again")
assertEqual(badFallback:getState().status, "malformed", "malformed fallback is classified")

-- An unsupported fallback response does not loop or probe a third endpoint.
local unsupportedFallbackRequests, unsupportedFallbackCallbacks = {}, {}
local unsupportedFallback = requestController("unsupported-fallback-secret", unsupportedFallbackRequests, unsupportedFallbackCallbacks)
unsupportedFallback:start()
unsupportedFallbackCallbacks[1]({ ok = false, status = 404 })
unsupportedFallbackCallbacks[2]({ ok = false, status = 404 })
assertEqual(#unsupportedFallbackRequests, 2, "unsupported fallback does not loop")
assertEqual(unsupportedFallback:getState().status, "unsupported", "unsupported fallback is classified")

-- Only an explicitly unsupported primary response may trigger fallback.
local function assertNoFallback(status, body, expectedStatus)
  local requestsForCase, callbacksForCase = {}, {}
  local case = requestController("failure-secret", requestsForCase, callbacksForCase)
  case:start()
  callbacksForCase[1]({ ok = status == 200, status = status, body = body })
  assertEqual(#requestsForCase, 1, "non-unsupported primary does not probe fallback")
  assertEqual(case:getState().status, expectedStatus, "primary failure classification")
end
assertNoFallback(401, "auth response", "authentication_failed")
assertNoFallback(429, "rate response", "rate_limited")
assertNoFallback(500, "server response", "service_unavailable")
assertNoFallback(0, "network response", "service_unavailable")
assertNoFallback(200, { account = { creditsBalance = "not-a-number" } }, "malformed")

print("fallback behavior tests passed")
-- Refresh failures retain the last successful value, expose freshness metadata, and recover.
local lifecycleConfig = { token = "lifecycle-secret", refresh_seconds = 30, precision = 1, glyph = "lightning" }
local lifecycleRequests, lifecycleCallbacks, lifecycleRenders = {}, {}, {}
local now = 100
local lifecycle = Controller.new({
  host = {
    getConfig = function(_, key) return lifecycleConfig[key] end,
    setUpdateInterval = function(_, milliseconds) interval = milliseconds end,
    render = function(_, state) lifecycleRenders[#lifecycleRenders + 1] = state end,
  },
  now = function() return now end,
  http = function(request, callback)
    lifecycleRequests[#lifecycleRequests + 1] = request
    lifecycleCallbacks[#lifecycleCallbacks + 1] = callback
    return true
  end,
})
lifecycle:start()
assertEqual(#lifecycleRequests, 1, "startup fetch is immediate")
lifecycleCallbacks[1]({ ok = true, status = 200, body = { account = { creditsBalance = 12.25 } } })
assertEqual(lifecycle:getState().status, "success", "successful lifecycle fetch")
assertEqual(lifecycle:getState().lastSuccessAt, 100, "success timestamp is retained")
now = 125
lifecycle:tick()
assertEqual(#lifecycleRequests, 2, "scheduled tick starts next fetch")
lifecycle:tick()
assertEqual(#lifecycleRequests, 2, "in-flight ticks are skipped")
lifecycleCallbacks[2]({ ok = false, status = 503 })
local stale = lifecycle:getState()
assertEqual(stale.status, "service_unavailable", "server failure is classified")
assertEqual(stale.remaining, 12.25, "failure retains last balance")
assertEqual(stale.stale, true, "failure marks retained balance stale")
assertEqual(stale.lastSuccessAt, 100, "failure retains last success time")
assertTrue(stale.hover:find("Service unavailable", 1, true) ~= nil, "failure class is shown")
assertTrue(stale.hover:find("100", 1, true) ~= nil, "last success time is shown")
now = 150
lifecycle:tick()
assertEqual(#lifecycleRequests, 3, "failure follows normal schedule")
lifecycleCallbacks[3]({ ok = true, status = 200, body = { account = { creditsBalance = 9.5 } } })
assertEqual(lifecycle:getState().status, "success", "successful recovery clears stale state")
assertEqual(lifecycle:getState().remaining, 9.5, "recovery updates balance")
assertEqual(lifecycle:getState().lastSuccessAt, 150, "recovery updates success time")

-- Rate limiting is distinct from service failure and retains a known balance.
now = 175
lifecycle:tick()
lifecycleCallbacks[4]({ ok = false, status = 429 })
assertEqual(lifecycle:getState().status, "rate_limited", "429 is classified as rate limited")
assertEqual(lifecycle:getState().remaining, 9.5, "rate limiting retains balance")
assertTrue(lifecycle:getState().hover:find("Rate limited", 1, true) ~= nil, "rate limit class is shown")

-- A suspended account is visible without discarding its normalized balance.
local suspensionCallbacks, suspensionRequests = {}, {}
local suspension = Controller.new({
  host = {
    getConfig = function(_, key) return ({ token = "suspension-secret", refresh_seconds = 30, precision = 1, glyph = "lightning" })[key] end,
    render = function() end,
  },
  now = function() return 200 end,
  http = function(request, callback)
    suspensionRequests[#suspensionRequests + 1] = request
    suspensionCallbacks[#suspensionCallbacks + 1] = callback
    return true
  end,
})
suspension:start()
suspensionCallbacks[1]({ ok = true, status = 200, body = { account = { creditsBalance = 4.25, suspended = true, suspendedUntil = "2026-12-01T00:00:00Z" } } })
local suspended = suspension:getState()
assertEqual(suspended.status, "suspended", "suspension is classified")
assertEqual(suspended.remaining, 4.25, "suspension preserves balance")
assertEqual(suspended.suspended, true, "suspension is exposed")
assertEqual(suspended.suspendedUntil, "2026-12-01T00:00:00Z", "suspension end is exposed")
assertTrue(suspended.hover:find("2026-12-01T00:00:00Z", 1, true) ~= nil, "suspension end is shown")

-- A failure before any successful response remains neutral instead of fabricating zero.
local neutralCallbacks = {}
local neutral = Controller.new({
  host = {
    getConfig = function(_, key) return ({ token = "neutral-secret", refresh_seconds = 30, precision = 1, glyph = "lightning" })[key] end,
    render = function() end,
  },
  http = function(_, callback) neutralCallbacks[#neutralCallbacks + 1] = callback; return true end,
})
neutral:start()
neutralCallbacks[1]({ ok = false, status = 500 })
assertEqual(neutral:getState().remaining, nil, "failed first fetch has no balance")
assertEqual(neutral:getState().text, "—", "failed first fetch stays neutral")

print("refresh lifecycle tests passed")
-- Balance formatting and active-batch tooltip boundaries use the controller seam.
local function presentation(value, precision, account, clock, localTime)
  local callbacksForCase = {}
  local settings = { token = "presentation-secret", refresh_seconds = 30, precision = precision, glyph = "star" }
  local case = Controller.new({
    host = {
      getConfig = function(_, key) return settings[key] end,
      render = function() end,
      formatLocalTime = localTime,
    },
    now = clock,
    http = function(_, callback) callbacksForCase[#callbacksForCase + 1] = callback; return true end,
  })
  case:start()
  callbacksForCase[1]({ ok = true, status = 200, body = { account = account or { creditsBalance = value } } })
  return case:getState()
end

assertEqual(presentation(999.94, 1).text, "999.9", "values below one thousand use fixed point")
assertEqual(presentation(1000, 1).text, "1.0K", "thousand compact threshold")
assertEqual(presentation(1000000, 0).text, "1M", "million compact threshold and precision")
assertEqual(presentation(1234567890, 4).text, "1.2346B", "billions use selected precision")
assertEqual(presentation(999.95, 1).text, "1000.0", "ordinary rounding below compact threshold")
assertEqual(presentation(32.55458, 4).hover, "32.55458", "hover keeps exact un-compacted balance")

local batches = {
  { credits = 5, receivedAt = "promo", expiresAt = 200, reason = "promo_code_bonus" },
  { credits = 4, receivedAt = "expired", expiresAt = 100, reason = "expired" },
  { credits = 3, receivedAt = "next", expiresAt = 101, reason = "next_up" },
  { credits = 3, receivedAt = "next", expiresAt = 101, reason = "next_up" },
  { credits = 2, reason = nil },
  { credits = 0, expiresAt = 300, reason = "zero" },
  { credits = -1, expiresAt = 300, reason = "negative" },
  { credits = "invalid", expiresAt = 300, reason = "malformed" },
  { credits = 7, expiresAt = 100, reason = "boundary" },
  { credits = 6, expiresAt = "invalid", reason = "bad expiry" },
}
local batchState = presentation(12.25, 1, { creditsBalance = 12.25, batches = batches }, function() return 100 end,
  function(epoch) return "LOCAL(" .. tostring(epoch) .. ")" end)
assertTrue(batchState.hover:find("Active batches:", 1, true) ~= nil, "active breakdown heading")
assertTrue(batchState.hover:find("3 credits; expires LOCAL(101); reason Next up", 1, true) ~= nil, "earliest active expiry first")
assertEqual(select(2, batchState.hover:gsub("3 credits; expires LOCAL%(101%); reason Next up", "")), 1, "duplicate batch identity is shown once")
assertTrue(batchState.hover:find("5 credits; expires LOCAL(200); reason Promo code bonus", 1, true) ~= nil, "reason and local expiry formatting")
assertTrue(batchState.hover:find("2 credits; No expiry reported; reason Reason unavailable", 1, true) ~= nil, "missing expiry and reason labels")
assertEqual(batchState.hover:find("expired", 1, true), nil, "expired and boundary rows omitted")
assertEqual(batchState.hover:find("zero", 1, true), nil, "zero rows omitted")
assertEqual(batchState.hover:find("negative", 1, true), nil, "negative rows omitted")
assertEqual(batchState.hover:find("malformed", 1, true), nil, "malformed rows omitted")
assertEqual(batchState.hover:find("bad expiry", 1, true), nil, "invalid expiry rows omitted")

local emptyBatchState = presentation(4, 1, { creditsBalance = 4, batches = {
  { credits = 0, expiresAt = 200 }, { credits = -2 }, { credits = 1, expiresAt = 50 },
} }, function() return 100 end)
assertEqual(emptyBatchState.hover:find("Active batches:", 1, true), nil, "empty active breakdown omitted")
print("formatting and batch tests passed")
