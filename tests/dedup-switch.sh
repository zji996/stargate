#!/bin/sh
# Exercise the real switch functions with isolated UCI, init and runtime peers.
set -eu
repo_dir="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
LAB_ROOT="$(mktemp -d)"
export LAB_ROOT
trap 'rm -rf "$LAB_ROOT"' EXIT
sed -n '/^die() {/,/^action=/p' "$repo_dir/luci-app-stargate/root/usr/share/stargate/dedup.sh" | sed '$d' > "$LAB_ROOT/functions"
cat > "$LAB_ROOT/init" <<'INIT'
#!/bin/sh
set -eu
case "$1" in
  enabled) test -f "$LAB_ROOT/enabled" ;;
  status) test -f "$LAB_ROOT/front" ;;
  enable) touch "$LAB_ROOT/enabled" ;;
  disable) rm -f "$LAB_ROOT/enabled" ;;
  start|stop)
    if [ -f "$LAB_ROOT/fail-$1" ]; then rm "$LAB_ROOT/fail-$1"; exit 1; fi
    if [ "$1" = start ]; then touch "$LAB_ROOT/front"; else rm -f "$LAB_ROOT/front"; fi ;;
esac
INIT
cat > "$LAB_ROOT/stargate.sh" <<'RUNTIME'
#!/bin/sh
set -eu
printf 'apply\n' >> "$LAB_ROOT/applies"
if [ -f "$LAB_ROOT/fail-apply" ]; then
  rm "$LAB_ROOT/fail-apply"
  rm -f "$LAB_ROOT/runtime"
  exit 1
fi
if [ -f "$LAB_ROOT/fallback" ]; then rm "$LAB_ROOT/fallback"; exit 0; fi
cat "$LAB_ROOT/uci/stargate.dedup.enabled" > "$LAB_ROOT/config"
touch "$LAB_ROOT/runtime"
RUNTIME
cat > "$LAB_ROOT/stargate-init" <<'SERVICE'
#!/bin/sh
test -f "$LAB_ROOT/runtime"
SERVICE
cat > "$LAB_ROOT/runner" <<'RUNNER'
#!/bin/sh
set -eu
. "$LAB_ROOT/functions"
app=stargate
script_dir="$LAB_ROOT"
config_file="$LAB_ROOT/config"
dedup_init="$LAB_ROOT/init"
stargate_init="$LAB_ROOT/stargate-init"
dedup_bin=/bin/false
dedup_ca_dir="$LAB_ROOT/ca"
uci_cmd() (
  action="$1"; shift
  file="$LAB_ROOT/uci/${1%%=*}"
  case "$action" in
    get) cat "$file" ;;
    set) printf '%s\n' "${1#*=}" > "$file" ;;
    delete) rm -f "$file" "$file".* ;;
  esac
)
uci_get() { uci_cmd get "$app.$1.$2" 2>/dev/null || printf '%s' "$3"; }
uci_commit() { :; }
bool_value() { printf '%s' "$1"; }
load_front_config() { dedup_port=10860; dedup_domains=lab.test; }
wait_front() { test -f "$LAB_ROOT/front"; }
generate_config() {
  uci_get dedup enabled 0 > "$LAB_ROOT/next"
  printf '%s\n' "$LAB_ROOT/next"
}
command="$1"; shift
switch_transaction "dedup_$command" "$@"
RUNNER
chmod +x "$LAB_ROOT/init" "$LAB_ROOT/stargate.sh" "$LAB_ROOT/stargate-init"
reset_case() {
  rm -rf "$LAB_ROOT/uci" "$LAB_ROOT/ca"
  mkdir "$LAB_ROOT/uci" "$LAB_ROOT/ca"
  touch "$LAB_ROOT/ca/ca.pem" "$LAB_ROOT/runtime"
  rm -f "$LAB_ROOT/front" "$LAB_ROOT/enabled" "$LAB_ROOT/applies"
  printf '1\n' > "$LAB_ROOT/uci/stargate.global.enabled"
  printf 'dedup\n' > "$LAB_ROOT/uci/stargate.dedup"
  printf '%s\n' "$1" > "$LAB_ROOT/uci/stargate.dedup.enabled"
  printf '192.0.2.1\n' > "$LAB_ROOT/uci/stargate.dedup.devices"
  printf '%s\n' "$1" > "$LAB_ROOT/config"
  if [ "$1" = 1 ]; then touch "$LAB_ROOT/front" "$LAB_ROOT/enabled"; fi
}
run_ok() { sh "$LAB_ROOT/runner" "$@" > "$LAB_ROOT/log" 2>&1 || { cat "$LAB_ROOT/log"; exit 1; }; }
run_fail() {
  if sh "$LAB_ROOT/runner" "$@" > "$LAB_ROOT/log" 2>&1; then cat "$LAB_ROOT/log"; echo 'expected failure' >&2; exit 1; fi
  grep -q 'previous settings and runtime restored' "$LAB_ROOT/log"
}
assert_state() {
  test "$(cat "$LAB_ROOT/uci/stargate.dedup.enabled")" = "$1"
  test "$(cat "$LAB_ROOT/config")" = "$1"
  test -f "$LAB_ROOT/runtime"
  if [ "$1" = 1 ]; then test -f "$LAB_ROOT/front"; test -f "$LAB_ROOT/enabled"
  else test ! -f "$LAB_ROOT/front"; test ! -f "$LAB_ROOT/enabled"; fi
}
# Real happy path, remembered devices, and idempotence.
reset_case 0
run_ok on
assert_state 1
run_ok on
[ "$(wc -l < "$LAB_ROOT/applies")" -eq 1 ]
run_ok off
assert_state 0
run_ok off
assert_state 0
# Already absent from procd: stop may fail while there is nothing to stop.
touch "$LAB_ROOT/fail-stop"
run_ok off
assert_state 0
# Fail before steering, including CA creation and a missing original section.
reset_case 0
touch "$LAB_ROOT/fail-start"
run_fail on 192.0.2.2
assert_state 0
[ "$(cat "$LAB_ROOT/uci/stargate.dedup.devices")" = 192.0.2.1 ]
rm "$LAB_ROOT/ca/ca.pem" "$LAB_ROOT/uci/stargate.dedup" "$LAB_ROOT/uci/stargate.dedup.enabled" "$LAB_ROOT/uci/stargate.dedup.devices"
run_fail on 192.0.2.2
[ ! -f "$LAB_ROOT/uci/stargate.dedup" ]
# An existing front is restored too when updating its device list fails.
reset_case 1
touch "$LAB_ROOT/fail-start"
run_fail on 192.0.2.2
assert_state 1
[ "$(cat "$LAB_ROOT/uci/stargate.dedup.devices")" = 192.0.2.1 ]
# Explicit empty options stay present, absent ones stay absent.
reset_case 0
: > "$LAB_ROOT/uci/stargate.dedup.devices"
rm "$LAB_ROOT/uci/stargate.dedup.enabled" "$LAB_ROOT/ca/ca.pem"
run_fail on 192.0.2.2
[ -f "$LAB_ROOT/uci/stargate.dedup.devices" ]
[ "$(cat "$LAB_ROOT/uci/stargate.dedup.devices")" = "" ]
[ ! -f "$LAB_ROOT/uci/stargate.dedup.enabled" ]
# Apply failures can leave an unchanged file and a stopped runtime.
for direction in on off; do
  if [ "$direction" = on ]; then previous=0; else previous=1; fi
  reset_case "$previous"
  touch "$LAB_ROOT/fail-apply"
  run_fail "$direction"
  assert_state "$previous"
  [ "$(wc -l < "$LAB_ROOT/applies")" -eq 2 ]
done
# A helper returning success after falling back is also a failed switch.
reset_case 0
touch "$LAB_ROOT/fallback"
run_fail on
assert_state 0
# Stopping the front is part of off and must roll back if it fails.
reset_case 1
touch "$LAB_ROOT/fail-stop"
run_fail off
assert_state 1
# Configure applies devices and targets together, restoring even target absence.
reset_case 1
run_ok configure 1 192.0.2.2 api.openai.com
assert_state 1
[ "$(cat "$LAB_ROOT/uci/stargate.dedup.devices")" = 192.0.2.2 ]
[ "$(cat "$LAB_ROOT/uci/stargate.dedup.targets")" = api.openai.com ]
touch "$LAB_ROOT/fail-start"
run_fail configure 1 192.0.2.3 chatgpt.com
assert_state 1
[ "$(cat "$LAB_ROOT/uci/stargate.dedup.devices")" = 192.0.2.2 ]
[ "$(cat "$LAB_ROOT/uci/stargate.dedup.targets")" = api.openai.com ]
reset_case 0
touch "$LAB_ROOT/fail-apply"
run_fail configure 1 192.0.2.2 api.openai.com
assert_state 0
[ ! -f "$LAB_ROOT/uci/stargate.dedup.targets" ]
reset_case 1
run_ok configure 0 192.0.2.3 api.openai.com
assert_state 0
[ "$(cat "$LAB_ROOT/uci/stargate.dedup.devices")" = 192.0.2.3 ]
run_ok configure 0 '' ''
assert_state 0
[ "$(cat "$LAB_ROOT/uci/stargate.dedup.devices")" = '' ]
[ "$(cat "$LAB_ROOT/uci/stargate.dedup.targets")" = none ]
run_fail configure 1 '' api.openai.com
assert_state 0
run_fail configure 1 ' , ' api.openai.com
assert_state 0
printf 'dedup switch: all transaction checks passed\n'
