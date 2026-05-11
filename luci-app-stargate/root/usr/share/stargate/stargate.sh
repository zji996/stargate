#!/bin/sh
set -eu

app="stargate"
work_dir="/etc/stargate"
config_file="$work_dir/config.json"
next_file="$config_file.next"
backup_file="$config_file.bak"
singbox_bin="/usr/bin/sing-box"
tmp_prefix="/tmp/stargate"

usage() {
  cat <<'USAGE'
Usage:
  /usr/share/stargate/stargate.sh generate
  /usr/share/stargate/stargate.sh check
  /usr/share/stargate/stargate.sh apply
  /usr/share/stargate/stargate.sh rollback
  /usr/share/stargate/stargate.sh start
  /usr/share/stargate/stargate.sh start-transparent [redirect|tproxy] [port]
  /usr/share/stargate/stargate.sh stop
  /usr/share/stargate/stargate.sh status
  /usr/share/stargate/stargate.sh firewall-apply
  /usr/share/stargate/stargate.sh firewall-clean
  /usr/share/stargate/stargate.sh firewall-status
  /usr/share/stargate/stargate.sh probe baidu|google|github
  /usr/share/stargate/stargate.sh node-add label server port password sni insecure
  /usr/share/stargate/stargate.sh node-add-link anytls://...
  /usr/share/stargate/stargate.sh node-update id label server port password sni insecure
  /usr/share/stargate/stargate.sh node-list
  /usr/share/stargate/stargate.sh node-use id
  /usr/share/stargate/stargate.sh node-delete id
  /usr/share/stargate/stargate.sh rules-update
  /usr/share/stargate/stargate.sh rules-update-start
  /usr/share/stargate/stargate.sh rules-status
  /usr/share/stargate/stargate.sh rules-test domain-or-ip
  /usr/share/stargate/stargate.sh backup-create [output.tar.gz]
  /usr/share/stargate/stargate.sh backup-restore input.tar.gz
  /usr/share/stargate/stargate.sh reset-defaults
  /usr/share/stargate/stargate.sh singbox-upgrade uploaded-binary
  /usr/share/stargate/stargate.sh singbox-rollback
  /usr/share/stargate/stargate.sh logs
  /usr/share/stargate/stargate.sh logs-raw
  /usr/share/stargate/stargate.sh logs-clear
USAGE
}

rules_update_pid_file="$tmp_prefix-rules-update.pid"
rules_update_status_file="$tmp_prefix-rules-update.status"
rules_update_log_file="$tmp_prefix-rules-update.log"

script_dir="$(CDPATH= cd "$(dirname "$0")" && pwd)"
for module in common nodes rules rules_update config service firewall maintenance; do
  # shellcheck source=/dev/null
  . "$script_dir/lib/$module.sh"
done

action="${1:-}"
case "$action" in
  generate) generate_config ;;
  check) load_config; generated="$(generate_config)"; next_file="$generated"; check_next ;;
  apply) apply_config ;;
  rollback) rollback_config ;;
  start) start_local_proxy ;;
  start-transparent) start_transparent_proxy "${2:-redirect}" "${3:-}" ;;
  stop) stop_service ;;
  status) status_json ;;
  firewall-apply) firewall_apply ;;
  firewall-clean) firewall_clean ;;
  firewall-status) firewall_status_text ;;
  probe) probe_url "${2:-}" ;;
  node-add) node_add_values "${2:-}" "${3:-}" "${4:-443}" "${5:-}" "${6:-}" "${7:-1}" ;;
  node-add-link) node_add_link "${2:-}" ;;
  node-update) node_update "${2:-}" "${3:-}" "${4:-}" "${5:-443}" "${6:-}" "${7:-}" "${8:-1}" ;;
  node-list) node_list ;;
  node-use) node_use "${2:-}" ;;
  node-delete) node_delete "${2:-}" ;;
  rules-update) rules_update ;;
  rules-update-start) rules_update_start ;;
  rules-status) rules_status ;;
  rules-test) rules_test "${2:-}" ;;
  backup-create) backup_create "${2:-}" ;;
  backup-restore) backup_restore "${2:-}" ;;
  reset-defaults) reset_defaults ;;
  singbox-upgrade) singbox_upgrade "${2:-}" ;;
  singbox-rollback) singbox_rollback ;;
  logs) logs_text ;;
  logs-raw) logs_raw ;;
  logs-clear) logs_clear ;;
  -h|--help|help|"") usage ;;
  *) usage >&2; exit 2 ;;
esac
