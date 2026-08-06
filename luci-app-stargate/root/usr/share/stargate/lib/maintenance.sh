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
  {
    printf '%s\n' "$rules_direct_rule_set" "$rules_proxy_rule_set"
    [ -z "$rules_geoip_direct_rule_set" ] || printf '%s\n' "$rules_geoip_direct_rule_set"
    printf '%s\n' "$rules_geoip_proxy_rule_sets" | tr ', \t' '\n\n\n'
  } | while IFS= read -r file; do
    [ -n "$file" ] || continue
    if [ -f "$file" ]; then
      cp -a "$file" "$tmp_dir/usr/share/stargate/rules/$(basename "$file")"
    fi
    runtime_file="$(rule_set_runtime_path "$file")"
    if [ "$runtime_file" != "$file" ] && [ -f "$runtime_file" ]; then
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
  archive_list="$(tar -tzf "$archive")" || {
    echo "invalid backup: cannot list archive" >&2
    exit 1
  }
  unsafe_path="$(printf '%s\n' "$archive_list" | awk '
    {
      path = $0
      sub(/\/$/, "", path)
      if (path == "") next
      if (path ~ /^\// || path ~ /(^|\/)\.\.(\/|$)/) { print $0; exit }
      if (path == "manifest" ||
          path == "etc" || path == "etc/config" || path == "etc/config/stargate" ||
          path == "etc/stargate" || path ~ /^etc\/stargate\/[^\/]+$/ ||
          path == "usr" || path == "usr/share" || path == "usr/share/stargate" ||
          path == "usr/share/stargate/rules" || path ~ /^usr\/share\/stargate\/rules\/[^\/]+$/) next
      print $0
      exit
    }
  ')"
  [ -z "$unsafe_path" ] || {
    echo "invalid backup path: $unsafe_path" >&2
    exit 1
  }
  tar -C "$tmp_dir" -xzf "$archive"

  [ -f "$tmp_dir/manifest" ] && [ ! -L "$tmp_dir/manifest" ] || {
    echo "invalid backup: missing manifest" >&2
    exit 1
  }
  grep -qx 'name=stargate' "$tmp_dir/manifest" && grep -qx 'version=1' "$tmp_dir/manifest" || {
    echo "invalid backup: unsupported manifest" >&2
    exit 1
  }
  [ -f "$tmp_dir/etc/config/stargate" ] || {
    echo "invalid backup: missing etc/config/stargate" >&2
    exit 1
  }
  [ ! -L "$tmp_dir/etc/config/stargate" ] || {
    echo "invalid backup: configuration must be a regular file" >&2
    exit 1
  }
  if find "$tmp_dir" -type l | grep -q .; then
    echo "invalid backup: symbolic links are not allowed" >&2
    exit 1
  fi
  uci -q -c "$tmp_dir/etc/config" show stargate >/dev/null 2>&1 || {
    echo "invalid backup: malformed UCI configuration" >&2
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
    find "$tmp_dir/usr/share/stargate/rules" -maxdepth 1 -type f \( -name '*.json' -o -name '*.srs' \) -exec cp -a {} /usr/share/stargate/rules/ \;
  fi
  uci_commit || true
  echo "backup files restored"
  "$0" apply-runtime
  echo "backup restored and runtime synchronized"
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
	option remote_preset 'google_doh'
	option remote_server 'dns.google'
	option remote_type 'https'
	option remote_path '/dns-query'
	option remote_detour 'anytls-out'
	option hijack_dns '1'
	option hijack_port '1053'

config rules 'rules'
	option mode 'blacklist'
	option source 'loyalsoldier'
	option source_base_url 'https://cdn.jsdelivr.net/gh/Loyalsoldier/clash-rules@release'
	option geoip_base_url 'https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geoip'
	option direct_rule_set '/usr/share/stargate/rules/direct.json'
	option proxy_rule_set '/usr/share/stargate/rules/proxy.json'
	option geoip_direct_rule_set '/usr/share/stargate/rules/geoip-cn.srs'
	option geoip_proxy_rule_sets '/usr/share/stargate/rules/geoip-google.srs /usr/share/stargate/rules/geoip-facebook.srs /usr/share/stargate/rules/geoip-twitter.srs /usr/share/stargate/rules/geoip-telegram.srs'
	option geoip_proxy_extra_cidrs '104.244.43.0/24 175.41.128.0/18'
	option block_quic '1'
	option private_direct '1'
	option custom_direct_domains ''
	option custom_proxy_domains ''
	option custom_direct_ips ''
	option custom_proxy_ips ''

config safety 'safety'
	option backup_on_apply '1'
	option lan_ipv6_policy 'keep'
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
  backup_bin="$backup_dir/sing-box.bak.gz"
  next_bin="$singbox_bin.next"
  cleanup_upgrade_files() {
    rm -f "$next_bin" "$backup_bin.next"
  }

  mkdir -p "$install_dir" "$backup_dir"
  cleanup_upgrade_files
  trap cleanup_upgrade_files EXIT INT TERM
  required_bytes="$(($(wc -c <"$upload") + 16777216))"
  available_bytes="$(df -Pk "$install_dir" | awk 'NR == 2 { printf "%.0f", $4 * 1024 }')"
  [ -n "$available_bytes" ] && [ "$available_bytes" -ge "$required_bytes" ] || {
    echo "not enough flash space for atomic sing-box upgrade" >&2
    exit 1
  }

  cp -f "$upload" "$next_bin" || {
    cleanup_upgrade_files
    echo "failed to stage uploaded sing-box" >&2
    exit 1
  }
  chmod 0755 "$next_bin"
  "$next_bin" version >/dev/null 2>&1 || {
    cleanup_upgrade_files
    echo "uploaded file is not a runnable sing-box binary" >&2
    exit 1
  }
  if [ -f "$config_file" ]; then
    "$next_bin" check -c "$config_file" >/dev/null 2>&1 || {
      cleanup_upgrade_files
      echo "uploaded sing-box cannot load the current Stargate config" >&2
      exit 1
    }
  fi

  was_running=0
  /etc/init.d/stargate status >/dev/null 2>&1 && was_running=1
  had_previous=0
  if [ -x "$singbox_bin" ]; then
    gzip -c "$singbox_bin" >"$backup_bin.next" && mv "$backup_bin.next" "$backup_bin" || {
      cleanup_upgrade_files
      echo "failed to store compressed sing-box backup" >&2
      exit 1
    }
    had_previous=1
  fi
  mv "$next_bin" "$singbox_bin"
  if [ "$was_running" = "1" ] && ! STARGATE_CONFIG_READY=1 /etc/init.d/stargate restart; then
    if [ "$had_previous" = "1" ] && [ -s "$backup_bin" ]; then
      rm -f "$singbox_bin"
      gzip -dc "$backup_bin" >"$next_bin" && chmod 0755 "$next_bin" && mv "$next_bin" "$singbox_bin"
      STARGATE_CONFIG_READY=1 /etc/init.d/stargate restart >/dev/null 2>&1 || true
    else
      rm -f "$singbox_bin"
    fi
    cleanup_upgrade_files
    echo "sing-box restart failed; restored previous binary" >&2
    exit 1
  fi
  cleanup_upgrade_files
  trap - EXIT INT TERM
  "$singbox_bin" version | head -1
  echo "sing-box upgraded: $singbox_bin"
}

singbox_rollback() {
  load_config
  backup_bin="/usr/share/stargate/backup/sing-box.bak.gz"
  [ -s "$backup_bin" ] || {
    echo "sing-box backup not found: $backup_bin" >&2
    exit 1
  }
  gzip -t "$backup_bin" >/dev/null 2>&1 || {
    echo "sing-box backup is corrupt: $backup_bin" >&2
    exit 1
  }
  was_running=0
  /etc/init.d/stargate status >/dev/null 2>&1 && was_running=1
  current_backup="$tmp_prefix-sing-box.rollback-from.gz"
  next_bin="$singbox_bin.next"
  cleanup_rollback_files() {
    rm -f "$current_backup" "$next_bin"
  }
  cleanup_rollback_files
  trap cleanup_rollback_files EXIT INT TERM
  [ ! -x "$singbox_bin" ] || gzip -c "$singbox_bin" >"$current_backup"
  gzip -dc "$backup_bin" >"$next_bin"
  chmod 0755 "$next_bin"
  "$next_bin" version >/dev/null 2>&1 || {
    rm -f "$current_backup" "$next_bin"
    echo "backup sing-box is not runnable" >&2
    exit 1
  }
  if [ -f "$config_file" ]; then
    "$next_bin" check -c "$config_file" >/dev/null 2>&1 || {
      rm -f "$current_backup" "$next_bin"
      echo "backup sing-box cannot load the current Stargate config" >&2
      exit 1
    }
  fi
  mv "$next_bin" "$singbox_bin"
  if [ "$was_running" = "1" ] && ! STARGATE_CONFIG_READY=1 /etc/init.d/stargate restart; then
    if [ -s "$current_backup" ]; then
      rm -f "$singbox_bin"
      gzip -dc "$current_backup" >"$next_bin" && chmod 0755 "$next_bin" && mv "$next_bin" "$singbox_bin"
      STARGATE_CONFIG_READY=1 /etc/init.d/stargate restart >/dev/null 2>&1 || true
    fi
    rm -f "$current_backup" "$next_bin"
    echo "sing-box rollback restart failed; restored current binary" >&2
    exit 1
  fi
  cleanup_rollback_files
  trap - EXIT INT TERM
  "$singbox_bin" version | head -1
  echo "sing-box rolled back: $singbox_bin"
}
