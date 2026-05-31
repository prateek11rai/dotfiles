-- Pull in the wezterm API
local wezterm = require("wezterm")

-- This will hold the configuration.
local config = wezterm.config_builder()

-- Load startup configs
local startup = require("startup")

-- This is where you actually apply your config choices.

-- decorations
config.enable_tab_bar = false
config.window_decorations = "RESIZE"
-- Font
config.font = wezterm.font("JetBrains Mono", { weight = "Bold"})
config.font_size = 15
-- Color Theme and inline styling
config.color_scheme = "Dracula (Official)"
config.window_background_opacity = 0.99
config.macos_window_background_blur = 20
-- config.window_frame = {
--   border_left_width = '0.25cell',
--   border_right_width = '0.25cell',
--   border_bottom_height = '0.15cell',
--   border_top_height = '0.15cell',
--   border_left_color = 'purple',
--   border_right_color = 'purple',
--   border_bottom_color = 'purple',
--   border_top_color = 'purple',
-- }
-- Skip the "are you sure?" prompt on Cmd+Q
config.window_close_confirmation = "NeverPrompt"


-- Finally, return the configuration to wezterm:
return config