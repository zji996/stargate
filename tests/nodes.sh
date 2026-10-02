#!/bin/sh
set -eu
repo_dir="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
. "$repo_dir/luci-app-stargate/root/usr/share/stargate/lib/common.sh"
. "$repo_dir/luci-app-stargate/root/usr/share/stargate/lib/nodes.sh"

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
app="stargate"

# Mock in-memory UCI state
state_file="$test_dir/uci.state"
: > "$state_file"

uci_get() {
  sec="$1"
  opt="$2"
  def="${3:-}"
  val="$(grep "^$sec\.$opt=" "$state_file" 2>/dev/null | cut -d= -f2- || true)"
  if [ -n "$val" ]; then
    printf '%s' "$val"
  else
    printf '%s' "$def"
  fi
}

uci_cmd() {
  cmd="$1"
  arg="$2"
  if [ "$cmd" = "set" ]; then
    key="${arg%%=*}"
    val="${arg#*=}"
    # strip app prefix if present
    key="${key#$app.}"
    grep -v "^$key=" "$state_file" > "$state_file.tmp" 2>/dev/null || true
    printf '%s=%s\n' "$key" "$val" >> "$state_file.tmp"
    mv "$state_file.tmp" "$state_file"
  elif [ "$cmd" = "delete" ]; then
    key="${arg#$app.}"
    grep -v "^$key\." "$state_file" > "$state_file.tmp" 2>/dev/null || true
    mv "$state_file.tmp" "$state_file"
  fi
}

uci_commit() {
  :
}

list_node_item_ids() {
  grep '\.type=anytls' "$state_file" 2>/dev/null | cut -d. -f1 | sort -u
}

runtime_calls="$test_dir/runtime.calls"
runtime_result=success
apply_runtime_state() {
  printf '%s\n' "$(uci_get node server '')" >> "$runtime_calls"
  [ "$runtime_result" = success ]
}

# Initial setup: main inbounds and two nodes
uci_cmd set "$app.global.enabled=1"
uci_cmd set "$app.inbound.socks_port=10808"
uci_cmd set "$app.inbound.http_port=10809"
uci_cmd set "$app.inbound.transparent_port=12345"
uci_cmd set "$app.dns.hijack_port=1053"

uci_cmd set "$app.node_a=node_item"
uci_cmd set "$app.node_a.type=anytls"
uci_cmd set "$app.node_a.label=Node-A"
uci_cmd set "$app.node_a.server=a.example.com"
uci_cmd set "$app.node_a.server_port=443"
uci_cmd set "$app.node_a.password=pass-a"
uci_cmd set "$app.node_a.enable_port=0"

uci_cmd set "$app.node_b=node_item"
uci_cmd set "$app.node_b.type=anytls"
uci_cmd set "$app.node_b.label=Node-B"
uci_cmd set "$app.node_b.server=b.example.com"
uci_cmd set "$app.node_b.server_port=443"
uci_cmd set "$app.node_b.password=pass-b"
uci_cmd set "$app.node_b.enable_port=0"

uci_cmd set "$app.node=node"
uci_cmd set "$app.node.type=anytls"
uci_cmd set "$app.node.label=Node-A"
uci_cmd set "$app.node.server=a.example.com"
uci_cmd set "$app.node.server_port=443"
uci_cmd set "$app.node.password=pass-a"
uci_cmd set "$app.node.sni="
uci_cmd set "$app.node.insecure=1"

# Switching an enabled runtime applies the selected node immediately.
node_use "node_b"
[ "$(uci_get node server '')" = "b.example.com" ] || {
  echo "node_use did not save the selected node" >&2
  exit 1
}
[ "$(tail -n 1 "$runtime_calls")" = "b.example.com" ] || {
  echo "node_use did not apply the selected node at runtime" >&2
  exit 1
}

# A failed runtime apply restores both the previous UCI selection and runtime.
runtime_result=fail
if (node_use "node_a" >/dev/null 2>&1); then
  echo "expected failed runtime apply to reject node switch" >&2
  exit 1
fi
[ "$(uci_get node server '')" = "b.example.com" ] || {
  echo "failed node switch did not restore the previous UCI node" >&2
  exit 1
}
[ "$(tail -n 1 "$runtime_calls")" = "b.example.com" ] || {
  echo "failed node switch did not attempt to restore the previous runtime" >&2
  exit 1
}
runtime_result=success

# 1. Test node_next_ports with no ports allocated
ports="$(node_next_ports)"
[ "$ports" = "$(printf '10818\t10819')" ] || {
  echo "expected initial ports 10818 10819, got: $ports" >&2
  exit 1
}

# 2. Test node_port_set on node_a
node_port_set "node_a" "10818" "10819" "0.0.0.0" "Living Room TV"
[ "$(uci_get node_a enable_port 0)" = "1" ] || exit 1
[ "$(uci_get node_a socks_port '')" = "10818" ] || exit 1
[ "$(uci_get node_a http_port '')" = "10819" ] || exit 1
[ "$(uci_get node_a listen '')" = "0.0.0.0" ] || exit 1
[ "$(uci_get node_a port_label '')" = "Living Room TV" ] || exit 1

# 3. Test node_next_ports automatically advances to 10820 10821
ports="$(node_next_ports)"
[ "$ports" = "$(printf '10820\t10821')" ] || {
  echo "expected next ports 10820 10821, got: $ports" >&2
  exit 1
}

# 4. Test port conflict detection on node_b
if (node_port_set "node_b" "10818" "10821" "0.0.0.0" 2>/dev/null); then
  echo "expected conflict with node_a to fail" >&2
  exit 1
fi
if (node_port_set "node_b" "10808" "10821" "0.0.0.0" 2>/dev/null); then
  echo "expected conflict with main socks to fail" >&2
  exit 1
fi
if (node_port_set "node_b" "010820" "" "0.0.0.0" 2>/dev/null); then
  echo "expected a port with leading zeros to fail" >&2
  exit 1
fi

# A failed rebind must not leave the original node disabled in UCI staging.
if (node_port_set "node_b" "invalid" "10821" "0.0.0.0" "Broken" "node_a" 2>/dev/null); then
  echo "expected invalid rebind to fail" >&2
  exit 1
fi
[ "$(uci_get node_a enable_port 0)" = "1" ] || {
  echo "failed rebind changed the original node" >&2
  exit 1
}
[ "$(uci_get node_a socks_port '')" = "10818" ] || exit 1

# 5. Test switching port from node_a to node_b while retaining the same ports
node_port_set "node_b" "10818" "10819" "0.0.0.0" "Workstation" "node_a"
[ "$(uci_get node_a enable_port 0)" = "0" ] || {
  echo "expected node_a enable_port to be cleared after switch" >&2
  exit 1
}
[ "$(uci_get node_a socks_port '')" = "" ] || exit 1
[ "$(uci_get node_b enable_port 0)" = "1" ] || exit 1
[ "$(uci_get node_b socks_port '')" = "10818" ] || exit 1
[ "$(uci_get node_b port_label '')" = "Workstation" ] || exit 1

# 6. Test node_update does NOT erase dedicated port when called without port arguments
node_update "node_b" "Node-B-Renamed" "b2.example.com" "8443" "newpass" "sni.example" "1"
[ "$(uci_get node_b label '')" = "Node-B-Renamed" ] || exit 1
[ "$(uci_get node_b server '')" = "b2.example.com" ] || exit 1
[ "$(uci_get node_b enable_port 0)" = "1" ] || {
  echo "node_update without port args wiped enable_port" >&2
  exit 1
}
[ "$(uci_get node_b socks_port '')" = "10818" ] || {
  echo "node_update without port args wiped socks_port" >&2
  exit 1
}

# 7. Test node_port_remove
node_port_remove "node_b"
[ "$(uci_get node_b enable_port 0)" = "0" ] || exit 1
[ "$(uci_get node_b socks_port '')" = "" ] || exit 1
[ "$(uci_get node_b port_label '')" = "" ] || exit 1

echo "node port management tests passed"
