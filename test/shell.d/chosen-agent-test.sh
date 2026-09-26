#!/bin/bash

source "$(dirname "$0")/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

mock_bin="$test_tmp/bin"
home="$test_tmp/home"
mkdir -p "$mock_bin" "$home/.local/state/omarchy"

cat >"$mock_bin/omarchy-default-agent" <<'SH'
#!/bin/bash
[[ -n ${DEFAULT_AGENT:-} ]] && echo "$DEFAULT_AGENT"
exit 0
SH
cat >"$mock_bin/omarchy-notification-send" <<'SH'
#!/bin/bash
printf '%s\n' "$@" >"$NOTIFICATION_LOG"
SH
chmod +x "$mock_bin"/*

marker="$home/.local/state/omarchy/first-run-agent"
log="$test_tmp/notification"

run_step() {
  rm -f "$log"
  HOME="$home" PATH="$mock_bin:$PATH" NOTIFICATION_LOG="$log" "$@" \
    bash "$ROOT/install/user/first-run/chosen-agent.sh"
}

run_step
[[ ! -e $log ]] || fail "no chosen agent sends nothing"
pass "without a chosen agent, first run offers nothing"

echo claude >"$marker"
run_step
grep -qx "Install claude" "$log" || fail "the chosen agent is offered by name" "$(cat "$log" 2>/dev/null)"
grep -qx -- "--exec" "$log" || fail "the notification installs it on click"
[[ $(tail -3 "$log" | tr '\n' ' ') == "omarchy-default-agent --install claude " ]] ||
  fail "a click runs the agent's own installer" "$(tail -3 "$log")"
[[ ! -e $marker ]] || fail "the choice is offered once"
pass "the agent chosen at install is offered once, and a click installs it"

echo codex >"$marker"
run_step env DEFAULT_AGENT=claude
[[ ! -e $log ]] || fail "an agent already set is not overridden"
[[ ! -e $marker ]] || fail "the choice is cleared even when not offered"
pass "an agent chosen since then wins"
