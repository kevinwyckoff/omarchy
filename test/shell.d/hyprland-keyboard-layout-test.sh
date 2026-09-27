#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

require_command lua

# Prints the input settings a config hands Hyprland: the session's
# default/hypr/input.lua, or with LOAD=greeter the SDDM greeter's hyprland.lua.
# TREE loads the configs from another copy of the tree, and VCONSOLE_PATH reads
# vconsole.conf from that path instead of the given contents.
resolved_input() {
  OMARCHY_PATH="${TREE:-$ROOT}" OMARCHY_VCONSOLE="${1-}" VCONSOLE_PATH="${VCONSOLE_PATH-}" LOAD="${LOAD:-session}" lua <<'LUA'
package.path = os.getenv("OMARCHY_PATH") .. "/?.lua;" .. package.path

local vconsole = os.getenv("OMARCHY_VCONSOLE")
local vconsole_path = os.getenv("VCONSOLE_PATH")
local real_open = io.open

io.open = function(path, mode)
  if path ~= "/etc/vconsole.conf" then
    return real_open(path, mode)
  end

  if vconsole_path ~= "" then
    return real_open(vconsole_path, mode)
  end

  if not vconsole then
    return nil
  end

  local file = io.tmpfile()
  file:write(vconsole)
  file:seek("set")
  return file
end

hl = {
  config = function(config)
    local input = config.input
    print(("[%s] [%s] [%s]"):format(input.kb_layout, input.kb_variant, input.kb_options))
  end,
}

o = { window = function() end }

if os.getenv("LOAD") == "greeter" then
  dofile(os.getenv("OMARCHY_PATH") .. "/default/sddm/hyprland.lua")
else
  require("default.hypr.input")
end
LUA
}

assert_input() {
  local description="$1"
  local expected="$2"
  local actual

  if (( $# > 2 )); then
    actual=$(resolved_input "$3")
  else
    actual=$(resolved_input)
  fi

  [[ $actual == "$expected" ]] ||
    fail "$description" "expected: $expected"$'\n'"actual:   $actual"
  pass "$description"
}

base_options="compose:caps,shift:both_capslock_cancel"
toggle_options="$base_options,grp:alts_toggle"

assert_input "missing vconsole.conf falls back to us" "[us] [] [$base_options]"
assert_input "us layout passes through" "[us] [intl] [$base_options]" 'XKBLAYOUT=us
XKBVARIANT=intl
'
assert_input "latin layouts are left alone" "[de] [nodeadkeys] [$base_options]" 'XKBLAYOUT=de
XKBVARIANT=nodeadkeys
'
assert_input "non-latin layout gains us in front" "[us,ara] [,] [$toggle_options]" 'XKBLAYOUT=ara
'
assert_input "prepended us keeps variants aligned" "[us,ru] [,phonetic] [$toggle_options]" 'XKBLAYOUT=ru
XKBVARIANT=phonetic
'
assert_input "non-latin layout in front gains us even when us trails" "[us,il,us] [,] [$toggle_options]" 'XKBLAYOUT=il,us
'

# The SDDM greeter takes the same password, so it needs the same layout; it
# leaves out the session's Caps Lock compose key.
LOAD=greeter assert_input "the greeter falls back to us" "[us] [] []"
LOAD=greeter assert_input "the greeter uses the picked layout" "[de] [nodeadkeys] []" 'XKBLAYOUT=de
XKBVARIANT=nodeadkeys
'
LOAD=greeter assert_input "the greeter leads with us for non-latin layouts" "[us,ru] [,phonetic] [grp:alts_toggle]" 'XKBLAYOUT=ru
XKBVARIANT=phonetic
'

# A greeter that can't read the layout keeps US instead of showing a config
# error on the login screen: keyboard.lua missing after a partial upgrade, cut
# short, or handing back something else, or vconsole.conf unreadable.
greeter_tree=$(mktemp -d)
trap 'rm -rf "$greeter_tree"' EXIT
# A directory in vconsole.conf's place opens but can't be read.
mkdir -p "$greeter_tree/default/sddm" "$greeter_tree/default/hypr" "$greeter_tree/etc/vconsole.conf"
cp "$ROOT/default/sddm/hyprland.lua" "$greeter_tree/default/sddm/"
german='XKBLAYOUT=de
XKBVARIANT=nodeadkeys
'

TREE=$greeter_tree LOAD=greeter assert_input "the greeter falls back to us without keyboard.lua" "[us] [] []" "$german"
keyboard_lua_size=$(wc -c <"$ROOT/default/hypr/keyboard.lua")
head -c $(( keyboard_lua_size / 2 )) "$ROOT/default/hypr/keyboard.lua" >"$greeter_tree/default/hypr/keyboard.lua"
TREE=$greeter_tree LOAD=greeter assert_input "the greeter falls back to us when keyboard.lua is cut short" "[us] [] []" "$german"
printf 'return { layout = "de" }\n' >"$greeter_tree/default/hypr/keyboard.lua"
TREE=$greeter_tree LOAD=greeter assert_input "the greeter falls back to us when keyboard.lua returns something else" "[us] [] []" "$german"
VCONSOLE_PATH="$greeter_tree/etc/vconsole.conf" LOAD=greeter assert_input "the greeter falls back to us when vconsole.conf can't be read" "[us] [] []"

hooks_conf="$ROOT/etc/mkinitcpio.conf.d/omarchy_hooks.conf"
keyboard_lua="$ROOT/default/hypr/keyboard.lua"

hooks_layouts=$(awk -F')' '/\) ;;$/ { gsub(/[[:space:]|]+/, "\n", $1); print $1 }' "$hooks_conf" | grep '^[a-z]\+$' | sort)
lua_layouts=$(sed -n '/^local non_latin_layouts =/,+1p' "$keyboard_lua" | grep -o '"[^"]*"' | tr -d '"' | tr ' ' '\n' | grep '^[a-z]\+$' | sort)

[[ -n $hooks_layouts ]] || fail "non-latin layout list is readable from omarchy_hooks.conf"
[[ $hooks_layouts == "$lua_layouts" ]] ||
  fail "non-latin layout lists stay in sync" "$(diff <(echo "$hooks_layouts") <(echo "$lua_layouts"))"
pass "non-latin layout lists stay in sync with the initramfs hook"
