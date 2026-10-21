#!/bin/sh
set -eu
base=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
state="$base/state"
agent="$base/stargate-remote"
singbox="$base/sing-box"
frpc="$base/frpc"
chmod 700 "$state"
chmod 755 "$agent" "$singbox" "$frpc"
if [ ! -f "$state/profile.json" ]; then
  "$agent" enroll --dir "$state" --link-file "$base/enrollment.link" --sing-box "$singbox" --frpc "$frpc"
fi
"$agent" prepare --dir "$state" --sing-box "$singbox" --frpc "$frpc"
transport_pid=''
frpc_pid=''
watch_pid=''
cleanup() {
  trap - EXIT HUP INT TERM
  [ -z "$watch_pid" ] || kill "$watch_pid" 2>/dev/null || true
  [ -z "$frpc_pid" ] || kill "$frpc_pid" 2>/dev/null || true
  [ -z "$transport_pid" ] || kill "$transport_pid" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 0' HUP INT TERM
"$singbox" run -c "$state/transport.json" &
transport_pid=$!
"$frpc" -c "$state/frpc.json" &
frpc_pid=$!
sleep 2
"$agent" watch --dir "$state" --sing-box "$singbox" --frpc "$frpc" &
watch_pid=$!
printf 'Remote access started. Keep this terminal open.\n'
while kill -0 "$transport_pid" 2>/dev/null && kill -0 "$frpc_pid" 2>/dev/null && kill -0 "$watch_pid" 2>/dev/null; do
  sleep 3
done
echo 'A remote-access process exited; stopping the remaining processes.' >&2
exit 1
