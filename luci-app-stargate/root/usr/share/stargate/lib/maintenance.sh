# shellcheck shell=sh
backup_create() {
  load_config
  output="${1:-}"
  [ -n "$output" ] || output="$tmp_prefix-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  tmp_dir="$(mktemp -d "$tmp_prefix-backup.XXXXXX")"
  trap 'rm -rf "$tmp_dir"' EXIT INT TERM

  mkdir -p "$tmp_dir/etc/config" "$tmp_dir/etc/stargate" "$tmp_dir/usr/share/stargate/rules"
  [ -f /etc/config/stargate ] && cp -a /etc/config/stargate "$tmp_dir/etc/config/stargate"
  if [ -d "$work_dir" ]; then
    find "$work_dir" -maxdepth 1 -type f \( -name '*.json' -o -name '*.env' -o -name 'env' \) -exec cp -a {} "$tmp_dir/etc/stargate/" \;
  fi
  for file in "$rules_direct_rule_set" "$rules_proxy_rule_set"; do
    if [ -f "$file" ]; then
      cp -a "$file" "$tmp_dir/usr/share/stargate/rules/$(basename "$file")"
    fi
    runtime_file="$(rule_set_runtime_path "$file")"
    if [ -f "$runtime_file" ]; then
      cp -a "$runtime_file" "$tmp_dir/usr/share/stargate/rules/$(basename "$runtime_file")"
    fi
  done
  {
    echo "name=stargate"
    echo "created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "version=1"
  } >"$tmp_dir/manifest"
  tar -C "$tmp_dir" -czf "$output" manifest etc usr
  echo "$output"
}

backup_restore() {
  archive="${1:-}"
  [ -f "$archive" ] || {
    echo "backup archive missing: $archive" >&2
    exit 1
  }
  tmp_dir="$(mktemp -d "$tmp_prefix-restore.XXXXXX")"
  trap 'rm -rf "$tmp_dir"' EXIT INT TERM
  tar -C "$tmp_dir" -xzf "$archive"

  [ -f "$tmp_dir/etc/config/stargate" ] || {
    echo "invalid backup: missing etc/config/stargate" >&2
    exit 1
  }

  mkdir -p /etc/config /etc/stargate /usr/share/stargate/rules
  if [ -f /etc/config/stargate ]; then
    cp -a /etc/config/stargate "/etc/config/stargate.restore_from"
  fi
  cp -a "$tmp_dir/etc/config/stargate" /etc/config/stargate
  if [ -d "$tmp_dir/etc/stargate" ]; then
    find "$tmp_dir/etc/stargate" -maxdepth 1 -type f \( -name '*.json' -o -name '*.env' -o -name 'env' \) -exec cp -a {} /etc/stargate/ \;
  fi
  if [ -d "$tmp_dir/usr/share/stargate/rules" ]; then
    find "$tmp_dir/usr/share/stargate/rules" -maxdepth 1 -type f -name '*.json' -exec cp -a {} /usr/share/stargate/rules/ \;
  fi
  uci_commit || true
  echo "backup restored"
}

reset_defaults() {
  backup_create "$tmp_prefix-before-reset-$(date +%Y%m%d-%H%M%S).tar.gz" >/dev/null || true
  [ -x /etc/init.d/stargate ] && /etc/init.d/stargate stop >/dev/null 2>&1 || true
  cat > /etc/config/stargate <<'EOF'
config global 'global'
	option enabled '0'
	option log_level 'warn'
	option singbox_bin '/usr/bin/sing-box'
	option config_file '/etc/stargate/config.json'
	option work_dir '/etc/stargate'
	option auto_start '0'

config inbound 'inbound'
	option socks_listen '127.0.0.1'
	option socks_port '10808'
	option http_listen '127.0.0.1'
	option http_port '10809'
	option transparent_proxy '0'
	option transparent_mode 'redirect'
	option transparent_listen '0.0.0.0'
	option transparent_port '12345'

config node 'node'
	option type 'anytls'
	option label 'primary'
	option server ''
	option server_port '443'
	option password ''
	option sni ''
	option insecure '1'

config dns 'dns'
	option mode 'tcp_doh'
	option final 'direct-dns'
	option strategy 'prefer_ipv4'
	option local_preset 'alidns_tcp'
	option local_server '223.5.5.5'
	option local_type 'tcp'
	option local_path '/dns-query'
	option remote_preset 'quad9_doh'
	option remote_server '9.9.9.9'
	option remote_type 'https'
	option remote_path '/dns-query'
	option remote_detour 'anytls-out'
	option hijack_dns '1'
	option hijack_port '1053'

config rules 'rules'
	option mode 'blacklist'
	option source 'loyalsoldier'
	option source_base_url 'https://cdn.jsdelivr.net/gh/Loyalsoldier/clash-rules@release'
	option direct_rule_set '/usr/share/stargate/rules/direct.json'
	option proxy_rule_set '/usr/share/stargate/rules/proxy.json'
	option block_quic '1'
	option private_direct '1'
	option custom_direct_domains ''
	option custom_proxy_domains ''
	option custom_direct_ips ''
	option custom_proxy_ips ''

config safety 'safety'
	option backup_on_apply '1'
EOF
  rm -f /etc/stargate/config.json.next
  uci_commit || true
  echo "default Stargate config restored; service stopped"
}

singbox_upgrade() {
  upload="${1:-}"
  [ -f "$upload" ] || {
    echo "uploaded sing-box binary missing: $upload" >&2
    exit 1
  }
  load_config
  install_dir="$(dirname "$singbox_bin")"
  backup_dir="/usr/share/stargate/backup"
  backup_bin="$backup_dir/sing-box.bak"
  tmp_bin="$tmp_prefix-sing-box.new"

  mkdir -p "$install_dir" "$backup_dir"
  cp -f "$upload" "$tmp_bin"
  chmod 0755 "$tmp_bin"
  "$tmp_bin" version >/dev/null 2>&1 || {
    rm -f "$tmp_bin"
    echo "uploaded file is not a runnable sing-box binary" >&2
    exit 1
  }

  if [ -x "$singbox_bin" ]; then
    cp -a "$singbox_bin" "$backup_bin"
  fi
  cp -f "$tmp_bin" "$singbox_bin"
  chmod 0755 "$singbox_bin"
  rm -f "$tmp_bin"
  "$singbox_bin" version | head -1
  echo "sing-box upgraded: $singbox_bin"
}

singbox_rollback() {
  load_config
  backup_bin="/usr/share/stargate/backup/sing-box.bak"
  [ -x "$backup_bin" ] || {
    echo "sing-box backup not found: $backup_bin" >&2
    exit 1
  }
  cp -a "$backup_bin" "$singbox_bin"
  chmod 0755 "$singbox_bin"
  "$singbox_bin" version | head -1
  echo "sing-box rolled back: $singbox_bin"
}

