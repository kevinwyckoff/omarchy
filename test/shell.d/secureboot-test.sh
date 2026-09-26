#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq

# The vendored engine's own suites, run against the renamed copy that ships
# (install/secureboot/VENDORED records the pin and the renames).
for suite in common limine sign status firmware windows commands; do
  output=$(bash "$ROOT/test/secureboot/$suite.sh" 2>&1) || fail "secureboot $suite suite passes" "$output"
  pass "secureboot ${output##*$'\n'}"
done

tmp_dir=$(mktemp -d)
trap 'rm -r "$tmp_dir"' EXIT

# The hook runs the engine as root at every kernel install, so an engine the
# user can edit, like this checkout, is refused before sudo is asked for.
mkdir -p "$tmp_dir/bin"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"%s/sudo-calls"\n' "$tmp_dir" >"$tmp_dir/bin/sudo"
chmod 755 "$tmp_dir/bin/sudo"
if (( EUID == 0 )); then
  skip "integration refuses an engine others can change (running as root)"
else
  status=0
  output=$(OMARCHY_PATH=$ROOT PATH="$tmp_dir/bin:$PATH" "$ROOT/bin/omarchy-secureboot-integrate" 2>&1) || status=$?
  (( status == 1 )) && [[ $output == *"can be changed by someone other than root"* ]] ||
    fail "integration refuses an engine others can change" "$output"
  [[ ! -e $tmp_dir/sudo-calls ]] || fail "integration refuses before asking for sudo" "$(<"$tmp_dir/sudo-calls")"
  pass "integration refuses an engine others can change"
fi

status=0
OMARCHY_PATH=$ROOT PATH="$tmp_dir/bin:$PATH" "$ROOT/bin/omarchy-secureboot-integrate" --bogus 2>/dev/null || status=$?
(( status == 2 )) || fail "integration rejects unknown arguments"
pass "integration rejects unknown arguments"

# Each template the integration renders names the engine by the path it
# substitutes.
for template in limine/90-omarchy-secureboot-sign systemd/omarchy-secureboot-watch@.service; do
  grep -q '@BINDIR@/omarchy-secureboot ' "$ROOT/install/secureboot/$template" ||
    fail "$template calls the engine through @BINDIR@"
done
pass "templates call the engine through @BINDIR@"
