#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command lua

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

# Load the production keyboard step without running first-boot setup.
owner="$ROOT/bin/omarchy-provision-owner"
for fn in keyboard_form apply_keyboard apply_keyboard_xkb; do
  sed -n "/^$fn() {/,/^}/p" "$owner" >>"$test_tmp/keyboard_step"
  grep -q "^$fn() {" "$test_tmp/keyboard_step" || fail "$fn is found in omarchy-provision-owner"
done

# Runs the keyboard step for the layout in $PICK, against a scratch root's
# vconsole.conf. With REAL_FIRSTBOOT set, systemd-firstboot is the real one,
# pointed at that root, so systemd's own kbd-model-map decides what it writes.
# Otherwise a stand-in writes what systemd writes for a keymap it maps (de:
# KEYMAP and XKB) and for one it doesn't (anything else: KEYMAP alone).
cat >"$test_tmp/harness" <<'SH'
#!/bin/bash
set -euo pipefail
source "$ROOT/install/provisioning/setup-form.sh"
source "$TEST_TMP/keyboard_step"
LOG_FILE="$TEST_TMP/log"
VCONSOLE_CONF="$TEST_TMP/root/etc/vconsole.conf"
step() { :; }
confirm_reboot() { return 1; }
omarchy_prompt_keyboard() { keyboard="$PICK"; keyboard_label="$PICK"; }
tty() { echo "not a tty"; return 1; }
loadkeys() { :; }
log_step() { printf '%s\n' "$1" >>"$LOG_FILE"; }
localectl() {
  case $* in
    "--no-pager list-keymaps") printf '%s\n' $KNOWN_KEYMAPS ;;
    "set-keymap "*) [[ ${LOCALECTL_FAILS:-} != 1 ]] && printf 'KEYMAP=%s\n' "$2" >"$VCONSOLE_CONF" ;;
    *) return 1 ;;
  esac
}
if [[ -n ${REAL_FIRSTBOOT:-} ]]; then
  systemd-firstboot() { command systemd-firstboot --root="$TEST_TMP/root" "$@" >/dev/null; }
else
  systemd-firstboot() {
    [[ ${FIRSTBOOT_FAILS:-} != 1 ]] || return 1
    local keymap=${1#--keymap=}
    {
      printf '%s\n' "# Written by systemd-firstboot(1)" "KEYMAP=$keymap"
      [[ $keymap != de ]] || printf '%s\n' XKBLAYOUT=de XKBMODEL=pc105 XKBOPTIONS=terminate:ctrl_alt_bksp
    } >"$VCONSOLE_CONF"
  }
fi
keyboard_form
SH

KNOWN_KEYMAPS="us de pl pl3 colemak ua bg-cp1251 cz"

vconsole_conf="$test_tmp/root/etc/vconsole.conf"
mkdir -p "$test_tmp/root/etc"

# Picks a layout, starting from the given vconsole.conf.
pick() {
  local keymap="$1"
  rm -f "$test_tmp/log"
  printf '%s' "$2" >"$vconsole_conf"
  TEST_TMP="$test_tmp" PICK="$keymap" KNOWN_KEYMAPS="$KNOWN_KEYMAPS" bash "$test_tmp/harness" ||
    fail "the keyboard step finishes for $keymap" "$(cat "$test_tmp/log" 2>/dev/null)"
}
export ROOT FIRSTBOOT_FAILS="" LOCALECTL_FAILS="" REAL_FIRSTBOOT=""

vconsole() { cat "$vconsole_conf"; }

assert_vconsole() {
  local description="$1" expected="$2"
  [[ $(vconsole) == "$expected" ]] || fail "$description" "expected:"$'\n'"$expected"$'\n'"actual:"$'\n'"$(vconsole)"
  pass "$description"
}

# Hyprland's kb_layout, kb_variant and kb_options for the vconsole.conf left behind.
desktop_input() {
  OMARCHY_PATH="$ROOT" VCONSOLE_FILE="$vconsole_conf" lua <<'LUA'
package.path = os.getenv("OMARCHY_PATH") .. "/?.lua;" .. package.path
local real_open = io.open
io.open = function(path, mode)
  if path == "/etc/vconsole.conf" then
    path = os.getenv("VCONSOLE_FILE")
  end
  return real_open(path, mode)
end
hl = {
  config = function(config)
    local input = config.input
    print(("[%s] [%s] [%s]"):format(input.kb_layout, input.kb_variant, input.kb_options))
  end,
}
o = { window = function() end }
require("default.hypr.input")
LUA
}

assert_desktop() {
  local description="$1" expected="$2" actual
  actual=$(desktop_input)
  [[ $actual == "$expected" ]] || fail "$description" "expected: $expected"$'\n'"actual:   $actual"
  pass "$description"
}

base_options="compose:caps,shift:both_capslock_cancel"
toggle_options="$base_options,grp:alts_toggle"

# A layout systemd can't map gets the picker's XKB layout, right after KEYMAP.
pick pl $'KEYMAP=us\nXKBLAYOUT=us\n'
assert_vconsole "a keymap systemd can't map gets the picker's XKB layout" "# Written by systemd-firstboot(1)
KEYMAP=pl
XKBLAYOUT=pl
XKBMODEL=pc105
XKBOPTIONS=terminate:ctrl_alt_bksp"
grep -q 'keymap pl has no XKB layout' "$test_tmp/log" || fail "the added layout is logged"
assert_desktop "Polish reaches Hyprland" "[pl] [] [$base_options]"

pick colemak $'KEYMAP=us\n'
assert_vconsole "the picker's variant is written too" "# Written by systemd-firstboot(1)
KEYMAP=colemak
XKBLAYOUT=us
XKBMODEL=pc105
XKBVARIANT=colemak
XKBOPTIONS=terminate:ctrl_alt_bksp"
assert_desktop "Colemak reaches Hyprland as us(colemak)" "[us] [colemak] [$base_options]"

# Non-Latin layouts get the same us-first treatment as the mapped ones.
pick ua $'KEYMAP=us\n'
assert_desktop "Ukrainian reaches Hyprland behind us, with the Alt toggle" "[us,ua] [,] [$toggle_options]"
pick bg-cp1251 $'KEYMAP=us\n'
assert_desktop "phonetic Bulgarian keeps its variant behind us" "[us,bg] [,phonetic] [$toggle_options]"

# A keymap systemd maps stays exactly as systemd wrote it.
pick de $'KEYMAP=us\n'
assert_vconsole "a keymap systemd maps is left as systemd wrote it" "# Written by systemd-firstboot(1)
KEYMAP=de
XKBLAYOUT=de
XKBMODEL=pc105
XKBOPTIONS=terminate:ctrl_alt_bksp"
! grep -q 'XKB layout' "$test_tmp/log" 2>/dev/null || fail "nothing is logged for a mapped keymap"

# A keymap outside the picker that systemd can't map either stays as today.
pick pl3 $'KEYMAP=us\n'
assert_vconsole "a keymap the picker doesn't offer is left as systemd wrote it" "# Written by systemd-firstboot(1)
KEYMAP=pl3"

pick definitely-not-a-keymap $'KEYMAP=us\nXKBLAYOUT=us\n'
assert_vconsole "an unknown keymap leaves vconsole.conf alone" $'KEYMAP=us\nXKBLAYOUT=us'

# The localectl fallback persists KEYMAP alone the same way.
FIRSTBOOT_FAILS=1 pick cz $'KEYMAP=us\n'
assert_vconsole "the localectl fallback gets the picker's layout too" "KEYMAP=cz
XKBLAYOUT=cz
XKBMODEL=pc105
XKBVARIANT=qwerty
XKBOPTIONS=terminate:ctrl_alt_bksp"

# Nothing is paired with a keymap that never got persisted.
FIRSTBOOT_FAILS=1 LOCALECTL_FAILS=1 pick pl $'KEYMAP=us\nFONT=default8x16\n'
assert_vconsole "no XKB layout is written for a keymap that was not persisted" $'KEYMAP=us\nFONT=default8x16'

# Direct calls: the layout goes after KEYMAP, ahead of lines like the console
# font, and a second call adds nothing.
printf '%s\n' KEYMAP=pl FONT=default8x16 >"$vconsole_conf"
for _ in 1 2; do
  TEST_TMP="$test_tmp" bash -c '
    source "$ROOT/install/provisioning/setup-form.sh"
    source "$TEST_TMP/keyboard_step"
    VCONSOLE_CONF="$TEST_TMP/root/etc/vconsole.conf" LOG_FILE=/dev/null
    log_step() { :; }
    apply_keyboard_xkb pl'
done
assert_vconsole "the layout goes after KEYMAP, once" "KEYMAP=pl
XKBLAYOUT=pl
XKBMODEL=pc105
XKBOPTIONS=terminate:ctrl_alt_bksp
FONT=default8x16"

# The real systemd-firstboot and kbd-model-map, where the host has them: every
# layout the picker offers must reach Hyprland, and those systemd maps must
# come out byte for byte as systemd-firstboot alone writes them.
if command -v systemd-firstboot >/dev/null && [[ -r /usr/share/systemd/kbd-model-map ]]; then
  source "$ROOT/install/provisioning/setup-form.sh"
  KNOWN_KEYMAPS=$(cut -d'|' -f2 <<<"$OMARCHY_KEYBOARD_LAYOUTS")
  plain_root="$test_tmp/plain"
  mkdir -p "$plain_root/etc"
  without_layout=()
  changed=()
  while IFS='|' read -r label keymap xkb; do
    REAL_FIRSTBOOT=1 pick "$keymap" $'KEYMAP=us\n'
    grep -q '^XKBLAYOUT=.' "$vconsole_conf" || without_layout+=("$label ($keymap)")

    if [[ -z $xkb ]]; then
      rm -f "$plain_root/etc/vconsole.conf"
      command systemd-firstboot --root="$plain_root" --keymap="$keymap" --force >/dev/null 2>&1
      cmp -s "$plain_root/etc/vconsole.conf" "$vconsole_conf" || changed+=("$label ($keymap)")
    fi
  done <<<"$OMARCHY_KEYBOARD_LAYOUTS"

  ((${#without_layout[@]} == 0)) ||
    fail "every picked layout gives Hyprland an XKB layout with the real systemd-firstboot" "$(printf '%s\n' "${without_layout[@]}")"
  pass "every picked layout gives Hyprland an XKB layout with the real systemd-firstboot"
  ((${#changed[@]} == 0)) ||
    fail "layouts systemd maps come out exactly as systemd-firstboot writes them" "$(printf '%s\n' "${changed[@]}")"
  pass "layouts systemd maps come out exactly as systemd-firstboot writes them"
else
  skip "every picked layout gives Hyprland an XKB layout with the real systemd-firstboot (no systemd-firstboot)"
fi
