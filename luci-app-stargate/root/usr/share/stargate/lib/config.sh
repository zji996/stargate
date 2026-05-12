# shellcheck shell=sh
write_dns_servers() {
  esc_local="$(printf '%s' "$dns_local_server" | json_escape)"
  esc_local_path="$(printf '%s' "$dns_local_path" | json_escape)"
  esc_remote="$(printf '%s' "$dns_remote_server" | json_escape)"
  esc_path="$(printf '%s' "$dns_remote_path" | json_escape)"
  esc_detour="$(printf '%s' "$dns_remote_detour" | json_escape)"

  printf '      { "tag": "local", "type": "local" },\n'
  if [ "$dns_local_type" = "https" ]; then
    printf '      { "tag": "direct-dns", "type": "https", "server": "%s", "path": "%s" },\n' "$esc_local" "$esc_local_path"
  else
    printf '      { "tag": "direct-dns", "type": "%s", "server": "%s" },\n' "$dns_local_type" "$esc_local"
  fi
  if [ "$dns_remote_type" = "https" ]; then
    printf '      { "tag": "remote-doh", "type": "https", "server": "%s", "path": "%s", "detour": "%s", "domain_resolver": { "server": "direct-dns", "strategy": "%s" } }\n' "$esc_remote" "$esc_path" "$esc_detour" "$dns_strategy"
  else
    printf '      { "tag": "remote-doh", "type": "%s", "server": "%s", "detour": "%s", "domain_resolver": { "server": "direct-dns", "strategy": "%s" } }\n' "$dns_remote_type" "$esc_remote" "$esc_detour" "$dns_strategy"
  fi
}

write_dns_rules() {
  if [ "$rules_mode" = "blacklist" ] || [ "$rules_mode" = "whitelist" ]; then
    printf '      { "rule_set": "direct", "server": "direct-dns" },\n'
    printf '      { "rule_set": "proxy", "server": "remote-doh" }\n'
  fi
}

write_inbounds() {
  printf '    {\n'
  printf '      "type": "socks",\n'
  printf '      "tag": "socks-in",\n'
  printf '      "listen": "%s",\n' "$esc_socks_listen"
  printf '      "listen_port": %s\n' "$socks_port"
  printf '    },\n'
  printf '    {\n'
  printf '      "type": "http",\n'
  printf '      "tag": "http-in",\n'
  printf '      "listen": "%s",\n' "$esc_http_listen"
  printf '      "listen_port": %s\n' "$http_port"
  printf '    }'
  if [ "$transparent_proxy" = "1" ]; then
    printf ',\n'
    printf '    {\n'
    printf '      "type": "%s",\n' "$transparent_mode"
    printf '      "tag": "transparent-in",\n'
    printf '      "listen": "%s",\n' "$esc_transparent_listen"
    printf '      "listen_port": %s' "$transparent_port"
    if [ "$transparent_mode" = "tproxy" ]; then
      printf ',\n      "network": "tcp"\n'
    else
      printf '\n'
    fi
    printf '    }'
    if [ "$dns_hijack" = "1" ]; then
      printf ',\n'
      printf '    {\n'
      printf '      "type": "direct",\n'
      printf '      "tag": "dns-in",\n'
      printf '      "listen": "0.0.0.0",\n'
      printf '      "listen_port": %s,\n' "$dns_hijack_port"
      printf '      "override_address": "1.0.0.1",\n'
      printf '      "override_port": 53\n'
      printf '    }'
    fi
  fi
  printf '\n'
}

write_rule_sets() {
  if [ "$rules_mode" = "blacklist" ] || [ "$rules_mode" = "whitelist" ]; then
    printf '      {\n'
    printf '        "type": "local",\n'
    printf '        "tag": "direct",\n'
    printf '        "format": "%s",\n' "$direct_rule_set_format"
    printf '        "path": "%s"\n' "$esc_direct_runtime_rule_set"
    printf '      },\n'
    printf '      {\n'
    printf '        "type": "local",\n'
    printf '        "tag": "proxy",\n'
    printf '        "format": "%s",\n' "$proxy_rule_set_format"
    printf '        "path": "%s"\n' "$esc_proxy_runtime_rule_set"
    printf '      }'
    if [ -n "$rules_geoip_direct_rule_set" ]; then
      esc_geoip_direct_rule_set="$(printf '%s' "$rules_geoip_direct_rule_set" | json_escape)"
      printf ',\n'
      printf '      {\n'
      printf '        "type": "local",\n'
      printf '        "tag": "geoip-direct",\n'
      printf '        "format": "binary",\n'
      printf '        "path": "%s"\n' "$esc_geoip_direct_rule_set"
      printf '      }'
    fi
    geoip_index=1
    printf '%s\n' "$rules_geoip_proxy_rule_sets" | tr ', \t' '\n\n\n' | while IFS= read -r geoip_proxy_rule_set; do
      [ -n "$geoip_proxy_rule_set" ] || continue
      esc_geoip_proxy_rule_set="$(printf '%s' "$geoip_proxy_rule_set" | json_escape)"
      printf ',\n'
      printf '      {\n'
      printf '        "type": "local",\n'
      printf '        "tag": "geoip-proxy-%s",\n' "$geoip_index"
      printf '        "format": "binary",\n'
      printf '        "path": "%s"\n' "$esc_geoip_proxy_rule_set"
      printf '      }'
      geoip_index=$((geoip_index + 1))
    done
    printf '\n'
  fi
}

write_route_rules() {
  first=1
  add_rule() {
    if [ "$first" = 1 ]; then
      first=0
    else
      printf ',\n'
    fi
    printf '      %s' "$1"
  }

  if [ "$transparent_proxy" = "1" ]; then
    add_rule '{ "inbound": ["transparent-in"], "action": "sniff", "sniffer": ["tls", "http"], "timeout": "500ms" }'
    if [ "$dns_hijack" = "1" ]; then
      add_rule '{ "inbound": ["dns-in"], "action": "hijack-dns" }'
    fi
  fi
  if [ "$rules_block_quic" = "1" ]; then
    add_rule '{ "network": "udp", "port": 443, "action": "reject" }'
  fi
  if [ "$rules_private_direct" = "1" ]; then
    add_rule '{ "ip_is_private": true, "outbound": "direct" }'
  fi
  custom_direct_ip_rule="$(write_inline_ip_rule "$rules_custom_direct_ips" "direct")"
  geoip_proxy_extra_ip_rule="$(write_inline_ip_rule "$rules_geoip_proxy_extra_cidrs" "anytls-out")"
  custom_proxy_ip_rule="$(write_inline_ip_rule "$rules_custom_proxy_ips" "anytls-out")"
  [ -z "$custom_direct_ip_rule" ] || add_rule "$custom_direct_ip_rule"
  [ -z "$custom_proxy_ip_rule" ] || add_rule "$custom_proxy_ip_rule"
  [ -z "$geoip_proxy_extra_ip_rule" ] || add_rule "$geoip_proxy_extra_ip_rule"
  if [ "$rules_mode" = "blacklist" ] || [ "$rules_mode" = "whitelist" ]; then
    custom_direct_rule="$(write_inline_domain_rule "$rules_custom_direct_domains" "direct")"
    custom_proxy_rule="$(write_inline_domain_rule "$rules_custom_proxy_domains" "anytls-out")"
    [ -z "$custom_direct_rule" ] || add_rule "$custom_direct_rule"
    [ -z "$custom_proxy_rule" ] || add_rule "$custom_proxy_rule"
    add_rule '{ "rule_set": "proxy", "outbound": "anytls-out" }'
    geoip_index=1
    printf '%s\n' "$rules_geoip_proxy_rule_sets" | tr ', \t' '\n\n\n' | while IFS= read -r geoip_proxy_rule_set; do
      [ -n "$geoip_proxy_rule_set" ] || continue
      add_rule "{ \"rule_set\": \"geoip-proxy-$geoip_index\", \"outbound\": \"anytls-out\" }"
      geoip_index=$((geoip_index + 1))
    done
    add_rule '{ "rule_set": "direct", "outbound": "direct" }'
    if [ -n "$rules_geoip_direct_rule_set" ]; then
      add_rule '{ "rule_set": "geoip-direct", "outbound": "direct" }'
    fi
    if [ -n "$rules_geoip_direct_rule_set" ] || [ -n "$rules_geoip_proxy_rule_sets" ]; then
      add_rule "{ \"action\": \"resolve\", \"server\": \"direct-dns\", \"strategy\": \"$dns_strategy\" }"
      add_rule '{ "rule_set": "proxy", "outbound": "anytls-out" }'
      geoip_index=1
      printf '%s\n' "$rules_geoip_proxy_rule_sets" | tr ', \t' '\n\n\n' | while IFS= read -r geoip_proxy_rule_set; do
        [ -n "$geoip_proxy_rule_set" ] || continue
        add_rule "{ \"rule_set\": \"geoip-proxy-$geoip_index\", \"outbound\": \"anytls-out\" }"
        geoip_index=$((geoip_index + 1))
      done
      add_rule '{ "rule_set": "direct", "outbound": "direct" }'
      if [ -n "$rules_geoip_direct_rule_set" ]; then
        add_rule '{ "rule_set": "geoip-direct", "outbound": "direct" }'
      fi
    fi
    if [ "$rules_mode" = "blacklist" ]; then
      rules_default_outbound="direct"
    else
      rules_default_outbound="anytls-out"
    fi
  elif [ "$rules_mode" = "global_proxy" ]; then
    rules_default_outbound="anytls-out"
  elif [ "$rules_mode" = "direct" ]; then
    rules_default_outbound="direct"
  fi
  printf '\n'
}

generate_config() {
  load_config
  validate_config
  mkdir -p "$work_dir"

  esc_server="$(printf '%s' "$node_server" | json_escape)"
  esc_password="$(printf '%s' "$node_password" | json_escape)"
  esc_sni="$(printf '%s' "$node_sni" | json_escape)"
  esc_socks_listen="$(printf '%s' "$socks_listen" | json_escape)"
  esc_http_listen="$(printf '%s' "$http_listen" | json_escape)"
  esc_transparent_listen="$(printf '%s' "$transparent_listen" | json_escape)"
  direct_runtime_rule_set="$(rule_set_runtime_path "$rules_direct_rule_set")"
  proxy_runtime_rule_set="$(rule_set_runtime_path "$rules_proxy_rule_set")"
  direct_rule_set_format="$(rule_set_runtime_format "$rules_direct_rule_set")"
  proxy_rule_set_format="$(rule_set_runtime_format "$rules_proxy_rule_set")"
  esc_direct_runtime_rule_set="$(printf '%s' "$direct_runtime_rule_set" | json_escape)"
  esc_proxy_runtime_rule_set="$(printf '%s' "$proxy_runtime_rule_set" | json_escape)"
  tls_server_name=""
  if [ -n "$node_sni" ]; then
    tls_server_name=", \"server_name\": \"$esc_sni\""
  fi

  {
    cat <<EOF
{
  "log": {
    "level": "$log_level",
    "timestamp": true
  },
  "dns": {
    "servers": [
EOF
    write_dns_servers
    cat <<EOF
    ],
    "rules": [
EOF
    write_dns_rules
    cat <<EOF
    ],
    "final": "$dns_final",
    "strategy": "$dns_strategy",
    "independent_cache": true,
    "reverse_mapping": true
  },
  "inbounds": [
EOF
    write_inbounds
    cat <<EOF
  ],
  "outbounds": [
    {
      "type": "anytls",
      "tag": "anytls-out",
      "server": "$esc_server",
      "server_port": $node_port,
      "password": "$esc_password",
      "idle_session_check_interval": "30s",
      "idle_session_timeout": "30s",
      "min_idle_session": 5,
      "tls": {
        "enabled": true,
        "insecure": $(bool_json "$node_insecure")$tls_server_name
      }
    },
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" }
  ],
  "route": {
    "default_domain_resolver": "direct-dns",
    "rule_set": [
EOF
    write_rule_sets
    cat <<EOF
    ],
    "rules": [
EOF
    write_route_rules
    cat <<EOF
    ],
    "final": "$rules_default_outbound"
  }
}
EOF
  } >"$next_file"
  echo "$next_file"
}

check_next() {
  [ -x "$singbox_bin" ] || {
    echo "sing-box not found: $singbox_bin" >&2
    exit 1
  }
  "$singbox_bin" check -c "$next_file"
}

apply_config() {
  load_config
  generated="$(generate_config)"
  next_file="$generated"
  check_next
  if [ "$backup_on_apply" = "1" ] && [ -f "$config_file" ]; then
    cp -a "$config_file" "$backup_file"
  fi
  mv "$next_file" "$config_file"
  echo "config applied: $config_file"
}

restore_backup_config() {
  load_config
  [ -f "$backup_file" ] || {
    echo "no backup config found: $backup_file" >&2
    return 1
  }
  [ -x "$singbox_bin" ] || {
    echo "sing-box not found: $singbox_bin" >&2
    return 1
  }
  "$singbox_bin" check -c "$backup_file"
  if [ -f "$config_file" ]; then
    cp -a "$config_file" "$config_file.rollback_from"
  fi
  cp -a "$backup_file" "$config_file"
  echo "rolled back config: $backup_file -> $config_file"
}

rollback_config() {
  restore_backup_config
  if pgrep -af "sing-box run -c" 2>/dev/null | grep -F -- "$config_file" >/dev/null 2>&1; then
    /etc/init.d/stargate restart
    echo "service restarted with backup config"
  else
    echo "service is not running; backup config restored"
  fi
}

restart_service_with_rollback() {
  if /etc/init.d/stargate status >/dev/null 2>&1; then
    restart_output="$(/etc/init.d/stargate restart 2>&1)" && {
      [ -z "$restart_output" ] || printf '%s\n' "$restart_output"
      echo "service restarted"
      return 0
    }
  else
    /etc/init.d/stargate stop >/dev/null 2>&1 || true
    if /etc/init.d/stargate start; then
      echo "service started"
      return 0
    fi
  fi

  if [ -n "${restart_output:-}" ]; then
    printf '%s\n' "$restart_output" >&2
  fi

  echo "service restart failed; trying rollback" >&2
  restore_backup_config || return 1
  if /etc/init.d/stargate status >/dev/null 2>&1; then
    /etc/init.d/stargate restart
    echo "service restarted"
    return 0
  fi

  /etc/init.d/stargate stop >/dev/null 2>&1 || true
  if /etc/init.d/stargate start; then
    echo "rollback applied and service started"
    return 0
  fi

  echo "service restart still failed after rollback" >&2
  return 1
}
