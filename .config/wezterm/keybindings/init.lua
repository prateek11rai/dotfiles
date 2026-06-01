-- Custom keybindings

local wezterm = require("wezterm")

local module = {}

module.keys = {
  -- Fit the window to the active screen. Useful when an external display is
  -- disconnected and the window ends up larger than the internal screen.
  {
    key = "f",
    mods = "CTRL|SHIFT",
    action = wezterm.action_callback(function(window, _)
      local screen = wezterm.gui.screens().active
      window:set_position(screen.x, screen.y)
      window:set_inner_size(screen.width, screen.height)
    end),
  },
}

return module
