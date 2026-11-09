--!nonstrict
-- Griphub community widget. Credentials are read only from the token plugin setting,
-- sent only as an HTTP header, and never included in UI, URLs, notifications, or
-- process arguments.
local Controller = require("./widget_controller.luau")
local PORTAL = Controller.PORTAL_URL

local controller = Controller.new({
  host = {
    getConfig = function(_, key) return noctalia.getConfig(key) end,
    setUpdateInterval = function(_, milliseconds) noctalia.setUpdateInterval(milliseconds) end,
    render = function(_, state)
      barWidget.setGlyph(state.glyph)
      barWidget.setText(state.text)
      barWidget.setTooltip(state.hover)
    end,
    decode = function(_, body) return noctalia.json.decode(body) end,
  },
  http = function(request, callback) return noctalia.http(request, callback) end,
  notify = function(title, body) noctalia.notify(title, body) end,
  openPortal = function(url)
    -- The URL is a fixed constant; argv form avoids shell interpolation.
    noctalia.runAsync({ "xdg-open", url })
  end,
})

function update()
  controller:tick()
end

function onConfigChanged()
  controller:onConfigChanged()
end

function onClick()
  controller:click()
end

controller:start()
