-- The keyboard layout picked at install or first boot, as Hyprland takes it.
-- Shared by the session (default/hypr/input.lua) and the SDDM greeter
-- (default/sddm/hyprland.lua), so the password is typed on the same layout in
-- both.

local function read_vconsole()
  local values = {}
  local file = io.open("/etc/vconsole.conf", "r")
  if not file then
    return values
  end

  for line in file:lines() do
    local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
    if key and value then
      value = value:gsub("%s+#.*$", "")
      value = value:gsub('^"(.*)"$', "%1")
      value = value:gsub("^'(.*)'$", "%1")
      values[key] = value
    end
  end

  file:close()
  return values
end

-- Layouts that can't type Latin letters. Keep in sync with the list in
-- etc/mkinitcpio.conf.d/omarchy_hooks.conf.
local non_latin_layouts =
  " af am ara bd bg by et ge gr il in iq ir kg kh kz la lk mk mm mn mv np rs ru sy th tj ua "

local vconsole = read_vconsole()

local keyboard = {
  layout = vconsole.XKBLAYOUT or "us",
  variant = vconsole.XKBVARIANT or "",
  -- kb_options the layout itself needs, for the caller to add to its own.
  options = "",
}

-- Hyprland resolves keybindings against the first entry in kb_layout, not the
-- layout that's currently active, so Omarchy's Latin-keysym bindings (SUPER + W
-- and friends) only fire when a Latin layout leads. Installing with a non-Latin
-- one would otherwise leave the desktop unusable, and the greeter unable to take
-- a password typed in Latin letters.
if non_latin_layouts:find(" " .. keyboard.layout:match("^[^,]*") .. " ", 1, true) then
  keyboard.layout = "us," .. keyboard.layout
  keyboard.variant = "," .. keyboard.variant
  -- Reach the original layout with Left Alt + Right Alt.
  keyboard.options = "grp:alts_toggle"
end

return keyboard
