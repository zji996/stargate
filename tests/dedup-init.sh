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
echo "dedup init handover tests passed"
