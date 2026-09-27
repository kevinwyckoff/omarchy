#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

# Load the production apply_keyboard without running first-boot setup.
sed -n '/^apply_keyboard() {/,/^}/p' "$ROOT/bin/omarchy-provision-owner" >"$test_tmp/apply_keyboard"
[[ -s $test_tmp/apply_keyboard ]] || fail "apply_keyboard is found in omarchy-provision-owner"

# systemd-firstboot --force rewrites vconsole.conf with only the keyboard lines,
# dropping everything else; the stand-in does the same to the test's copy.
cat >"$test_tmp/harness" <<'SH'
#!/bin/bash
set -euo pipefail
source "$TEST_TMP/apply_keyboard"
LOG_FILE="$TEST_TMP/log"
VCONSOLE_CONF="$TEST_TMP/vconsole.conf"
tty() { echo "not a tty"; return 1; }
loadkeys() { :; }
log_step() { printf '%s\n' "$1" >>"$LOG_FILE"; }
localectl() {
  case $* in
    "--no-pager list-keymaps") printf '%s\n' us de de-latin1 ;;
    "set-keymap "*) printf 'set-keymap %s\n' "$2" >>"$TEST_TMP/localectl" ;;
    *) return 1 ;;
  esac
}
systemd-firstboot() {
  [[ ${FIRSTBOOT_FAILS:-} == 1 ]] && return 1
  local keymap=${1#--keymap=}
  printf '%s\n' "# Written by systemd-firstboot(1)" "KEYMAP=$keymap" "XKBLAYOUT=${keymap%%-*}" >"$VCONSOLE_CONF"
}
apply_keyboard "$1"
SH

# Runs apply_keyboard for a keymap, starting from the given vconsole.conf, or
# from none at all when it is left out.
run_apply() {
  local keymap="$1"
  rm -f "$test_tmp/log" "$test_tmp/localectl"
  if (( $# > 1 )); then
    printf '%s' "$2" >"$test_tmp/vconsole.conf"
  else
    rm -f "$test_tmp/vconsole.conf"
  fi
  TEST_TMP="$test_tmp" bash "$test_tmp/harness" "$keymap" || fail "apply_keyboard $keymap finishes"
}

has_line() {
  [[ $(grep -cx -- "$1" "$test_tmp/vconsole.conf") == 1 ]]
}

vconsole() {
  cat "$test_tmp/vconsole.conf"
}

run_apply de $'KEYMAP=us\nXKBLAYOUT=us\nFONT=default8x16\n'
has_line KEYMAP=de && has_line XKBLAYOUT=de && ! grep -q '=us$' "$test_tmp/vconsole.conf" ||
  fail "the picked keymap replaces the install's" "$(vconsole)"
has_line FONT=default8x16 || fail "the install's console font survives the rewrite" "$(vconsole)"
pass "first-boot keyboard keeps the install's console font"

run_apply de $'KEYMAP=us\nFONT=ter-v32n\nFONT_MAP=8859-2\nFONT_UNIMAP=lat2\n'
has_line FONT=ter-v32n && has_line FONT_MAP=8859-2 && has_line FONT_UNIMAP=lat2 ||
  fail "every console font line survives" "$(vconsole)"
pass "first-boot keyboard keeps FONT_MAP and FONT_UNIMAP too"

# systemd-vconsole-setup takes a key with blanks before it or around the =.
run_apply de $'KEYMAP=us\n  FONT=ter-v32n\n\tFONT_MAP = 8859-2\n#FONT=default8x16\n'
has_line '  FONT=ter-v32n' && has_line $'\tFONT_MAP = 8859-2' ||
  fail "indented font lines survive" "$(vconsole)"
! grep -q '^#FONT' "$test_tmp/vconsole.conf" || fail "a commented-out font stays behind" "$(vconsole)"
pass "first-boot keyboard keeps font lines written with blanks"

run_apply de $'KEYMAP=us\nXKBLAYOUT=us\n'
! grep -q '^FONT' "$test_tmp/vconsole.conf" || fail "no font is added when the install set none" "$(vconsole)"
run_apply de
has_line KEYMAP=de && ! grep -q '^FONT' "$test_tmp/vconsole.conf" ||
  fail "a missing vconsole.conf is written with just the keyboard" "$(vconsole)"
pass "first-boot keyboard adds no font of its own"

run_apply de $'KEYMAP=us\nFONT=default8x16\n'
TEST_TMP="$test_tmp" bash "$test_tmp/harness" de-latin1 || fail "a second keyboard pick finishes"
has_line KEYMAP=de-latin1 && has_line FONT=default8x16 ||
  fail "picking again keeps exactly one font line" "$(vconsole)"
pass "first-boot keyboard can run again without duplicating the font"

FIRSTBOOT_FAILS=1 run_apply de $'KEYMAP=us\nFONT=default8x16\n'
[[ $(cat "$test_tmp/localectl") == "set-keymap de" ]] && has_line FONT=default8x16 ||
  fail "the localectl fallback leaves the font alone" "$(vconsole)"
pass "first-boot keyboard falls back to localectl without touching the font"

run_apply definitely-not-a-keymap $'KEYMAP=us\nFONT=default8x16\n'
[[ $(vconsole) == $'KEYMAP=us\nFONT=default8x16' ]] || fail "an unknown keymap leaves vconsole.conf alone" "$(vconsole)"
grep -q 'unknown to localectl' "$test_tmp/log" || fail "an unknown keymap is logged"
pass "first-boot keyboard keeps the default for an unknown keymap"
