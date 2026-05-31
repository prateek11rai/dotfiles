-- Startup config: tmux auto-attach and window sizing
-- Attaches to existing tmux session or creates a new one
-- Maximizes window on startup to fill the screen

local wezterm = require("wezterm")

local module = {}

-- tmux new-session -A attaches to the most recent session if one exists,
-- or creates a new one if none exist
module.default_args = { "/opt/homebrew/bin/tmux", "new-session", "-A" }

wezterm.on("gui-startup", function()
  local _, _, window = wezterm.mux.spawn_window({
    args = module.default_args,
  })
  window:gui_window():maximize()
end)

return module
