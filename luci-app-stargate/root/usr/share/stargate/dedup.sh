#!/bin/sh
set -eu

app="stargate"
work_dir="/etc/stargate"
config_file="$work_dir/config.json"
next_file="$config_file.next"
backup_file="$config_file.bak"
singbox_bin="/usr/bin/sing-box"
dedup_bin="/usr/bin/stargate-dedup"
dedup_ca_dir="$work_dir/dedup"
dedup_init="/etc/init.d/stargate-dedup"
stargate_init="/etc/init.d/stargate"

usage() {
  cat <<'USAGE'
Usage:
  /usr/share/stargate/dedup.sh on [device ...]  turn on, for these devices (IP or CIDR) if given
  /usr/share/stargate/dedup.sh off              turn off
  /usr/share/stargate/dedup.sh status
  /usr/share/stargate/dedup.sh ca               print the CA certificate the devices must trust
USAGE
}

script_dir="$(CDPATH= cd "$(dirname "$0")" && pwd)"
for module in common rules config firewall; do
  # shellcheck source=/dev/null
  . "$script_dir/lib/$module.sh"
done

die() {
  echo "$*" >&2
  exit 1
}

# The front's settings, without the node checks generate_config does.
load_front_config() {
  rules_mode="$(uci_get rules mode blacklist)"
  load_dedup_config
  validate_dedup_config
}

# "<instance> <arguments>" for the init script, or nothing while off. The
# instance name changes with the arguments and the binary, so procd starts a
# changed front next to the old one, which keeps accepting for -linger.
print_front() {
  load_front_config
  [ "$dedup_enabled" = 1 ] && [ -n "$dedup_devices" ] || return 0
  [ -x "$dedup_bin" ] || die "dedup front missing: $dedup_bin"
  # Defaults are sized for 300 MiB.
  args="front -listen 127.0.0.1:$dedup_port -via socks5://127.0.0.1:$((dedup_port + 1))"
  args="$args -admin 127.0.0.1:$((dedup_port + 2)) -ca-dir $dedup_ca_dir"
  args="$args -domains $(printf '%s' "$dedup_domains" | tr ' ' ',') -compress $dedup_compress"
  args="$args -index-mib $((230 * dedup_memory_mib / 300)) -inflight-mib $((128 * dedup_memory_mib / 300))"
  args="$args -memory-mib $((220 * dedup_memory_mib / 300)) -linger 3s"
  printf 'front_%s %s\n' "$(printf '%s %s' "$args" "$(md5sum <"$dedup_bin")" | md5sum | cut -c1-8)" "$args"
}

listening() {
  awk -v port="$(printf '%04X' "$1")" '$4 == "0A" && substr($2, index($2, ":") + 1) == port { found = 1 } END { exit !found }' /proc/net/tcp
}

wait_front() {
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    listening "$dedup_port" && return 0
    sleep 1
  done
  return 1
}

# Restart Stargate only if its generated config differs from the running one.
apply_steering() {
  next="$(generate_config)" || return 1
  if [ -f "$config_file" ] && cmp -s "$next" "$config_file" && "$stargate_init" status >/dev/null; then
    rm -f "$next"
    return 0
  fi
  rm -f "$next"
  echo "restarting Stargate with the new routes; proxied connections drop once..."
  routes_touched=1
  "$script_dir/stargate.sh" apply-runtime >/dev/null || return 1
  # The runtime helper may successfully roll back to an older config. That
  # still means this switch failed; never report the requested state as live.
  steering_matches
}

steering_matches() {
  next="$(generate_config)" || return 1
  if cmp -s "$next" "$config_file"; then matches=1; else matches=0; fi
  rm -f "$next"
  [ "$matches" = 1 ] && "$stargate_init" status >/dev/null
}

save_switch() {
  uci_cmd get "$app.dedup" >/dev/null 2>&1 || uci_cmd set "$app.dedup=dedup"
  uci_cmd set "$app.dedup.enabled=$1"
  uci_cmd set "$app.dedup.devices=$2"
  uci_commit
}

# Remember option absence as well as values, including a missing section.
# Restore only the fields this CLI writes, leaving other dedup options alone.
snapshot_switch() {
  old_section="$(uci_cmd get "$app.dedup" || true)"
  old_enabled_set=0
  if old_enabled="$(uci_cmd get "$app.dedup.enabled")"; then old_enabled_set=1; fi
  old_devices_set=0
  if old_devices="$(uci_cmd get "$app.dedup.devices")"; then old_devices_set=1; fi
  old_init_enabled=0
  "$dedup_init" enabled && old_init_enabled=1
  old_front_running=0
  "$dedup_init" status >/dev/null 2>&1 && old_front_running=1
  routes_touched=0
  front_touched=0
}

restore_switch() {
  if [ -z "$old_section" ]; then
    if uci_cmd get "$app.dedup" >/dev/null 2>&1; then
      uci_cmd delete "$app.dedup" || return 1
    fi
  else
    for option in enabled devices; do
      case "$option" in
        enabled) value="$old_enabled"; was_set="$old_enabled_set" ;;
        devices) value="$old_devices"; was_set="$old_devices_set" ;;
      esac
      if [ "$was_set" = 1 ]; then
        uci_cmd set "$app.dedup.$option=$value" || return 1
      else
        if uci_cmd get "$app.dedup.$option" >/dev/null 2>&1; then
          uci_cmd delete "$app.dedup.$option" || return 1
        fi
      fi
    done
  fi
  uci_commit || return 1
  if [ "$front_touched" = 1 ] && [ "$old_front_running" = 1 ]; then
    "$dedup_init" start || return 1
    dedup_port="$(uci_get dedup port 10860)"
    wait_front || return 1
  fi
  # Reapply unconditionally: a failed restart can leave the old file in place
  # while its process or firewall is down. A byte comparison cannot detect it.
  if [ "$routes_touched" = 1 ]; then
    "$script_dir/stargate.sh" apply-runtime >/dev/null || return 1
    steering_matches || return 1
  fi
  # Keep a front alive if routes could not be restored.
  if [ "$front_touched" = 1 ] && [ "$old_front_running" = 0 ]; then
    "$dedup_init" stop || return 1
  fi
  if [ "$old_init_enabled" = 1 ]; then
    "$dedup_init" enable
  else
    "$dedup_init" disable
  fi
}

switch_transaction() (
  snapshot_switch
  trap 'rc=$?; trap - EXIT; if [ "$rc" != 0 ]; then
    if restore_switch; then
      echo "dedup switch failed; previous settings and runtime restored" >&2
    else
      echo "dedup switch failed; recovery incomplete, check Stargate and dedup status" >&2
    fi
  fi; exit "$rc"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  "$@"
)

dedup_on() {
  [ "$(bool_value "$(uci_get global enabled 0)")" = 1 ] || die "Stargate is not running; start it first"
  [ -x "$dedup_bin" ] || die "dedup front missing: $dedup_bin (build it with tools/dedup/build.sh)"
  devices="${*:-$old_devices}"
  [ -n "$devices" ] || die "which devices? e.g. dedup.sh on 10.0.0.12"
  [ "$(uci_get rules mode blacklist)" != direct ] || die "direct mode sends nothing to a node; nothing to deduplicate"

  save_switch 1 "$devices"
  (load_front_config) || return 1
  load_front_config
  if [ ! -f "$dedup_ca_dir/ca.pem" ]; then
    mkdir -p "$dedup_ca_dir"
    chmod 700 "$dedup_ca_dir"
    "$dedup_bin" ca -dir "$dedup_ca_dir" -domains "$(printf '%s' "$dedup_domains" | tr ' ' ',')" >/dev/null
    new_ca=1
  fi

  echo "starting the dedup front..."
  front_touched=1
  "$dedup_init" enable
  if ! "$dedup_init" start || ! wait_front; then
    logread -e stargate-dedup 2>/dev/null | tail -n 5 >&2 || true
    die "the dedup front did not start"
  fi
  if ! apply_steering; then
    die "Stargate did not take the new routes"
  fi
  echo "dedup on for $devices"
  if [ "${new_ca:-0}" = 1 ]; then
    echo "new CA: until those devices trust it (dedup.sh ca), their requests to $dedup_domains fail"
  fi
}

dedup_off() {
  save_switch 0 "$(uci_get dedup devices '')"
  [ "$(bool_value "$(uci_get global enabled 0)")" != 1 ] || apply_steering
  front_touched=1
  "$dedup_init" stop
  "$dedup_init" disable
  echo "dedup off"
}

dedup_status() {
  load_front_config
  steering=no
  ! grep -q '"dedup-in"' "$config_file" 2>/dev/null || steering=yes
  front=down
  ! listening "$dedup_port" || front=up
  printf 'switch: %s\ndevices: %s\ndomains: %s\n' "$([ "$dedup_enabled" = 1 ] && echo on || echo off)" "${dedup_devices:-none}" "$dedup_domains"
  printf 'front: %s\nsteering in sing-box: %s\n' "$front" "$steering"
  [ -f "$dedup_ca_dir/ca.pem" ] && printf 'ca: %s\n' "$dedup_ca_dir/ca.pem" || printf 'ca: none\n'
  [ "$front" = up ] || return 0
  stats="$(wget -q -T 2 -O - "http://127.0.0.1:$((dedup_port + 2))/stats" 2>/dev/null || true)"
  [ -n "$stats" ] || return 0
  for key in original_bytes sent_bytes ratio intercepted_conns passed_conns; do
    printf '%s: %s\n' "$key" "$(jsonfilter -s "$stats" -e "@.$key" 2>/dev/null || echo 0)"
  done
  printf 'lanes: %s\n' "$(jsonfilter -s "$stats" -e '@.lanes' 2>/dev/null)"
}

action="${1:-}"
[ "$#" -eq 0 ] || shift
case "$action" in
  on) switch_transaction dedup_on "$@" ;;
  off) switch_transaction dedup_off ;;
  status) dedup_status ;;
  ca) cat "$dedup_ca_dir/ca.pem" ;;
  front) print_front ;;
  -h|--help|help|"") usage ;;
  *) usage >&2; exit 2 ;;
esac
