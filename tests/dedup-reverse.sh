#!/bin/sh
# The reverse command of dedup.sh, with an isolated UCI store, list directory,
# init script and front state: add/remove/list, the atomic list file, exactly
# one SIGHUP per change, and a rollback that restores both UCI and the file.
set -eu
repo_dir="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
LAB_ROOT="$(mktemp -d)"
export LAB_ROOT
LAB_LIB_DIR="$repo_dir/luci-app-stargate/root/usr/share/stargate/lib"
export LAB_LIB_DIR
trap 'rm -rf "$LAB_ROOT"' EXIT

# The real command functions, without the dispatcher at the end.
sed -n '/^die() {/,/^action=/p' "$repo_dir/luci-app-stargate/root/usr/share/stargate/dedup.sh" | sed '$d' >"$LAB_ROOT/functions"

cat >"$LAB_ROOT/init" <<'INIT'
#!/bin/sh
set -eu
# reload must only signal: it never starts, stops or replaces an instance.
case "$1" in
  status) test -f "$LAB_ROOT/front" ;;
  reload)
    [ ! -f "$LAB_ROOT/fail-reload" ] || { rm -f "$LAB_ROOT/fail-reload"; exit 1; }
    printf 'reload\n' >>"$LAB_ROOT/reloads"
    printf 'origins: %s\n' "$(cat "$LAB_ROOT/ca/reverse-origins" 2>/dev/null | tr '\n' ' ')" >>"$LAB_ROOT/seen"
    ;;
  start|stop|restart|enable|disable)
    echo "unexpected init call: $1" >&2
    exit 1
    ;;
esac
INIT
chmod +x "$LAB_ROOT/init"

cat >"$LAB_ROOT/runner" <<'RUNNER'
#!/bin/sh
set -eu
for module in common rules config; do
  . "$LAB_LIB_DIR/$module.sh"
done
. "$LAB_ROOT/functions"
app=stargate
script_dir="$LAB_ROOT"
config_file="$LAB_ROOT/config"
dedup_init="$LAB_ROOT/init"
dedup_bin="$LAB_ROOT/bin"
dedup_ca_dir="$LAB_ROOT/ca"
# A UCI store: one file per option, "option\n<value>", so an option can be
# present but empty, as after committing an empty string.
uci_cmd() (
  action="$1"; shift
  case "$action" in
    get)
      if [ -f "$LAB_ROOT/uci/$1" ]; then
        # Like uci: the value without a trailing newline, empty if it is empty.
        printf '%s' "$(sed -n '2p' "$LAB_ROOT/uci/$1")"
      else
        # A section exists while any of its options does; an absent option
        # makes uci -q get fail, which is what the callers test.
        case "$1" in *.*.*) exit 1 ;; esac
        ls "$LAB_ROOT/uci/$1".* >/dev/null 2>&1 || exit 1
        printf 'dedup\n'
      fi ;;
    set)
      key="${1%%=*}"; value="${1#*=}"
      # A section name has two components, its options three.
      case "$key" in *.*.*) printf 'option\n%s\n' "$value" >"$LAB_ROOT/uci/$key" ;; esac ;;
    delete) rm -f "$LAB_ROOT/uci/$1" ;;
  esac
)
uci_get() { uci_cmd get "$app.$1.$2" 2>/dev/null || printf '%s' "$3"; }
uci_commit() { printf 'commit\n' >>"$LAB_ROOT/commits"; }
load_front_config() {
  rules_mode="$(uci_get rules mode blacklist)"
  # generate_config() sets used_ports before validate_dedup_config; do the same
  # so a reverse port colliding with a Stargate port is caught here too.
  used_ports="$(uci_get inbound socks_port '')"
  load_dedup_config
  validate_dedup_config
}
command="$1"; shift
case "$command" in
  reverse) reverse_command "$@" ;;
  front) print_front ;;
  status) dedup_status ;;
  *) "$command" "$@" ;;
esac
RUNNER

hosts_file="$LAB_ROOT/ca/reverse-origins"
auth_file="$LAB_ROOT/ca/reverse.auth"
reset_case() { # <reverse_listen> <reverse_origins>
  rm -rf "$LAB_ROOT/uci" "$LAB_ROOT/ca"
  mkdir -p "$LAB_ROOT/uci/stargate.dedup" "$LAB_ROOT/ca"
  printf 'option\n1\n' >"$LAB_ROOT/uci/stargate.dedup.enabled"
  printf 'option\n192.0.2.1\n' >"$LAB_ROOT/uci/stargate.dedup.devices"
  printf 'option\n10860\n' >"$LAB_ROOT/uci/stargate.dedup.port"
  [ -z "$1" ] || printf 'option\n%s\n' "$1" >"$LAB_ROOT/uci/stargate.dedup.reverse_listen"
  [ -z "$2" ] || printf 'option\n%s\n' "$2" >"$LAB_ROOT/uci/stargate.dedup.reverse_origins"
  printf 'option\nchatgpt.com\n' >"$LAB_ROOT/uci/stargate.dedup.domains"
  touch "$LAB_ROOT/ca/ca.pem" "$LAB_ROOT/front"
  # A front binary is only needed by the argument cases.
  rm -f "$LAB_ROOT/bin"
  if [ "${3:-}" = bin ]; then printf '#!/bin/sh\n' >"$LAB_ROOT/bin"; chmod +x "$LAB_ROOT/bin"; fi
  rm -f "$LAB_ROOT/commits" "$LAB_ROOT/reloads" "$LAB_ROOT/seen"
}
uci_value() { sed -n '2p' "$LAB_ROOT/uci/stargate.dedup.$1" 2>/dev/null || true; }
run_ok() {
  sh "$LAB_ROOT/runner" "$@" >"$LAB_ROOT/log" 2>&1 || { cat "$LAB_ROOT/log" >&2; exit 1; }
}
run_fail() {
  if sh "$LAB_ROOT/runner" "$@" >"$LAB_ROOT/log" 2>&1; then
    cat "$LAB_ROOT/log" >&2
    echo "expected failure: $*" >&2
    exit 1
  fi
}
fail() {
  echo "$*" >&2
  exit 1
}
expect_eq() { # <actual> <expected> <what>
  [ "$1" = "$2" ] || fail "$3: got '$1', want '$2'"
}
reloads() { [ -f "$LAB_ROOT/reloads" ] && wc -l <"$LAB_ROOT/reloads" || echo 0; }
modes() { ls -l "$1" | cut -c1-10; }

# ---- off: the list commands are refused without touching UCI ----------------
reset_case '' 'api.example.com'
run_fail reverse add api.example.org
expect_eq "$(uci_value reverse_origins)" api.example.com "reverse_origins after a refused add"
expect_eq "$(reloads)" 0 "reloads after a refused add"
grep -q 'reverse entry is off' "$LAB_ROOT/log" || fail 'the refusal does not name reverse_listen'
# list still works while off: it only reads.
run_ok reverse list
expect_eq "$(cat "$LAB_ROOT/log")" api.example.com "reverse list while off"

# ---- add: UCI, the file, and exactly one SIGHUP -----------------------------
reset_case 192.0.2.1:10863 'api.example.com'
printf 'api.example.com\n' >"$hosts_file"
printf 'main:stargate-dedup\n' >"$auth_file"
chmod 0640 "$auth_file"
# Uppercase input is normalised; a new host is appended in sorted order.
run_ok reverse add B.Example.NET api.example.com
expect_eq "$(uci_value reverse_origins)" 'api.example.com b.example.net' "reverse_origins after add"
expect_eq "$(cat "$hosts_file")" 'api.example.com
b.example.net' 'the list file after add'
expect_eq "$(modes "$hosts_file")" '-rw-r--r--' 'the list file is 0644'
expect_eq "$(reloads)" 1 'one SIGHUP per change'
expect_eq "$(cat "$LAB_ROOT/commits")" commit 'UCI is committed'
# The front re-read the new list, and the add touched nothing else.
grep -qx 'origins: api.example.com b.example.net ' "$LAB_ROOT/seen" || fail 'the front did not see the new list'
expect_eq "$(stat -c %a "$auth_file")" 640 'remove/add does not rewrite reverse.auth'

# Adding a host that is already there changes nothing and sends no signal.
rm -f "$LAB_ROOT/commits"
run_ok reverse add api.example.com
expect_eq "$(reloads)" 1 'no SIGHUP when the list does not change'
[ ! -f "$LAB_ROOT/commits" ] || fail 'no commit when the list does not change'

# remove
run_ok reverse remove api.example.com
expect_eq "$(uci_value reverse_origins)" b.example.net "reverse_origins after remove"
expect_eq "$(cat "$hosts_file")" b.example.net 'the list file after remove'
expect_eq "$(reloads)" 2 'one SIGHUP per change'
# removing a host that is not there changes nothing
run_ok reverse remove api.example.com
expect_eq "$(reloads)" 2 'no SIGHUP when removing an absent host'
# list prints the rest
run_ok reverse list
expect_eq "$(cat "$LAB_ROOT/log")" b.example.net 'reverse list'

# ---- the file is replaced in place, so the old one is never half-written ----
reset_case 192.0.2.1:10863 'api.example.com'
printf 'api.example.com\n' >"$hosts_file"
inode_before="$(stat -c %i "$hosts_file")"
run_ok reverse add b.example.net
[ "$(stat -c %i "$hosts_file")" != "$inode_before" ] || fail 'the list file was modified in place'
[ -z "$(ls "$LAB_ROOT/ca" | grep -v -x -e ca.pem -e reverse-origins -e reverse.auth || true)" ] ||
  fail 'a temp file was left behind'
# Same content again: the file is not rewritten.
inode_before="$(stat -c %i "$hosts_file")"
printf 'api.example.com\nb.example.net\n' >"$hosts_file"
run_ok reverse add api.example.com
expect_eq "$(stat -c %i "$hosts_file")" "$inode_before" 'an unchanged list is not rewritten'

# ---- an empty list is refused ----------------------------------------------
reset_case 192.0.2.1:10863 'api.example.com'
printf 'api.example.com\n' >"$hosts_file"
run_fail reverse remove api.example.com
grep -q 'clear reverse_listen' "$LAB_ROOT/log" || fail 'removing the last host is not explained'
expect_eq "$(uci_value reverse_origins)" api.example.com "reverse_origins after a refused remove"
expect_eq "$(cat "$hosts_file")" api.example.com 'the list file after a refused remove'
expect_eq "$(reloads)" 0 'no SIGHUP after a refused remove'

# ---- invalid hosts are refused before anything changes ----------------------
# The hosts use the same name check as dedup domains, so a label may not be
# empty and the value may not carry a scheme, a path or shell syntax.
for bad in 'api' 'api..example.com' 'api.example.com;' 'a_b.example.com' \
  'http://api.example.com' 'api.example.com/v1'; do
  reset_case 192.0.2.1:10863 'api.example.com'
  printf 'api.example.com\n' >"$hosts_file"
  run_fail reverse add "$bad"
  grep -q 'invalid reverse origin' "$LAB_ROOT/log" || fail "an invalid host is not named: $bad"
  expect_eq "$(uci_value reverse_origins)" api.example.com "reverse_origins after refusing $bad"
  expect_eq "$(cat "$hosts_file")" api.example.com "the list file after refusing $bad"
  expect_eq "$(reloads)" 0 "no SIGHUP after refusing $bad"
done
run_fail reverse
grep -q 'reverse requires' "$LAB_ROOT/log" || fail 'a missing mode is not explained'
run_fail reverse add
grep -q 'which hosts' "$LAB_ROOT/log" || fail 'a missing host is not explained'
run_fail reverse list api.example.com
grep -q 'takes no hosts' "$LAB_ROOT/log" || fail 'reverse list with a host is not refused'

# ---- a failed SIGHUP restores the UCI text and the old file ----------------
reset_case 192.0.2.1:10863 'api.example.com'
printf 'api.example.com\n' >"$hosts_file"
printf 'main:stargate-dedup\n' >"$auth_file"
touch "$LAB_ROOT/fail-reload"
run_fail reverse add b.example.net
grep -q 'previous list restored' "$LAB_ROOT/log" || fail 'a failed reload is not reported as restored'
expect_eq "$(uci_value reverse_origins)" api.example.com "reverse_origins after a failed reload"
expect_eq "$(cat "$hosts_file")" api.example.com 'the list file after a failed reload'
expect_eq "$(cat "$auth_file")" 'main:stargate-dedup' 'reverse.auth after a failed reload'

# The same when reverse_origins was absent: it must be absent again.
reset_case 192.0.2.1:10863 ''
rm -f "$hosts_file"
touch "$LAB_ROOT/fail-reload"
run_fail reverse add b.example.net
[ ! -f "$LAB_ROOT/uci/stargate.dedup.reverse_origins" ] || fail 'an absent reverse_origins came back'
[ ! -f "$hosts_file" ] || fail 'the list file appeared although there was none'

# ---- no front running: the file is written, nothing is signalled -----------
reset_case 192.0.2.1:10863 'api.example.com'
printf 'api.example.com\n' >"$hosts_file"
rm -f "$LAB_ROOT/front"
run_ok reverse add b.example.net
expect_eq "$(cat "$hosts_file")" 'api.example.com
b.example.net' 'the list file without a front'
expect_eq "$(reloads)" 0 'no SIGHUP without a front'

# ---- status reports the reverse entry and its counters ---------------------
reset_case 192.0.2.1:10863 'api.example.com b.example.net'
rm -f "$LAB_ROOT/front"
run_ok status
grep -qx 'reverse: 192.0.2.1:10863' "$LAB_ROOT/log" || fail 'status lacks the reverse listener'
grep -q 'reverse origins:' "$LAB_ROOT/log" || { cat "$LAB_ROOT/log" >&2; fail 'status lacks the reverse origins'; }
reset_case '' ''
run_ok status
grep -qx 'reverse: off' "$LAB_ROOT/log" || fail 'status does not say the reverse entry is off'
grep -qx 'reverse origins: none' "$LAB_ROOT/log" || fail 'status does not say there are no origins'

# ---- validation of the options themselves ---------------------------------
reset_case '192.0.2.1' 'api.example.com' bin
run_fail front
grep -q 'address and a port' "$LAB_ROOT/log" || fail 'a listener without a port is accepted'
reset_case '192.0.2.1:10861' 'api.example.com' bin
run_fail front
grep -q 'conflicts with the dedup ports' "$LAB_ROOT/log" || fail 'a listener on a dedup port is accepted'
reset_case '192.0.2.1:10862' 'api.example.com' bin
run_fail front
grep -q 'conflicts with the dedup ports' "$LAB_ROOT/log" || fail 'a listener on the stats port is accepted'
reset_case '192.0.2.1:10863' 'api.example.com' bin
printf 'option\n10863\n' >"$LAB_ROOT/uci/stargate.inbound.socks_port"
run_fail front
grep -q 'conflicts with another Stargate port' "$LAB_ROOT/log" || fail 'a listener on another Stargate port is accepted'
reset_case '192.0.2.1:10863' '' bin
run_fail front
grep -q 'reverse_origins are required' "$LAB_ROOT/log" || fail 'a listener without hosts is accepted'
reset_case '192.0.2.1:99999' 'api.example.com' bin
run_fail front
grep -q 'reverse listen port must be between' "$LAB_ROOT/log" || fail 'an out-of-range port is accepted'
reset_case '192.0.2.300:10863' 'api.example.com' bin
run_fail front
grep -q 'reverse listen address must be' "$LAB_ROOT/log" || fail 'an invalid address is accepted'
reset_case '192.0.2.1:10863' 'api..example.com' bin
run_fail front
grep -q 'invalid reverse origin' "$LAB_ROOT/log" || fail 'an invalid origin is accepted'

# ---- the front's arguments: identical while off, four options when on -------
# The instance name is the arguments' hash, so an unchanged argument list is
# what keeps a live front from being replaced.
off_args='front -listen 127.0.0.1:10860 -via socks5://127.0.0.1:10861 -admin 127.0.0.1:10862 -ca-dir CA -domains chatgpt.com -compress auto -index-mib 230 -inflight-mib 128 -memory-mib 220 -linger 3s'
reset_case '' '' bin
run_ok front
off_line="$(cat "$LAB_ROOT/log")"
[ "${off_line#* }" = "$(printf '%s' "$off_args" | sed "s|CA|$LAB_ROOT/ca|")" ] ||
  fail "the arguments while off changed: $off_line"
off_instance="${off_line%% *}"
# A list may be present while off; it must not add an argument.
printf 'api.example.com\n' >"$hosts_file"
run_ok front
expect_eq "$(cat "$LAB_ROOT/log")" "$off_line" 'an existing list changes the arguments while off'

reset_case 192.0.2.1:10863 'api.example.com' bin
run_ok front
on_line="$(cat "$LAB_ROOT/log")"
case "$on_line" in
  *" -reverse 192.0.2.1:10863 -reverse-origins $hosts_file -reverse-auth $auth_file -reverse-allow 192.0.2.1") ;;
  *) fail "the arguments while on lack the reverse options: $on_line" ;;
esac
[ "${on_line%% *}" != "$off_instance" ] || fail 'turning the reverse entry on keeps the instance name'
# The front's state is written for it, with the modes the front expects.
expect_eq "$(cat "$hosts_file")" api.example.com 'the origins file from the front'
expect_eq "$(modes "$hosts_file")" '-rw-r--r--' 'the origins file is 0644'
expect_eq "$(cat "$auth_file")" 'main:stargate-dedup' 'the credentials file'
expect_eq "$(modes "$auth_file")" '-rw-------' 'the credentials file is 0600'
# Several hosts, several devices.
printf 'option\n192.0.2.1 192.0.2.0/24\n' >"$LAB_ROOT/uci/stargate.dedup.devices"
printf 'option\napi.example.com b.example.net\n' >"$LAB_ROOT/uci/stargate.dedup.reverse_origins"
run_ok front
case "$(cat "$LAB_ROOT/log")" in
  *' -reverse-allow 192.0.2.1,192.0.2.0/24') ;;
  *) fail "devices are not comma separated: $(cat "$LAB_ROOT/log")" ;;
esac
expect_eq "$(cat "$hosts_file")" 'api.example.com
b.example.net' 'several hosts, one per line'
# Unchanged content: the file is left as it is.
inode_before="$(stat -c %i "$hosts_file")"
run_ok front
expect_eq "$(stat -c %i "$hosts_file")" "$inode_before" 'an unchanged origins file is not rewritten'

echo "dedup reverse: all checks passed"
