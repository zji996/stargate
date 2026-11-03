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
  /usr/share/stargate/dedup.sh configure <0|1> "devices" "targets"
                                              apply the switch, devices and target domains together
  /usr/share/stargate/dedup.sh reverse add <host>...
  /usr/share/stargate/dedup.sh reverse remove <host>...
  /usr/share/stargate/dedup.sh reverse list    hosts the reverse entry forwards
  /usr/share/stargate/dedup.sh status
  /usr/share/stargate/dedup.sh ca               print the CA certificate the devices must trust

Reverse entry: UCI dedup.reverse_listen (an address and port, empty is off) and
dedup.reverse_origins. Turning it on or off changes the front's arguments, so it
is one front handover: set both options, uci commit, then
/etc/init.d/stargate-dedup start (dedup.sh configure 1 ... starts it too).
Afterwards reverse add/remove only rewrite the host list and send the running
front a SIGHUP: no restart, no sing-box restart, no CA change. The decoder must
list the same hosts before its side is deduplicated.
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
  args="$args -index-mib ${dedup_index_mib:-$((230 * dedup_memory_mib / 300))} -inflight-mib $((128 * dedup_memory_mib / 300))"
  args="$args -memory-mib $((220 * dedup_memory_mib / 300)) -linger 3s"
  # The reverse entry's host list and credentials are files the front re-reads
  # on SIGHUP, so only their paths appear here: adding a host keeps this
  # instance, and with reverse_listen empty the arguments are exactly as before.
  if [ -n "$dedup_reverse_listen" ]; then
    write_reverse_files || die "cannot write the reverse lists in $dedup_ca_dir"
    args="$args -reverse $dedup_reverse_listen -reverse-origins $(reverse_origins_path) -reverse-auth $(reverse_auth_path)"
    args="$args -reverse-allow $(printf '%s' "$dedup_devices" | tr ' ' ',')"
  fi
  printf 'front_%s %s\n' "$(printf '%s %s' "$args" "$(md5sum <"$dedup_bin")" | md5sum | cut -c1-8)" "$args"
}

reverse_origins_path() { printf '%s/%s' "$dedup_ca_dir" "$reverse_origins_name"; }
reverse_auth_path() { printf '%s/%s' "$dedup_ca_dir" "$reverse_auth_name"; }

# Write a file holding one word per line, only when its content changes, always
# through a temp file in the same directory and a rename, so the front never
# reads a half-written list.
# write_list <path> <mode> <space- or newline-separated words>
write_list() {
  wl_path=$1 wl_mode=$2
  shift 2
  # shellcheck disable=SC2086
  wl_content="$(printf '%s\n' $*)"
  if [ -f "$wl_path" ] && [ "$(cat "$wl_path")" = "$wl_content" ]; then
    # Same content, same access: nothing to replace.
    chmod "$wl_mode" "$wl_path" 2>/dev/null || true
    return 0
  fi
  wl_tmp="$wl_path.new.$$"
  (umask 077 && printf '%s\n' "$wl_content" >"$wl_tmp") || { rm -f "$wl_tmp"; return 1; }
  chmod "$wl_mode" "$wl_tmp" || { rm -f "$wl_tmp"; return 1; }
  mv -f "$wl_tmp" "$wl_path" || { rm -f "$wl_tmp"; return 1; }
}

# The front's state that must never enter its arguments.
write_reverse_files() {
  mkdir -p "$dedup_ca_dir" || return 1
  # One host per line; the front skips blank lines and # comments.
  write_list "$(reverse_origins_path)" 0644 "$dedup_reverse_origins" || return 1
  # The main lane's credentials, the same pair sing-box already sends.
  write_list "$(reverse_auth_path)" 0600 "main:$dedup_password" || return 1
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
  old_targets_set=0
  if old_targets="$(uci_cmd get "$app.dedup.targets")"; then old_targets_set=1; fi
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
    for option in enabled devices targets; do
      case "$option" in
        enabled) value="$old_enabled"; was_set="$old_enabled_set" ;;
        devices) value="$old_devices"; was_set="$old_devices_set" ;;
        targets) value="$old_targets"; was_set="$old_targets_set" ;;
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
  devices="$(printf '%s' "$devices" | tr ',\t\n' '   ' | awk '{$1=$1; print}')"
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
  if ! stop_output="$("$dedup_init" stop 2>&1)"; then
    # procd returns "Not found" after an already stopped service was removed.
    if "$dedup_init" status >/dev/null 2>&1 || listening "$(uci_get dedup port 10860)"; then
      printf '%s\n' "$stop_output" >&2
      return 1
    fi
  fi
  "$dedup_init" disable
  echo "dedup off"
}

dedup_configure() {
  [ "$#" = 3 ] || die 'configure requires: <0|1> "devices" "targets"'
  case "$1" in 0|1) ;; *) die 'enabled must be 0 or 1' ;; esac
  configured_devices="$(printf '%s' "$2" | tr ',\t\n' '   ' | awk '{$1=$1; print}')"
  save_switch "$1" "$configured_devices"
  # UCI drops empty scalar options on commit. Keep an explicit no-target
  # marker so a later read cannot fall back to the legacy domain defaults.
  targets="$3"
  case "$targets" in *[![:space:],]*) ;; *) targets=none ;; esac
  uci_cmd set "$app.dedup.targets=$targets"
  uci_commit
  (load_front_config) || return 1
  if [ "$1" = 1 ]; then
    [ -n "$configured_devices" ] || die 'devices are required when enabling dedup'
    dedup_on "$configured_devices"
  else
    dedup_off
  fi
}

# The hosts the reverse entry forwards, one per line: the UCI list as an
# operator would read it, not the snapshot taken for a rollback.
reverse_hosts() {
  printf '%s\n' "$(uci_get dedup reverse_origins '')" | tr ' ' '\n' | awk 'NF && !seen[$0]++'
}

# The list after adding or removing hosts: sorted and unique, so the file does
# not depend on the order the operator typed.
reverse_next_hosts() {
  reverse_mode=$1
  shift
  {
    reverse_hosts
    [ "$reverse_mode" != add ] || printf '%s\n' "$@"
  } | while IFS= read -r reverse_line; do
    [ -n "$reverse_line" ] || continue
    if [ "$reverse_mode" = remove ]; then
      reverse_drop=0
      for reverse_host in "$@"; do
        [ "$reverse_host" != "$reverse_line" ] || reverse_drop=1
      done
      [ "$reverse_drop" = 0 ] || continue
    fi
    printf '%s\n' "$reverse_line"
  done | sort -u | tr '\n' ' ' | sed 's/ *$//'
}

# Adding or removing a host leaves reverse_listen alone, so the front's
# arguments and instance name stay the same: only the list file and a SIGHUP
# are needed. Remember the UCI text and both list files first, so a failure
# midway can put back exactly what was there.
snapshot_reverse() {
  uci_get_reverse_origins="$(uci_get dedup reverse_origins '')"
  reverse_origins_set=0
  uci_cmd get "$app.dedup.reverse_origins" >/dev/null 2>&1 && reverse_origins_set=1
  reverse_origins_before="$(reverse_origins_path)"
  reverse_auth_before="$(reverse_auth_path)"
  reverse_backup="$(mktemp -d "${TMPDIR:-/tmp}/stargate-reverse.XXXXXX")" || return 1
  [ ! -f "$reverse_origins_before" ] || cp -p "$reverse_origins_before" "$reverse_backup/origins"
  [ ! -f "$reverse_auth_before" ] || cp -p "$reverse_auth_before" "$reverse_backup/auth"
  reverse_front_running=0
  "$dedup_init" status >/dev/null 2>&1 && reverse_front_running=1
  reverse_reloaded=0
  # Nothing is written until dedup_reverse has checked everything it can.
  reverse_touched=0
}

restore_reverse() {
  if [ "$reverse_origins_set" = 1 ]; then
    uci_cmd set "$app.dedup.reverse_origins=$uci_get_reverse_origins" || return 1
  else
    if uci_cmd get "$app.dedup.reverse_origins" >/dev/null 2>&1; then
      uci_cmd delete "$app.dedup.reverse_origins" || return 1
    fi
  fi
  uci_commit || return 1
  for reverse_saved in origins auth; do
    case "$reverse_saved" in
      origins) reverse_file="$reverse_origins_before" ;;
      *) reverse_file="$reverse_auth_before" ;;
    esac
    if [ -f "$reverse_backup/$reverse_saved" ]; then
      cp -p "$reverse_backup/$reverse_saved" "$reverse_file" || return 1
    else
      rm -f "$reverse_file" || return 1
    fi
  done
  rm -rf "$reverse_backup"
  # The front has already re-read the abandoned list; reread the restored one,
  # unless it was not running and had nothing to reload.
  [ "$reverse_reloaded" = 1 ] || return 0
  "$dedup_init" reload
}

reverse_transaction() (
  snapshot_reverse || die "cannot back up the reverse lists in $dedup_ca_dir"
  trap 'rc=$?; trap - EXIT; if [ "$rc" != 0 ]; then
    if [ "${reverse_touched:-0}" != 1 ]; then
      rm -rf "$reverse_backup"
      echo "dedup reverse failed; nothing changed" >&2
    elif restore_reverse; then
      echo "dedup reverse failed; previous list restored" >&2
    else
      echo "dedup reverse failed; recovery incomplete, check $dedup_ca_dir" >&2
    fi
  fi; exit "$rc"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  "$@"
)

dedup_reverse() {
  reverse_mode="${1:-}"
  case "$reverse_mode" in
    add|remove|list) shift ;;
    *) die 'reverse requires: add|remove|list [host ...]' ;;
  esac
  if [ "$reverse_mode" = list ]; then
    [ "$#" = 0 ] || die 'reverse list takes no hosts'
    load_front_config
    reverse_hosts
    return 0
  fi

  # Normalise and check the hosts before touching anything: a typo must leave
  # UCI and the list the front is using alone.
  reverse_hosts_wanted=""
  for reverse_host in "$@"; do
    reverse_host="$(printf '%s' "$reverse_host" | tr 'A-Z' 'a-z')"
    printf '%s\n' "$reverse_host" | grep -Eq '^[a-z0-9-]+(\.[a-z0-9-]+)+$' ||
      die "invalid reverse origin (want a host name): $reverse_host"
    reverse_hosts_wanted="$reverse_hosts_wanted $reverse_host"
  done
  [ -n "$reverse_hosts_wanted" ] || die "which hosts? e.g. dedup.sh reverse $reverse_mode api.example.com"
  # shellcheck disable=SC2086
  set -- $reverse_hosts_wanted

  load_front_config
  [ -n "$dedup_reverse_listen" ] || die 'the reverse entry is off: set dedup.reverse_listen and dedup.reverse_origins first'
  reverse_next="$(reverse_next_hosts "$reverse_mode" "$@")"
  # An empty list would leave a listening entry that forwards nothing.
  [ -n "$reverse_next" ] || die 'that would leave no reverse origins; clear reverse_listen to turn the entry off'

  reverse_old="$(reverse_hosts | sort -u | tr '\n' ' ' | sed 's/ *$//')"
  [ "$reverse_old" != "$reverse_next" ] || {
    rm -rf "$reverse_backup"
    echo "reverse origins unchanged: $reverse_next"
    return 0
  }

  uci_cmd get "$app.dedup" >/dev/null 2>&1 || uci_cmd set "$app.dedup=dedup"
  reverse_touched=1
  uci_cmd set "$app.dedup.reverse_origins=$reverse_next"
  uci_commit || die 'cannot save the reverse origins'

  # reverse.auth and the front's arguments were valid before and still are:
  # only the list file changes, through a temp file and a rename.
  write_list "$(reverse_origins_path)" 0644 "$reverse_next" ||
    die "cannot write $(reverse_origins_path)"
  if [ "$reverse_front_running" = 1 ]; then
    reverse_reloaded=1
    "$dedup_init" reload || die 'the front did not take the new list'
  fi
  rm -rf "$reverse_backup"
  echo "reverse origins: $reverse_next"
}

# Only a change needs the rollback snapshot: list is a read.
reverse_command() {
  case "${1:-}" in
    add|remove) reverse_transaction dedup_reverse "$@" ;;
    *) dedup_reverse "$@" ;;
  esac
}

dedup_status() {
  load_front_config
  steering=no
  ! grep -q '"dedup-in"' "$config_file" 2>/dev/null || steering=yes
  front=down
  ! listening "$dedup_port" || front=up
  printf 'switch: %s\ndevices: %s\ndomains: %s\n' "$([ "$dedup_enabled" = 1 ] && echo on || echo off)" "${dedup_devices:-none}" "$dedup_domains"
  printf 'targets: %s\n' "${dedup_targets:-none}"
  printf 'reverse: %s\nreverse origins: %s\n' "${dedup_reverse_listen:-off}" "${dedup_reverse_origins:-none}"
  printf 'front: %s\nsteering in sing-box: %s\n' "$front" "$steering"
  [ -f "$dedup_ca_dir/ca.pem" ] && printf 'ca: %s\n' "$dedup_ca_dir/ca.pem" || printf 'ca: none\n'
  [ "$front" = up ] || return 0
  stats="$(wget -q -T 2 -O - "http://127.0.0.1:$((dedup_port + 2))/stats" 2>/dev/null || true)"
  [ -n "$stats" ] || return 0
  for key in original_bytes sent_bytes ratio intercepted_conns passed_conns \
    reverse_requests reverse_direct reverse_refused; do
    printf '%s: %s\n' "$key" "$(jsonfilter -s "$stats" -e "@.$key" 2>/dev/null || echo 0)"
  done
  printf 'lanes: %s\n' "$(jsonfilter -s "$stats" -e '@.lanes' 2>/dev/null)"
}

action="${1:-}"
[ "$#" -eq 0 ] || shift
case "$action" in
  on) switch_transaction dedup_on "$@" ;;
  off) switch_transaction dedup_off ;;
  configure) switch_transaction dedup_configure "$@" ;;
  reverse) reverse_command "$@" ;;
  status) dedup_status ;;
  ca) cat "$dedup_ca_dir/ca.pem" ;;
  front) print_front ;;
  -h|--help|help|"") usage ;;
  *) usage >&2; exit 2 ;;
esac
