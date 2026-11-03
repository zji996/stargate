#!/bin/sh
# The front's init script with a fake cgroup, procd and front processes: a
# handover raises the memory limit for the old front, and lowers it again
# once that front has exited.
set -eu
repo_dir="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
lab="$(mktemp -d)"
sleepers=""
trap 'for p in $sleepers; do kill "$p" 2>/dev/null || true; done; rm -rf "$lab"' EXIT

# shellcheck source=/dev/null
. "$repo_dir/luci-app-stargate/root/etc/init.d/stargate-dedup"
cgroup_root="$lab/cgroup"
meminfo="$lab/meminfo"
instance_file="$lab/instance"
dedup_cli="$lab/dedup.sh"
mkdir -p "$cgroup_root/services/stargate-dedup"
echo memory >"$cgroup_root/cgroup.controllers"
echo memory >"$cgroup_root/cgroup.subtree_control"
echo memory >"$cgroup_root/services/cgroup.subtree_control"
mib() { echo $(($1 << 20)); }
mib 171 >"$cgroup_root/services/stargate-dedup/memory.current"
echo "MemAvailable:     $((377 << 10)) kB" >"$meminfo"
uci() { return 1; } # memory_mib unset: 300
procd_open_instance() { echo "$1" >"$lab/opened"; }
procd_set_param() { :; }
procd_close_instance() { :; }
old_fronts=""
pgrep() { [ -z "$old_fronts" ] || printf '%s\n' $old_fronts; }
front_args() {
  printf '#!/bin/sh\necho "%s -listen 127.0.0.1:10860"\n' "$1" >"$dedup_cli"
  chmod +x "$dedup_cli"
}
limit_now() { cat "$cgroup_root/services/stargate-dedup/memory.max"; }
expect() {
  [ "$(limit_now)" = "$(mib "$1")" ] || { echo "$2: limit $(($(limit_now) >> 20)) MiB, want $1" >&2; exit 1; }
}
wait_limit() {
  for _ in $(seq 50); do
    [ "$(limit_now)" = "$(mib "$1")" ] && return 0
    sleep 0.1
  done
  expect "$1" "$2"
}
# Stands in for a running front; sets $pid.
sleeper() {
  sleep 30 >/dev/null 2>&1 &
  pid=$!
  sleepers="$sleepers $pid"
}

# reload must only signal running fronts that read the reverse lists. Record
# the signals instead of sending them, so a start, stop or new instance would
# show up as a failure.
signals=""
reverse_fronts=""
front_cmdline() {
  case " $reverse_fronts " in
    *" $1 "*) echo "/usr/bin/stargate-dedup front -listen 127.0.0.1:10860 -reverse 10.0.0.1:10863 -reverse-origins /x" ;;
    *) echo "/usr/bin/stargate-dedup front -listen 127.0.0.1:10860 -reverse-origins-is-not-the-flag" ;;
  esac
}
signal_failure=0
signal_front() { signals="$signals $1"; [ "$signal_failure" = 0 ]; }

[ "$(handover_max "$(mib 300)" "$(mib 171)" "$(mib 377)")" = "$(mib 471)" ]
# Little free memory: only what is there, never below the usual limit.
[ "$(handover_max "$(mib 300)" "$(mib 171)" "$(mib 200)")" = "$(mib 307)" ]
[ "$(handover_max "$(mib 300)" "$(mib 171)" "$(mib 100)")" = "$(mib 300)" ]

# First start: nothing to hand over.
front_args front_aaa
start_service
expect 300 "first start"
[ "$(cat "$lab/opened")" = front_aaa ]

# Same instance again: no handover.
sleeper
old_fronts=$pid
start_service
expect 300 "unchanged front"

# Changed front: room for the old one until it exits.
front_args front_bbb
start_service
expect 471 "handover"
kill $old_fronts
wait_limit 300 "after the old front exited"

# A later handover keeps its raised limit when an earlier one's old front exits.
sleeper
first=$pid
old_fronts=$first
front_args front_ccc
start_service
expect 471 "second handover"
sleeper
old_fronts=$pid
front_args front_ddd
start_service
kill "$first"
sleep 1.5
expect 471 "superseded restore"
kill $old_fronts
wait_limit 300 "after the last old front exited"

# reload: one HUP to each front started with -reverse, and nothing else.
instances_before="$(cat "$lab/opened")"
served_before="$(cat "$cgroup_root/services/stargate-dedup/memory.max")"
old_fronts="101 102"
reverse_fronts="102"
reload_service
[ "$signals" = " 102" ] || { echo "reload signalled '$signals', want only the -reverse front 102" >&2; exit 1; }
[ "$(cat "$lab/opened")" = "$instances_before" ] || { echo 'reload opened an instance' >&2; exit 1; }
[ "$(cat "$cgroup_root/services/stargate-dedup/memory.max")" = "$served_before" ] ||
  { echo 'reload changed the memory limit' >&2; exit 1; }
# Only an older front (or one draining from before -reverse): SIGHUP would end
# it, so nothing is signalled and reload fails.
signals=""
reverse_fronts=""
if reload_service 2>/dev/null; then echo 'reload without a -reverse front succeeded' >&2; exit 1; fi
[ -z "$signals" ] || { echo "reload signalled an older front: '$signals'" >&2; exit 1; }
# No front at all: nothing to reload, not an error.
old_fronts=""
reload_service
[ -z "$signals" ] || { echo "reload without a front signalled '$signals'" >&2; exit 1; }
# A -reverse front that does not take the signal is a real failure.
old_fronts="103"
reverse_fronts="103"
signal_failure=1
if reload_service 2>/dev/null; then echo 'a failed signal to a running front was reported as success' >&2; exit 1; fi
signal_failure=0
old_fronts=""
echo "dedup init handover tests passed"
