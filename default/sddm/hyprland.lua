-- Minimal Hyprland config for the SDDM Wayland greeter.
-- SDDM starts the greeter itself after the compositor is ready.

-- Take the password on the layout picked at install, as the session does, or
-- the greeter stays US: with German picked, y and z would swap places. It is the
-- system layout from /etc/vconsole.conf, not a user's ~/.config/hypr/input.lua,
-- because the greeter can't know who is about to log in.
--
-- If that layout can't be had, from a partial upgrade without keyboard.lua or a
-- vconsole.conf that can't be read, keep US rather than put a config error on
-- the login screen.
local keyboard = { layout = "us", variant = "", options = "" }
local loaded, picked =
  pcall(dofile, (os.getenv("OMARCHY_PATH") or "/usr/share/omarchy") .. "/default/hypr/keyboard.lua")
if
  loaded
  and type(picked) == "table"
  and type(picked.layout) == "string"
  and type(picked.variant) == "string"
  and type(picked.options) == "string"
then
  keyboard = picked
end

hl.config({
  input = {
    kb_layout = keyboard.layout,
    kb_variant = keyboard.variant,
    kb_options = keyboard.options,
  },

  misc = {
    disable_hyprland_logo = true,
    disable_splash_rendering = true,
    force_default_wallpaper = 0,
  },

  animations = {
    enabled = false,
  },
})
