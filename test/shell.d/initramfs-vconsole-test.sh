#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

conf_dir="$ROOT/etc/mkinitcpio.conf.d"
vconsole_hook="$ROOT/etc/initcpio/install/omarchy-vconsole"
vconsole_conf="$test_tmp/vconsole.conf"

source "$ROOT/install/provisioning/setup-form.sh"
declare -F omarchy_keyboard_xkb_settings >/dev/null || fail "setup-form.sh defines omarchy_keyboard_xkb_settings"

# Sources the drop-ins the way mkinitcpio does, against the given vconsole.conf,
# and prints the FILES and HOOKS they leave, one entry per line. The HOOKS
# baseline comes from 00-omarchy-hooks.conf where Omarchy ships one, and from
# omarchy_hooks.conf otherwise. $1 is the Omarchy tree to read setup-form.sh
# from (standing in for /usr/share/omarchy), $2 a drop-in that sorts after omarchy_hooks.conf. mkinitcpio does not
# run under set -u, but the config must survive it.
resolve() {
  local omarchy_path="${1:-$ROOT}" later="${2:-}"
  OMARCHY_VCONSOLE_CONF="$vconsole_conf" \
    OMARCHY_SETUP_FORM="$omarchy_path/install/provisioning/setup-form.sh" \
    OMARCHY_PATH="${RESOLVE_OMARCHY_PATH:-$omarchy_path}" \
    OMARCHY_PCI_DEVICES_PATH="$test_tmp/no-pci" bash -uc '
      FILES=()
      HOOKS=()
      if [[ -f $1/00-omarchy-hooks.conf ]]; then
        source "$1/00-omarchy-hooks.conf"
      fi
      source "$1/omarchy_hooks.conf"
      if [[ -n $2 ]]; then
        source "$2"
      fi
      printf "FILES %s\n" "${FILES[@]}"
      printf "HOOKS %s\n" "${HOOKS[@]}"
    ' -- "$conf_dir" "$later"
}

bundled_by() {
  local resolved="$1" files=0 hook=0
  grep -qxF 'FILES /etc/vconsole.conf' <<<"$resolved" && files=1
  grep -qxF 'HOOKS omarchy-vconsole' <<<"$resolved" && hook=1
  if ((files && hook)); then
    echo both
  elif ((hook)); then
    echo hook
  elif ((files)); then
    echo files
  else
    echo none
  fi
}

assert_bundled_by() {
  local description="$1" expected="$2" contents="$3" omarchy_path="${4:-}" later="${5:-}"
  local resolved
  printf '%s' "$contents" >"$vconsole_conf"
  resolved=$(resolve "$omarchy_path" "$later") || fail "$description" "sourcing omarchy_hooks.conf failed"
  [[ $(bundled_by "$resolved") == "$expected" ]] ||
    fail "$description" "expected: $expected"$'\n'"actual:   $(bundled_by "$resolved")"$'\n'"$resolved"
  pass "$description"
}

# What systemd-firstboot writes for keymaps its kbd-model-map has a row for.
assert_bundled_by "a keymap systemd maps to a Latin layout goes in whole" files '# Written by systemd-firstboot(1)
KEYMAP=de-latin1
XKBLAYOUT=de
XKBMODEL=pc105
XKBOPTIONS=terminate:ctrl_alt_bksp
'
assert_bundled_by "a keymap systemd maps to a non-Latin layout stays out" none 'KEYMAP=ru
XKBLAYOUT=ru,us
XKBMODEL=pc105
XKBOPTIONS=terminate:ctrl_alt_bksp,grp:shift_toggle
'

# What the keyboard picker writes for a keymap systemd has no row for.
assert_bundled_by "a Latin layout the picker pinned goes in through the hook" hook '# Written by systemd-firstboot(1)
KEYMAP=cz
XKBLAYOUT=cz
XKBMODEL=pc105
XKBVARIANT=qwerty
XKBOPTIONS=terminate:ctrl_alt_bksp
FONT=ter-v16n
'
assert_bundled_by "a non-Latin layout the picker pinned still goes in through the hook" hook 'KEYMAP=ua
XKBLAYOUT=ua
XKBMODEL=pc105
XKBOPTIONS=terminate:ctrl_alt_bksp
'
assert_bundled_by "a quoted KEYMAP with the picker's layout goes in through the hook" hook 'KEYMAP="pl"
XKBLAYOUT=pl
XKBMODEL=pc105
XKBOPTIONS=terminate:ctrl_alt_bksp
'

pinned=0
leaked=()
while IFS='|' read -r _ keymap _; do
  settings=$(omarchy_keyboard_xkb_settings "$keymap")
  [[ -n $settings ]] || continue
  pinned=$((pinned + 1))
  printf 'KEYMAP=%s\n%s\nFONT=default8x16\n' "$keymap" "$settings" >"$vconsole_conf"
  [[ $(bundled_by "$(resolve)") == "hook" ]] || leaked+=("$keymap")
done <<<"$OMARCHY_KEYBOARD_LAYOUTS"
((pinned > 0)) || fail "the picker pins some layouts"
((${#leaked[@]} == 0)) || fail "every pinned picker layout goes in through the hook" "pinned XKB bundled whole: ${leaked[*]}"
pass "every pinned picker layout goes in through the hook"

# Nothing to leave out: the file goes in whole through FILES, as before the
# hook existed, so a later drop-in that sets HOOKS outright still keeps it.
assert_bundled_by "a picker keymap written before the pin goes in whole" files 'KEYMAP=pl
FONT=default8x16
'
assert_bundled_by "an unmapped keymap the picker doesn't offer goes in whole" files 'KEYMAP=pl3
'
printf '%s\n' 'HOOKS=(base udev keymap consolefont plymouth autodetect modconf kms block encrypt filesystems fsck)' \
  >"$test_tmp/zz-hooks.conf"
assert_bundled_by "a later drop-in that sets HOOKS keeps a picker keymap written before the pin" files 'KEYMAP=pl
FONT=default8x16
' "" "$test_tmp/zz-hooks.conf"

# XKB lines the picker did not write are the user's, and go in as before.
assert_bundled_by "an XKB layout added by hand to a picker keymap goes in whole" files 'KEYMAP=cz
XKBLAYOUT=cz
FONT=default8x16
'
assert_bundled_by "the picker's layout with a variant changed by hand goes in whole" files 'KEYMAP=cz
XKBLAYOUT=cz
XKBMODEL=pc105
XKBVARIANT=qwertz
XKBOPTIONS=terminate:ctrl_alt_bksp
'
assert_bundled_by "the picker's layout with a line added by hand goes in whole" files 'KEYMAP=pl
XKBLAYOUT=pl
XKBMODEL=pc105
XKBVARIANT=legacy
XKBOPTIONS=terminate:ctrl_alt_bksp
'
assert_bundled_by "quoted XKB settings go in whole" files 'KEYMAP=pl
XKBLAYOUT="pl"
XKBMODEL="pc105"
XKBOPTIONS="terminate:ctrl_alt_bksp"
'
assert_bundled_by "a non-Latin XKB layout added by hand to a picker keymap stays out" none 'KEYMAP=ua
XKBLAYOUT=ua
'
assert_bundled_by "a picker keymap's XKB layout on another keymap goes in whole" files 'KEYMAP=us
XKBLAYOUT=pl
XKBMODEL=pc105
XKBOPTIONS=terminate:ctrl_alt_bksp
'
assert_bundled_by "no KEYMAP keeps the Latin check" files 'XKBLAYOUT=de
'

# Without setup-form.sh there is no telling what the picker wrote.
assert_bundled_by "without setup-form.sh a pinned Latin layout goes in whole" files 'KEYMAP=cz
XKBLAYOUT=cz
XKBMODEL=pc105
XKBVARIANT=qwerty
XKBOPTIONS=terminate:ctrl_alt_bksp
' "$test_tmp/no-omarchy"
assert_bundled_by "without setup-form.sh a pinned non-Latin layout stays out" none 'KEYMAP=ua
XKBLAYOUT=ua
XKBMODEL=pc105
XKBOPTIONS=terminate:ctrl_alt_bksp
' "$test_tmp/no-omarchy"

# The packaged setup form decides, whatever OMARCHY_PATH says: a rebuild from a
# shell pointed at a checkout without the pins must not change the LUKS prompt.
RESOLVE_OMARCHY_PATH="$test_tmp/no-omarchy" assert_bundled_by "OMARCHY_PATH doesn't decide which setup form is read" hook 'KEYMAP=cz
XKBLAYOUT=cz
XKBMODEL=pc105
XKBVARIANT=qwerty
XKBOPTIONS=terminate:ctrl_alt_bksp
'

# A setup form from before the helper falls back quietly, with no "command not
# found" on every rebuild.
old_form="$test_tmp/old-omarchy/install/provisioning"
mkdir -p "$old_form"
sed '/^omarchy_keyboard_xkb_settings()/,/^}/d' "$ROOT/install/provisioning/setup-form.sh" >"$old_form/setup-form.sh"
printf 'KEYMAP=cz\nXKBLAYOUT=cz\nXKBMODEL=pc105\nXKBVARIANT=qwerty\nXKBOPTIONS=terminate:ctrl_alt_bksp\n' >"$vconsole_conf"
old_output=$(resolve "$test_tmp/old-omarchy" 2>&1) || fail "an older setup form still sources" "$old_output"
! grep -q 'command not found' <<<"$old_output" || fail "an older setup form prints no errors" "$old_output"
[[ $(bundled_by "$old_output") == "files" ]] || fail "an older setup form falls back to the whole file" "$old_output"
pass "an older setup form falls back quietly to the whole file"

rm -f "$vconsole_conf"
resolved=$(resolve) || fail "sourcing omarchy_hooks.conf without vconsole.conf succeeds"
[[ $(bundled_by "$resolved") == "none" ]] || fail "no vconsole.conf bundles nothing" "$resolved"
pass "no vconsole.conf bundles nothing"

# The hook itself, sourced the way mkinitcpio sources it, adding to a scratch
# image through mkinitcpio's own add_file where the host has mkinitcpio, or a
# stand-in that works the same way: a file the image already has is compared
# with the source before the source is copied over it.
[[ -f $vconsole_hook ]] || fail "the omarchy-vconsole install hook exists"
buildroot="$test_tmp/buildroot"

build_image() {
  mkdir -p "$test_tmp/tmp"
  OMARCHY_VCONSOLE_CONF="$vconsole_conf" BUILDROOT="$buildroot" TMPDIR="$test_tmp/tmp" bash -c '
    if [[ -r /usr/lib/initcpio/functions ]]; then
      source /usr/lib/initcpio/functions
    else
      add_file() {
        local src="$1" dest="$BUILDROOT$2" mode="$3"
        [[ $src != "-" ]] || src=/dev/stdin
        if [[ -f $dest ]] && cmp -s -- "$src" "$dest"; then
          return 0
        fi
        install -Dm"$mode" "$src" "$dest"
      }
    fi
    source "$1"
    build
  ' -- "$vconsole_hook" >/dev/null
}

printf '%s\n' '# Written by systemd-firstboot(1)' 'KEYMAP=cz' 'XKBLAYOUT=cz' 'XKBMODEL=pc105' \
  'XKBVARIANT=qwerty' 'XKBOPTIONS=terminate:ctrl_alt_bksp' 'FONT=ter-v16n' >"$vconsole_conf"
stripped='# Written by systemd-firstboot(1)
KEYMAP=cz
FONT=ter-v16n'

rm -rf "$buildroot"
build_image || fail "the omarchy-vconsole hook builds"
[[ -f $buildroot/etc/vconsole.conf && $(<"$buildroot/etc/vconsole.conf") == "$stripped" ]] ||
  fail "the hook bundles vconsole.conf without its XKB lines" "expected:"$'\n'"$stripped"$'\n'"actual:"$'\n'"$(cat "$buildroot/etc/vconsole.conf" 2>&1)"
[[ $(stat -c %a "$buildroot/etc/vconsole.conf") == "644" ]] || fail "the hook bundles vconsole.conf readable" "$(stat -c %a "$buildroot/etc/vconsole.conf")"
pass "the hook bundles vconsole.conf without its XKB lines"

# sd-vconsole, or any hook that runs first, adds vconsole.conf whole.
rm -rf "$buildroot"
install -Dm644 "$vconsole_conf" "$buildroot/etc/vconsole.conf"
build_image || fail "the omarchy-vconsole hook builds over an earlier vconsole.conf"
[[ $(<"$buildroot/etc/vconsole.conf") == "$stripped" ]] ||
  fail "the hook replaces a whole vconsole.conf an earlier hook added" "expected:"$'\n'"$stripped"$'\n'"actual:"$'\n'"$(cat -A "$buildroot/etc/vconsole.conf")"
pass "the hook replaces a whole vconsole.conf an earlier hook added"

[[ -z $(ls -A "$test_tmp/tmp") ]] || fail "the hook leaves no scratch file behind" "$(ls -A "$test_tmp/tmp")"
pass "the hook leaves no scratch file behind"

rm -rf "$buildroot"
vconsole_conf="$test_tmp/absent" build_image || fail "the omarchy-vconsole hook builds without vconsole.conf"
[[ ! -e $buildroot/etc/vconsole.conf ]] || fail "the hook adds nothing without vconsole.conf" "$(cat "$buildroot/etc/vconsole.conf")"
pass "the hook adds nothing without vconsole.conf"
