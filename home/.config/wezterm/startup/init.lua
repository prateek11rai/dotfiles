-- Startup config: tmux auto-attach and window sizing
-- Attaches to existing tmux session or creates a new one
-- Maximizes window on startup to fill the screen

local wezterm = require("wezterm")

local module = {}

-- tmux new-session -A attaches to the most recent session if one exists,
-- or creates a new one if none exist. Launched through a login shell so tmux is found
-- wherever it is installed (WezTerm's GUI environment has a bare PATH) instead of
-- hardcoding an install prefix.
module.default_args = { os.getenv("SHELL") or "/bin/sh", "-l", "-c", "exec tmux new-session -A" }

wezterm.on("gui-startup", function()
  local _, _, window = wezterm.mux.spawn_window({
    args = module.default_args,
  })
  window:gui_window():maximize()
end)

return module
