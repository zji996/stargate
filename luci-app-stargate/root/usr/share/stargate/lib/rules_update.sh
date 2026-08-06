# shellcheck shell=sh
json_arrays_from_clash_payloads() {
  key="$1"
  shift
  awk -v key="$key" '
    function trim(s) { sub(/^[ \t\r\n]+/, "", s); sub(/[ \t\r\n]+$/, "", s); return s }
    function strip_value(s) {
      s = trim(s)
      sub(/^- /, "", s)
      s = trim(s)
      sub(/^'\''/, "", s)
      sub(/'\''$/, "", s)
      sub(/^"/, "", s)
      sub(/"$/, "", s)
      return s
    }
    function emit(v) {
      gsub(/\\/,"\\\\",v)
      gsub(/"/,"\\\"",v)
      if (seen[v]) return
      seen[v] = 1
      if (count > 0) printf ",\n"
      printf "        \"%s\"", v
      count++
    }
    {
      line = trim($0)
      if (line == "" || line ~ /^#/) next
      if (line !~ /^- /) next
      value = strip_value(line)
      if (value == "" || value ~ /^PROCESS-NAME,/) next
      if (value ~ /^DOMAIN,/) value = substr(value, 8)
      else if (value ~ /^DOMAIN-SUFFIX,/) value = substr(value, 15)
      else if (value ~ /^DOMAIN-KEYWORD,/) value = substr(value, 16)
      else if (value ~ /^IP-CIDR,/) value = substr(value, 9)
      else if (value ~ /^IP-CIDR6,/) value = substr(value, 10)
      sub(/,no-resolve$/, "", value)
      if (key == "domain_suffix") {
        sub(/^\+\./, "", value)
        if (value ~ /^[A-Za-z0-9_.-]+$/) emit(value)
      } else if (key == "domain") {
        if (value ~ /^[A-Za-z0-9_.-]+$/ && value !~ /^\+\./) emit(value)
      } else if (key == "domain_keyword") {
        if (value ~ /^[A-Za-z0-9_.-]+$/) emit(value)
      } else if (key == "ip_cidr") {
        if (value ~ /^[0-9A-Fa-f:.]+\/[0-9]+$/) emit(value)
      }
    }
  ' "$@"
}

write_rule_set_json() {
  domain_inputs="$1"
  ip_inputs="$2"
  output="$3"
  tmp="$output.tmp"
  mkdir -p "$(dirname "$output")"
  {
    printf '{\n  "version": 3,\n  "rules": [\n'
    printf '    {\n      "domain_suffix": [\n'
    # shellcheck disable=SC2086
    json_arrays_from_clash_payloads domain_suffix $domain_inputs
    printf '\n      ],\n      "domain_keyword": [\n'
    # shellcheck disable=SC2086
    json_arrays_from_clash_payloads domain_keyword $domain_inputs
    printf '\n      ],\n      "ip_cidr": [\n'
    # shellcheck disable=SC2086
    json_arrays_from_clash_payloads ip_cidr $ip_inputs
    printf '\n      ]\n    }\n'
    printf '  ]\n}\n'
  } >"$tmp"
  mv "$tmp" "$output"
}

compile_rule_set() {
  source="$1"
  output="$(rule_set_runtime_path "$source")"
  command -v "$singbox_bin" >/dev/null 2>&1 || {
    echo "sing-box is required to compile rule-set: $singbox_bin" >&2
    exit 1
  }
  "$singbox_bin" rule-set compile "$source" -o "$output" >/dev/null
}

fetch_rule_list() {
  url="$1"
  output="$2"
  attempt=1
  while [ "$attempt" -le 3 ]; do
    if curl -fsSL --connect-timeout 8 --max-time 180 "$url" -o "$output"; then
      return 0
    fi
    rm -f "$output"
    attempt=$((attempt + 1))
    sleep 2
  done
  return 1
}

geoip_remote_name() {
  name="$(basename "$1")"
  name="${name%.srs}"
  name="${name#geoip-}"
  printf '%s.srs' "$name"
}

fetch_geoip_rule_set() {
  target="$1"
  output="${2:-$1}"
  remote_name="$(geoip_remote_name "$target")"
  fetch_rule_list "${rules_geoip_base_url%/}/$remote_name" "$output"
  [ -s "$output" ] || { echo "downloaded GeoIP rule-set is empty: $remote_name" >&2; exit 1; }
}

update_geoip_rule_sets() {
  stage_dir="$1"
  manifest="$2"
  if [ -n "$rules_geoip_direct_rule_set" ]; then
    staged="$stage_dir/geoip-direct.srs"
    fetch_geoip_rule_set "$rules_geoip_direct_rule_set" "$staged"
    printf '%s\t%s\n' "$staged" "$rules_geoip_direct_rule_set" >>"$manifest"
  fi
  geoip_index=1
  printf '%s\n' "$rules_geoip_proxy_rule_sets" | tr ', \t' '\n\n\n' | while IFS= read -r geoip_rule_set; do
    [ -n "$geoip_rule_set" ] || continue
    staged="$stage_dir/geoip-proxy-$geoip_index.srs"
    fetch_geoip_rule_set "$geoip_rule_set" "$staged"
    printf '%s\t%s\n' "$staged" "$geoip_rule_set" >>"$manifest"
    geoip_index=$((geoip_index + 1))
  done
}

install_staged_rule_sets() {
  manifest="$1"
  while IFS="$(printf '\t')" read -r staged target; do
    [ -n "$staged" ] && [ -n "$target" ] || continue
    mkdir -p "$(dirname "$target")"
    cp -f "$staged" "$target"
  done <"$manifest"
}

rules_update_core() {
  load_config
  [ "$rules_source" = "loyalsoldier" ] || {
    echo "unsupported rules source: $rules_source" >&2
    exit 1
  }
  command -v curl >/dev/null 2>&1 || {
    echo "curl is required to update rules" >&2
    exit 1
  }

  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
  stage_dir="$tmp_dir/staged"
  install_manifest="$tmp_dir/install.manifest"
  mkdir -p "$stage_dir"
  : >"$install_manifest"
  base="${rules_source_base_url%/}"
  for name in direct private proxy gfw tld-not-cn cncidr telegramcidr lancidr; do
    fetch_rule_list "$base/$name.txt" "$tmp_dir/$name.txt"
    [ -s "$tmp_dir/$name.txt" ] || { echo "downloaded $name list is empty" >&2; exit 1; }
  done
  staged_direct="$stage_dir/direct.json"
  staged_proxy="$stage_dir/proxy.json"
  write_rule_set_json "$tmp_dir/direct.txt $tmp_dir/private.txt" "$tmp_dir/cncidr.txt $tmp_dir/lancidr.txt" "$staged_direct"
  write_rule_set_json "$tmp_dir/proxy.txt $tmp_dir/gfw.txt $tmp_dir/tld-not-cn.txt" "$tmp_dir/telegramcidr.txt" "$staged_proxy"
  compile_rule_set "$staged_direct"
  compile_rule_set "$staged_proxy"
  printf '%s\t%s\n' "$staged_direct" "$rules_direct_rule_set" >>"$install_manifest"
  printf '%s\t%s\n' "$(rule_set_runtime_path "$staged_direct")" "$(rule_set_runtime_path "$rules_direct_rule_set")" >>"$install_manifest"
  printf '%s\t%s\n' "$staged_proxy" "$rules_proxy_rule_set" >>"$install_manifest"
  printf '%s\t%s\n' "$(rule_set_runtime_path "$staged_proxy")" "$(rule_set_runtime_path "$rules_proxy_rule_set")" >>"$install_manifest"
  update_geoip_rule_sets "$stage_dir" "$install_manifest"
  install_staged_rule_sets "$install_manifest"
  echo "Rules updated."
  if /etc/init.d/stargate status >/dev/null 2>&1; then
    echo "Reloading Stargate with updated rules."
    "$0" apply-runtime
  fi
}

rules_update() {
  if [ "${STARGATE_RULE_UPDATE_MANAGED:-0}" = "1" ]; then
    rules_update_core
    return
  fi

  printf 'running\n' >"$rules_update_status_file"
  printf 'Started at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$rules_update_log_file"
  if (rules_update_core); then
    printf 'Finished at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$rules_update_log_file"
    printf 'success\n' >"$rules_update_status_file"
  else
    code="$?"
    printf 'Finished at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$rules_update_log_file"
    printf 'failed (%s)\n' "$code" >"$rules_update_status_file"
    return "$code"
  fi
  rules_status
}

rules_update_start() {
  if [ -s "$rules_update_pid_file" ]; then
    update_pid="$(cat "$rules_update_pid_file" 2>/dev/null || true)"
    update_state="$(cat "$rules_update_status_file" 2>/dev/null || true)"
    if [ "$update_state" = "running" ] && [ -n "$update_pid" ] && kill -0 "$update_pid" 2>/dev/null; then
      echo "Rule update is already running."
      rules_status
      return 0
    fi
  fi

  rm -f "$rules_update_pid_file"
  printf 'running\n' >"$rules_update_status_file"
  {
    printf 'Started at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$rules_update_log_file"

  (
    trap '' HUP
    if STARGATE_RULE_UPDATE_MANAGED=1 "$0" rules-update >>"$rules_update_log_file" 2>&1; then
      printf 'Finished at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$rules_update_log_file"
      printf 'success\n' >"$rules_update_status_file"
    else
      code="$?"
      printf 'Finished at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$rules_update_log_file"
      printf 'failed (%s)\n' "$code" >"$rules_update_status_file"
    fi
    rm -f "$rules_update_pid_file"
  ) </dev/null >/dev/null 2>&1 &
  printf '%s\n' "$!" >"$rules_update_pid_file"

  echo "Rule update started."
  rules_status
}
