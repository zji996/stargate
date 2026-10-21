#!/bin/sh
set -eu
repo_dir="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
. "$repo_dir/luci-app-stargate/root/usr/share/stargate/lib/common.sh"
. "$repo_dir/luci-app-stargate/root/usr/share/stargate/lib/rules.sh"
. "$repo_dir/luci-app-stargate/root/usr/share/stargate/lib/config.sh"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
app="stargate"
work_dir="$test_dir"
config_file="$test_dir/config.json"
singbox_bin=/nonexistent
for name in direct proxy; do
  printf '{"version":3,"rules":[]}\n' > "$test_dir/$name.json"
  : > "$test_dir/$name.srs"
done
firewall_dns_ipv6_address() { printf fd00::1; }
test_mode=blacklist
dedup_enabled_case=1
dedup_port_case=10860
uci_get() {
  case "$1.$2" in
    rules.mode) printf '%s' "$test_mode" ;;
    node.server) printf node.example ;;
    node.password) printf test-only ;;
    inbound.transparent_proxy) printf 1 ;;
    rules.direct_rule_set) printf '%s/direct.json' "$test_dir" ;;
    rules.proxy_rule_set) printf '%s/proxy.json' "$test_dir" ;;
    rules.geoip_direct_rule_set|rules.geoip_proxy_rule_sets) printf '' ;;
    node_jp.server) printf jp.example.com ;;
    node_jp.password) printf jp-pass ;;
    node_jp.enable_port) printf 1 ;;
    node_jp.socks_port) printf 10818 ;;
    node_jp.http_port) printf 10819 ;;
    # Same server/port/password as the active node: shares anytls-out.
    node_main.server) printf node.example ;;
    node_main.password) printf test-only ;;
    node_main.enable_port) printf 1 ;;
    node_main.socks_port) printf 10838 ;;
    node_off.server) printf off.example.com ;;
    node_off.password) printf off-pass ;;
    node_off.enable_port) printf 0 ;;
    dedup.enabled) printf '%s' "$dedup_enabled_case" ;;
    dedup.devices) printf '%s' "${dedup_devices_case-10.0.0.12 10.1.0.0/16}" ;;
    dedup.domains) printf '%s' "${dedup_domains_case-ChatGPT.com,api.openai.com}" ;;
    dedup.port) printf '%s' "$dedup_port_case" ;;
    dedup.index_mib) printf '%s' "${dedup_index_case-}" ;;
    *) printf '%s' "$3" ;;
  esac
}
uci() {
  if [ "$1" = "-q" ] && [ "$2" = "show" ] && [ "$3" = "stargate" ]; then
    printf 'stargate.node_jp=node_item\nstargate.node_main=node_item\nstargate.node_off=node_item\n'
    return 0
  fi
  return 1
}
expect_fail() {
  if (generate_config >/dev/null 2>"$test_dir/err"); then
    echo "expected failure: $1" >&2
    exit 1
  fi
  grep -q "$1" "$test_dir/err" || { cat "$test_dir/err" >&2; exit 1; }
}

cp "$(generate_config)" "$test_dir/on.json"
cp "$(dedup_enabled_case=0 generate_config)" "$test_dir/off.json"
cp "$(test_mode=direct generate_config)" "$test_dir/direct.json"
cp "$(dedup_devices_case='' generate_config)" "$test_dir/nodevices.json"
python3 - "$test_dir" <<'PY2'
import json, sys
d = sys.argv[1]
for name in ("off", "direct", "nodevices"):
    assert "dedup" not in open(f"{d}/{name}.json").read(), name

on = json.load(open(f"{d}/on.json"))
inbounds = {i["tag"]: i for i in on["inbounds"]}
outbounds = {o["tag"]: o for o in on["outbounds"]}
via = inbounds["dedup-in"]
assert via["listen"] == "127.0.0.1" and via["listen_port"] == 10861
# Every node that has its own outbound is a lane; node_main shares anytls-out.
assert [u["username"] for u in via["users"]] == ["main", "node_jp"], via
for lane in ("main", "node_jp"):
    o = outbounds[f"dedup-out-{lane}"]
    assert (o["server"], o["server_port"], o["username"]) == ("127.0.0.1", 10860, lane), o
rules = on["route"]["rules"]
is_dedup = lambda r: "dedup-in" in r.get("inbound", []) or r.get("outbound", "").startswith("dedup-out-")
back = {r["auth_user"][0]: r["outbound"] for r in rules if r.get("inbound") == ["dedup-in"] and "auth_user" in r}
assert back == {"main": "anytls-out", "node_jp": "out-node-node_jp"}, back
assert {"inbound": ["dedup-in"], "action": "reject"} in rules
steer = {r["outbound"]: r for r in rules if r.get("outbound", "").startswith("dedup-out-")}
assert steer["dedup-out-main"]["inbound"] == ["transparent-in", "socks-in", "http-in", "in-socks-node_main"]
assert steer["dedup-out-node_jp"]["inbound"] == ["in-socks-node_jp", "in-http-node_jp"]
for r in steer.values():
    assert r["source_ip_cidr"] == ["10.0.0.12", "10.1.0.0/16"]
    assert r["domain_suffix"] == ["chatgpt.com", "api.openai.com"]
    assert r["network"] == "tcp" and r["port"] == 443
# Steering needs the sniffed name and must precede every other decision.
dedup_at = [i for i, r in enumerate(rules) if is_dedup(r)]
other_at = [i for i, r in enumerate(rules) if not is_dedup(r) and r.get("action") not in ("sniff", "hijack-dns")]
sniff_at = [i for i, r in enumerate(rules) if r.get("action") == "sniff"]
assert sniff_at[0] < dedup_at[0] and dedup_at[-1] < other_at[0], rules[:8]
PY2

(dedup_port_case=10817; expect_fail "conflicts with another Stargate port")
(dedup_devices_case="10.0.0.12;"; expect_fail "invalid dedup device")
(dedup_index_case=540M; expect_fail "index_mib must be numeric")
(dedup_index_case=8; expect_fail "index_mib must be at least 16")
dedup_index_case=540 generate_config >/dev/null
(dedup_domains_case="chatgpt"; expect_fail "invalid dedup domain")
# Bad options do not matter while dedup is off.
(dedup_enabled_case=0; dedup_port_case=x; generate_config >/dev/null)
