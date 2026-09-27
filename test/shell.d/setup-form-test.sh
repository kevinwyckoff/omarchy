#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp_dir=$(mktemp -d)
trap 'rm -r "$tmp_dir"' EXIT

# gum reads its scripted answers from GUM_SCRIPT, one "status:output" line per
# invocation, so a test spells out exactly what the human did at each screen:
# "0:dhh" answers, "1:" is Esc, "130:" is Ctrl+C. Only the widgets that take a
# list drain stdin, matching the real ones, so the piped layouts and timezones
# can be asserted.
cat >"$tmp_dir/gum" <<'EOF'
#!/bin/bash
count=$(($(cat "$GUM_COUNT") + 1))
printf '%s' "$count" >"$GUM_COUNT"
printf '%s\n' "$*" >>"$GUM_ARGS"

case $1 in
  choose | filter) cat >"$GUM_DIR/stdin.$count" ;;
esac

line=$(sed -n "${count}p" "$GUM_SCRIPT")
printf '%s\n' "${line#*:}"
exit "${line%%:*}"
EOF

cat >"$tmp_dir/tzupdate" <<'EOF'
#!/bin/bash
[[ -n ${TZ_GUESS:-} ]] || exit 1
printf '%s\n' "$TZ_GUESS"
EOF

cat >"$tmp_dir/timedatectl" <<'EOF'
#!/bin/bash
printf '%s\n' UTC Europe/Copenhagen America/Chicago
EOF

# Calls one prompt bare under `set -euo pipefail` — the shape that makes the
# status capture load-bearing. A cancelled prompt is a failing assignment, so a
# regression to a plain `status=$?` kills the shell before the function can
# return; both cases exit with the same status, and this marker is the only
# thing that tells them apart.
cat >"$tmp_dir/driver" <<'EOF'
#!/bin/bash

set -euo pipefail
set -T

source "$ROOT/install/provisioning/setup-form.sh"

notice() { printf '%s\n' "$1" >>"$NOTICES"; }

if [[ -n ${TAKEN_USERS:-} ]]; then
  omarchy_username_taken() { [[ " $TAKEN_USERS " == *" $1 "* ]]; }
fi

trap 'if [[ ${FUNCNAME[0]:-} == "$PROMPT_FN" ]]; then printf "returned\n" >>"$MARKER"; fi' RETURN

"$PROMPT_FN"

printf 'keyboard=%s\n' "${keyboard:-}"
printf 'keyboard_label=%s\n' "${keyboard_label:-}"
printf 'username=%s\n' "${username:-}"
printf 'password=%s\n' "${password:-}"
printf 'password_confirmation=%s\n' "${password_confirmation:-}"
printf 'full_name=%s\n' "${full_name:-}"
printf 'email_address=%s\n' "${email_address:-}"
printf 'hostname=%s\n' "${hostname:-}"
printf 'timezone=%s\n' "${timezone:-}"
EOF

chmod +x "$tmp_dir/gum" "$tmp_dir/tzupdate" "$tmp_dir/timedatectl" "$tmp_dir/driver"
export PATH="$tmp_dir:$PATH"
export GUM_DIR="$tmp_dir" GUM_SCRIPT="$tmp_dir/script" GUM_ARGS="$tmp_dir/args" GUM_COUNT="$tmp_dir/count"
export NOTICES="$tmp_dir/notices" MARKER="$tmp_dir/marker"

status=0

# run_prompt <function> <status:output>... — each response answers one gum screen
run_prompt() {
  local prompt=$1
  shift

  printf '%s\n' "$@" >"$GUM_SCRIPT"
  printf '0' >"$GUM_COUNT"
  : >"$GUM_ARGS"
  : >"$NOTICES"
  : >"$MARKER"
  rm -f "$tmp_dir"/stdin.*

  PROMPT_FN="$prompt" "$tmp_dir/driver" >"$tmp_dir/out" 2>"$tmp_dir/err" && status=0 || status=$?
}

field() { sed -n "s/^$1=//p" "$tmp_dir/out"; }

assert_returned() {
  grep -qx returned "$MARKER" ||
    fail "$1" "$(printf 'the prompt never returned; the shell died inside it:\n%s' "$(<"$tmp_dir/err")")"
}

assert_status() {
  ((status == $1)) || fail "$2" "expected status: $1
actual status:   $status"
}

assert_notices() {
  local description=$1 expected=$2
  local actual
  actual=$(<"$NOTICES")
  [[ $actual == "$expected" ]] || fail "$description" "expected notices: $expected
actual notices:   $actual"
}

# The contract both callers read, and the ordering the shared list exists to keep
source "$ROOT/install/provisioning/setup-form.sh"

((OMARCHY_FORM_BACK == 1)) || fail "Esc reports status 1"
((OMARCHY_FORM_SIGNAL == 130)) || fail "Ctrl+C reports status 130"
[[ $(printf '%s\n' "$OMARCHY_KEYBOARD_LAYOUTS" | head -n 1) == "English (US)|us" ]] ||
  fail "English (US) leads the keyboard layouts so gum choose opens on the default"
pass "the form publishes the 0/1/130 status contract and leads with English (US)"

# Keyboard

run_prompt omarchy_prompt_keyboard "0:German"
assert_status 0 "keyboard prompt succeeds"
[[ $(field keyboard) == "de" ]] || fail "keyboard prompt resolves the label to a keymap"
[[ $(field keyboard_label) == "German" ]] || fail "keyboard prompt keeps the label for the summary"
[[ $(head -n 1 "$tmp_dir/stdin.1") == "English (US)" ]] || fail "keyboard prompt offers English (US) first"
grep -qF -- '--selected English (US)' "$GUM_ARGS" || fail "keyboard prompt preselects English (US)"
pass "keyboard prompt maps the chosen label to its keymap"

run_prompt omarchy_prompt_keyboard "0:Polish"
assert_status 0 "keyboard prompt accepts a layout that carries an XKB layout"
[[ $(field keyboard) == "pl" ]] || fail "a row's XKB layout stays out of the keymap the prompt answers" "$(field keyboard)"
! grep -q '|' "$tmp_dir/stdin.1" || fail "keyboard prompt offers labels only" "$(grep '|' "$tmp_dir/stdin.1")"
pass "keyboard prompt answers the console keymap for rows with an XKB layout"

# Each row is label|keymap, plus an XKB layout[:variant] where systemd has none
malformed=$(awk -F'|' 'NF < 2 || NF > 3 || $1 == "" || $2 == "" ||
  (NF == 3 && $3 !~ /^[a-z]+(:[A-Za-z0-9_-]+)?$/)' <<<"$OMARCHY_KEYBOARD_LAYOUTS")
[[ -z $malformed ]] || fail "every layout row is label|keymap with an optional layout[:variant]" "$malformed"
pass "every layout row is label|keymap with an optional layout[:variant]"

[[ $(omarchy_keyboard_xkb_settings pl) == $'XKBLAYOUT=pl\nXKBMODEL=pc105\nXKBOPTIONS=terminate:ctrl_alt_bksp' ]] ||
  fail "a pinned layout reads as systemd-firstboot writes a mapped one" "$(omarchy_keyboard_xkb_settings pl)"
[[ $(omarchy_keyboard_xkb_settings colemak) == $'XKBLAYOUT=us\nXKBMODEL=pc105\nXKBVARIANT=colemak\nXKBOPTIONS=terminate:ctrl_alt_bksp' ]] ||
  fail "a pinned variant lands between the model and the options" "$(omarchy_keyboard_xkb_settings colemak)"
for keymap in us de pl2 ""; do
  [[ -z $(omarchy_keyboard_xkb_settings "$keymap") ]] ||
    fail "no XKB settings for '$keymap', which the list pins nothing for" "$(omarchy_keyboard_xkb_settings "$keymap")"
done
pass "the list's XKB settings exist only for the keymaps it pins a layout for"

# Installs match their vconsole.conf against these pins to keep the XKB lines
# out of the initramfs, so changing one sends existing installs' desktop layout
# to the LUKS prompt. Changing a pin has to be a decision, not an accident.
pins=$(awk -F'|' 'NF == 3 { print $2 "|" $3 }' <<<"$OMARCHY_KEYBOARD_LAYOUTS" | sort)
expected_pins=$(printf '%s\n' 'azerty|fr' 'bg-cp1251|bg:phonetic' 'colemak|us:colemak' 'cz|cz:qwerty' \
  'de_CH-latin1|ch' 'kyrgyz|kg' 'no-latin1|no' 'pl|pl' 'ua|ua' | sort)
[[ $pins == "$expected_pins" ]] || fail "the list pins exactly the nine layouts installs were written with" "$pins"
pass "the list pins exactly the nine layouts installs were written with"

# kbd's azerty is the French AZERTY console keymap and kbd has no Azerbaijani
# one, so a row offering it as Azerbaijani gave a French console.
! grep -q '^Azerbaijani|' <<<"$OMARCHY_KEYBOARD_LAYOUTS" ||
  fail "no row offers the French azerty keymap as Azerbaijani" "$(grep '^Azerbaijani|' <<<"$OMARCHY_KEYBOARD_LAYOUTS")"
grep -qx 'French (AZERTY)|azerty|fr' <<<"$OMARCHY_KEYBOARD_LAYOUTS" ||
  fail "azerty is offered as French (AZERTY) with the French XKB layout"
pass "the azerty keymap is labelled as the French layout it is"

# Every offered layout has to reach Hyprland: through systemd's kbd-model-map,
# or through the list's own XKB layout, which must be one xkeyboard-config has.
kbd_model_map=/usr/share/systemd/kbd-model-map
if [[ -r $kbd_model_map ]]; then
  unmapped=$(awk -F'|' 'NR == FNR { if ($0 !~ /^[[:space:]]*#/) mapped[$1] = 1; next }
    !($2 in mapped) && $3 == "" { print $1 "|" $2 }' FS='[[:space:]]+' "$kbd_model_map" FS='|' - <<<"$OMARCHY_KEYBOARD_LAYOUTS")
  [[ -z $unmapped ]] ||
    fail "every layout without a kbd-model-map row names its XKB layout" "unmapped:"$'\n'"$unmapped"
  pass "every layout without a kbd-model-map row names its XKB layout"
else
  skip "every layout without a kbd-model-map row names its XKB layout (no $kbd_model_map)"
fi

xkb_rules=/usr/share/X11/xkb/rules/evdev.lst
if [[ -r $xkb_rules ]]; then
  unknown=$(awk -F'|' 'NF == 3 { print $3 }' <<<"$OMARCHY_KEYBOARD_LAYOUTS" | while IFS=: read -r layout variant; do
    if [[ -n $variant ]]; then
      awk -v l="$layout" -v v="$variant" '/^! /{ s = $2; next } s == "variant" && $1 == v && $2 == l ":" { f = 1 } END { exit !f }' "$xkb_rules"
    else
      awk -v l="$layout" '/^! /{ s = $2; next } s == "layout" && $1 == l { f = 1 } END { exit !f }' "$xkb_rules"
    fi || printf '%s\n' "$layout${variant:+:$variant}"
  done)
  [[ -z $unknown ]] || fail "every XKB layout the list names exists in xkeyboard-config" "unknown:"$'\n'"$unknown"
  pass "every XKB layout the list names exists in xkeyboard-config"
else
  skip "every XKB layout the list names exists in xkeyboard-config (no $xkb_rules)"
fi

run_prompt omarchy_prompt_keyboard "1:"
assert_status "$OMARCHY_FORM_BACK" "keyboard prompt reports Esc as back"
assert_returned "keyboard prompt survives Esc under set -e"

run_prompt omarchy_prompt_keyboard "130:"
assert_status "$OMARCHY_FORM_SIGNAL" "keyboard prompt reports Ctrl+C as the caller's signal"
assert_returned "keyboard prompt survives Ctrl+C under set -e"
pass "keyboard prompt propagates Esc and Ctrl+C without dying under set -e"

# Username

TAKEN_USERS=dhh run_prompt omarchy_prompt_username "0:Not A Username" "0:root" "0:cups-browsed" "0:dhh" "0:david"
assert_status 0 "username prompt accepts a valid name"
[[ $(field username) == "david" ]] || fail "username prompt keeps re-asking until the name is valid"
assert_notices "username prompt explains each rejection" "Username must be alphanumeric with no spaces
Username is reserved for system
Username is reserved for system
That username already exists on this machine"
pass "username prompt rejects malformed, reserved, and taken names"

run_prompt omarchy_prompt_username "1:"
assert_status "$OMARCHY_FORM_BACK" "username prompt reports Esc as back"
assert_returned "username prompt survives Esc under set -e"

run_prompt omarchy_prompt_username "130:"
assert_status "$OMARCHY_FORM_SIGNAL" "username prompt reports Ctrl+C as the caller's signal"
assert_returned "username prompt survives Ctrl+C under set -e"
pass "username prompt propagates Esc and Ctrl+C without dying under set -e"

# Password

run_prompt omarchy_prompt_password "0:one" "0:two" "0:" "0:" "0:s3cret" "0:s3cret"
assert_status 0 "password prompt accepts a confirmed password"
[[ $(field password) == "s3cret" ]] || fail "password prompt keeps the confirmed password"
assert_notices "password prompt explains each rejection" "Passwords didn't match!
Your password can't be blank!"
pass "password prompt rejects mismatched and blank passwords"

run_prompt omarchy_prompt_password "0:s3cret" "1:"
assert_status "$OMARCHY_FORM_BACK" "password prompt reports Esc on the confirmation as back"
assert_returned "password confirmation survives Esc under set -e"

run_prompt omarchy_prompt_password "0:s3cret" "130:"
assert_status "$OMARCHY_FORM_SIGNAL" "password prompt reports Ctrl+C on the confirmation as the caller's signal"
assert_returned "password confirmation survives Ctrl+C under set -e"
pass "password confirmation propagates Esc and Ctrl+C without dying under set -e"

# Identity — both fields are skippable, so empty is an answer and not a cancel

run_prompt omarchy_prompt_identity "0:" "0:"
assert_status 0 "identity prompt treats empty fields as answers"
[[ -z $(field full_name) && -z $(field email_address) ]] || fail "identity prompt leaves skipped fields empty"
pass "identity prompt accepts skipped fields"

run_prompt omarchy_prompt_identity "0:David" "1:"
assert_status "$OMARCHY_FORM_BACK" "identity prompt reports Esc on the email as back"
assert_returned "identity prompt survives Esc under set -e"
pass "identity prompt propagates Esc from its second field"

# Hostname

run_prompt omarchy_prompt_hostname "0:-nope-" "0:workshop"
assert_status 0 "hostname prompt accepts a valid hostname"
[[ $(field hostname) == "workshop" ]] || fail "hostname prompt keeps re-asking until the hostname is valid"
assert_notices "hostname prompt explains the rejection" "Hostname must be 1-63 letters, digits, or dashes, and cannot start or end with a dash"

run_prompt omarchy_prompt_hostname "0:"
assert_status 0 "hostname prompt accepts an empty hostname"
[[ $(field hostname) == "$OMARCHY_HOSTNAME_DEFAULT" ]] || fail "hostname prompt falls back to the default hostname"
pass "hostname prompt rejects malformed names and defaults an empty one"

run_prompt omarchy_prompt_hostname "1:"
assert_status "$OMARCHY_FORM_BACK" "hostname prompt reports Esc as back"
assert_returned "hostname prompt survives Esc under set -e"
pass "hostname prompt propagates Esc without dying under set -e"

# Timezone

TZ_GUESS=Europe/Copenhagen run_prompt omarchy_prompt_timezone "0:Europe/Copenhagen"
assert_status 0 "timezone prompt accepts the geo guess"
[[ $(field timezone) == "Europe/Copenhagen" ]] || fail "timezone prompt keeps the chosen timezone"
grep -qF -- '--selected Europe/Copenhagen' "$GUM_ARGS" || fail "timezone prompt preselects the geo guess"
grep -qF UTC "$tmp_dir/stdin.1" || fail "timezone prompt offers the system timezone list"
pass "timezone prompt preselects the geo guess when one is available"

# An unnetworked first boot has no guess, and the fallback has to survive `set -e`
run_prompt omarchy_prompt_timezone "0:America/Chicago"
assert_status 0 "timezone prompt survives a failed geo guess"
[[ $(field timezone) == "America/Chicago" ]] || fail "timezone prompt keeps the filtered timezone"
[[ $(head -n 1 "$GUM_ARGS") == filter* ]] || fail "timezone prompt filters when there is no geo guess"
pass "timezone prompt falls back to filtering when the geo guess fails"

run_prompt omarchy_prompt_timezone "0:"
assert_status 0 "timezone prompt accepts an empty selection"
[[ $(field timezone) == "UTC" ]] || fail "timezone prompt falls back to UTC"
pass "timezone prompt falls back to UTC when nothing is selected"

run_prompt omarchy_prompt_timezone "1:"
assert_status "$OMARCHY_FORM_BACK" "timezone prompt reports Esc as back"
assert_returned "timezone prompt survives Esc under set -e"

TZ_GUESS=Europe/Copenhagen run_prompt omarchy_prompt_timezone "130:"
assert_status "$OMARCHY_FORM_SIGNAL" "timezone prompt reports Ctrl+C as the caller's signal"
assert_returned "timezone prompt survives Ctrl+C under set -e"
pass "timezone prompt propagates Esc and Ctrl+C without dying under set -e"
