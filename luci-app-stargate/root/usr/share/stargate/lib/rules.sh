# shellcheck shell=sh
rule_count() {
  file="$1"
  key="$2"
  [ -f "$file" ] || {
    printf 'not updated'
    return
  }
  awk -v key="\"$key\"" '
    function count_values(line) {
      while (match(line, /"[^"]+"/)) {
        count++
        line = substr(line, RSTART + RLENGTH)
      }
    }
    index($0, key) {
      in_array = 1
      sub(".*" key "[^[]*\\[", "")
    }
    in_array {
      line = $0
      if (line ~ /\]/) {
        sub(/\].*/, "", line)
        in_array = 0
      }
      count_values(line)
    }
    END { printf "%d", count }
  ' "$file"
}

rules_status() {
  load_config
  direct_domains="not updated"
  direct_ips="not updated"
  proxy_domains="not updated"
  proxy_ips="not updated"
  update_state="idle"
  update_last=""
  saved_state=""
  [ -s "$rules_update_status_file" ] && saved_state="$(cat "$rules_update_status_file" 2>/dev/null || true)"
  if [ -s "$rules_update_pid_file" ]; then
    update_pid="$(cat "$rules_update_pid_file" 2>/dev/null || true)"
    if [ "$saved_state" = "running" ] && [ -n "$update_pid" ] && kill -0 "$update_pid" 2>/dev/null; then
      update_state="running"
    elif [ -n "$saved_state" ]; then
      update_state="$saved_state"
    fi
  elif [ -n "$saved_state" ]; then
    update_state="$saved_state"
  fi
  if [ -s "$rules_update_log_file" ]; then
    update_last="$(awk '/^(Started|Finished) at / { line = $0 } END { print line }' "$rules_update_log_file" 2>/dev/null || true)"
  fi
  if [ -f "$rules_direct_rule_set" ]; then
    direct_domains="$(rule_count "$rules_direct_rule_set" domain_suffix) domains"
    direct_ips="$(rule_count "$rules_direct_rule_set" ip_cidr) CIDRs"
  fi
  if [ -f "$rules_proxy_rule_set" ]; then
    proxy_domains="$(rule_count "$rules_proxy_rule_set" domain_suffix) domains"
    proxy_ips="$(rule_count "$rules_proxy_rule_set" ip_cidr) CIDRs"
  fi
  printf 'Rule source: Loyalsoldier/clash-rules\n'
  printf 'Rule update: %s\n' "$update_state"
  [ -z "$update_last" ] || printf 'Last update: %s\n' "$update_last"
  printf 'Direct domains: %s\n' "$direct_domains"
  printf 'Direct IPs: %s\n' "$direct_ips"
  printf 'Proxy domains: %s\n' "$proxy_domains"
  printf 'Proxy IPs: %s\n' "$proxy_ips"
}

normalize_rule_target() {
  printf '%s' "${1:-}" | awk '
    function trim(s) { sub(/^[ \t\r\n]+/, "", s); sub(/[ \t\r\n]+$/, "", s); return s }
    {
      v = trim($0)
      sub(/^[A-Za-z][A-Za-z0-9+.-]*:\/\//, "", v)
      if (index(v, "@") > 0) sub(/^.*@/, "", v)
      cut_pos = 0
      slash_pos = index(v, "/")
      query_pos = index(v, "?")
      hash_pos = index(v, "#")
      if (slash_pos > 0) cut_pos = slash_pos
      if (query_pos > 0 && (cut_pos == 0 || query_pos < cut_pos)) cut_pos = query_pos
      if (hash_pos > 0 && (cut_pos == 0 || hash_pos < cut_pos)) cut_pos = hash_pos
      if (cut_pos > 0) v = substr(v, 1, cut_pos - 1)
      if (substr(v, 1, 1) == "[") {
        close_pos = index(v, "]")
        if (close_pos > 1) v = substr(v, 2, close_pos - 2)
      } else if (v !~ /:.*:/) {
        sub(/:[0-9]+$/, "", v)
      }
      sub(/\.$/, "", v)
      print tolower(trim(v))
      exit
    }
  '
}

is_ipv4() {
  printf '%s\n' "$1" | awk -F. '
    NF != 4 { exit 1 }
    {
      for (i = 1; i <= 4; i++) {
        if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1
      }
      exit 0
    }
  '
}

is_ip_address() {
  is_ipv4 "$1" || { printf '%s' "$1" | grep -q ':' && printf '%s' "$1" | grep -Eq '^[0-9a-f:]+$'; }
}

is_private_address() {
  target="$1"
  if is_ipv4 "$target"; then
    printf '%s\n' "$target" | awk -F. '
      $1 == 0 || $1 == 10 || $1 == 127 { exit 0 }
      $1 == 100 && $2 >= 64 && $2 <= 127 { exit 0 }
      $1 == 169 && $2 == 254 { exit 0 }
      $1 == 172 && $2 >= 16 && $2 <= 31 { exit 0 }
      $1 == 192 && $2 == 168 { exit 0 }
      $1 >= 224 { exit 0 }
      { exit 1 }
    '
    return "$?"
  fi
  case "$target" in
    ::1|fc*:*|fd*:*|fe80:*) return 0 ;;
    *) return 1 ;;
  esac
}

ipv4_to_int() {
  printf '%s\n' "$1" | awk -F. '
    NF != 4 { exit 1 }
    {
      for (i = 1; i <= 4; i++) {
        if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1
      }
      printf "%.0f\n", ($1 * 16777216) + ($2 * 65536) + ($3 * 256) + $4
    }
  '
}

parse_ipv4_cidrs() {
  list="$1"
  printf '%s\n' "$list" | tr ', \t' '\n\n\n' | awk '
    function trim(s) { sub(/^[ \t\r\n]+/, "", s); sub(/[ \t\r\n]+$/, "", s); return s }
    function valid_ip(ip, parts, i, n) {
      n = split(ip, parts, ".")
      if (n != 4) return 0
      for (i = 1; i <= 4; i++) {
        if (parts[i] !~ /^[0-9]+$/ || parts[i] < 0 || parts[i] > 255) return 0
      }
      return 1
    }
    {
      line = trim($0)
      if (line == "" || line ~ /^#/) next
      sub(/^ip-cidr:/, "", line)
      split(line, cidr, "/")
      ip = cidr[1]
      prefix = cidr[2]
      if (prefix == "") prefix = 32
      if (!valid_ip(ip) || prefix !~ /^[0-9]+$/ || prefix < 0 || prefix > 32) next
      value = ip "/" prefix
      if (!seen[value]++) print value
    }
  '
}

custom_ip_match() {
  list="$1"
  target="$2"
  is_ipv4 "$target" || return 1
  target_int="$(ipv4_to_int "$target" 2>/dev/null)" || return 1
  parse_ipv4_cidrs "$list" | awk -F/ -v target_int="$target_int" '
    function trim(s) { sub(/^[ \t\r\n]+/, "", s); sub(/[ \t\r\n]+$/, "", s); return s }
    function ipint(ip, parts, i, n) {
      n = split(ip, parts, ".")
      if (n != 4) return -1
      for (i = 1; i <= 4; i++) {
        if (parts[i] !~ /^[0-9]+$/ || parts[i] < 0 || parts[i] > 255) return -1
      }
      return (parts[1] * 16777216) + (parts[2] * 65536) + (parts[3] * 256) + parts[4]
    }
    function pow2(n, r) { r = 1; while (n-- > 0) r *= 2; return r }
    {
      base = trim($1)
      prefix = $2
      base_int = ipint(base)
      if (base_int < 0) next
      size = pow2(32 - prefix)
      network = int(base_int / size) * size
      if (target_int >= network && target_int < network + size) {
        print base "/" prefix
        found = 1
        exit
      }
    }
    END { exit found ? 0 : 1 }
  '
}

custom_domain_match() {
  list="$1"
  target="$2"
  printf '%s\n' "$list" | awk -v target="$target" '
    function trim(s) { sub(/^[ \t\r\n]+/, "", s); sub(/[ \t\r\n]+$/, "", s); return s }
    function suffix_match(domain, suffix) {
      return domain == suffix || (length(domain) > length(suffix) && substr(domain, length(domain) - length(suffix), 1) == "." && substr(domain, length(domain) - length(suffix) + 1) == suffix)
    }
    {
      line = tolower(trim($0))
      if (line == "" || line ~ /^#/) next
      sub(/^full:/, "", line)
      sub(/^domain:/, "", line)
      sub(/^\+\./, "", line)
      if (line !~ /^[a-z0-9_.-]+$/) next
      if (suffix_match(target, line)) {
        print line
        found = 1
        exit
      }
    }
    END { exit found ? 0 : 1 }
  '
}

write_inline_ip_rule() {
  list="$1"
  outbound="$2"
  cidrs="$(parse_ipv4_cidrs "$list" | awk '{ if (count++) printf ", "; printf "\"%s\"", $0 }')"
  [ -n "$cidrs" ] || return 0
  printf '{ "ip_cidr": [%s], "outbound": "%s" }' "$cidrs" "$outbound"
}

rule_set_domain_match() {
  file="$1"
  target="$2"
  [ -f "$file" ] || return 1
  candidate="$target"
  while [ -n "$candidate" ]; do
    if grep -Fq "\"$candidate\"" "$file"; then
      printf 'domain_suffix:%s\n' "$candidate"
      return 0
    fi
    case "$candidate" in
      *.*) candidate="${candidate#*.}" ;;
      *) break ;;
    esac
  done
  return 1
}

rule_set_ip_match() {
  file="$1"
  target="$2"
  [ -f "$file" ] || return 1
  is_ipv4 "$target" || return 1
  cidrs="$(awk '
    /"ip_cidr"[[:space:]]*:/ {
      in_array = 1
      sub(/.*"ip_cidr"[[:space:]]*:[[:space:]]*\[/, "")
    }
    in_array {
      line = $0
      if (line ~ /\]/) {
        sub(/\].*/, "", line)
        in_array = 0
      }
      while (match(line, /"[^"]+"/)) {
        value = substr(line, RSTART + 1, RLENGTH - 2)
        print value
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "$file")"
  custom_ip_match "$cidrs" "$target"
}

rules_test() {
  load_config
  target="$(normalize_rule_target "${1:-}")"
  [ -n "$target" ] || {
    echo "Target is required" >&2
    exit 1
  }
  printf 'Target: %s\n' "$target"

  if is_ip_address "$target"; then
    if [ "$rules_private_direct" = "1" ] && is_private_address "$target"; then
      printf 'Decision: Direct\n'
      printf 'Outbound: direct\n'
      printf 'Reason: private IP direct\n'
      return 0
    fi
    match="$(custom_ip_match "$rules_custom_direct_ips" "$target" 2>/dev/null || true)"
    if [ -n "$match" ]; then
      printf 'Decision: Direct\n'
      printf 'Outbound: direct\n'
      printf 'Reason: user direct IP (%s)\n' "$match"
      return 0
    fi
    match="$(custom_ip_match "$rules_custom_proxy_ips" "$target" 2>/dev/null || true)"
    if [ -n "$match" ]; then
      printf 'Decision: Proxy\n'
      printf 'Outbound: anytls-out\n'
      printf 'Reason: user proxy IP (%s)\n' "$match"
      return 0
    fi
    match="$(rule_set_ip_match "$rules_direct_rule_set" "$target" 2>/dev/null || true)"
    if [ -n "$match" ]; then
      printf 'Decision: Direct\n'
      printf 'Outbound: direct\n'
      printf 'Reason: direct rule-set IP (%s)\n' "$match"
      return 0
    fi
    match="$(rule_set_ip_match "$rules_proxy_rule_set" "$target" 2>/dev/null || true)"
    if [ -n "$match" ]; then
      printf 'Decision: Proxy\n'
      printf 'Outbound: anytls-out\n'
      printf 'Reason: proxy rule-set IP (%s)\n' "$match"
      return 0
    fi
    case "$rules_mode" in
      global_proxy)
        printf 'Decision: Proxy\n'
        printf 'Outbound: anytls-out\n'
        printf 'Reason: global proxy mode\n'
        ;;
      whitelist)
        printf 'Decision: Proxy\n'
        printf 'Outbound: anytls-out\n'
        printf 'Reason: whitelist default\n'
        ;;
      direct|blacklist|*)
        printf 'Decision: Direct\n'
        printf 'Outbound: direct\n'
        printf 'Reason: IP address default\n'
        ;;
    esac
    return 0
  fi

  case "$target" in *[!a-z0-9_.-]*|.*|*..*|*.) echo "Invalid domain or IP: $target" >&2; exit 1 ;; esac

  if [ "$rules_mode" = "global_proxy" ]; then
    printf 'Decision: Proxy\n'
    printf 'Outbound: anytls-out\n'
    printf 'Reason: global proxy mode\n'
    return 0
  fi
  if [ "$rules_mode" = "direct" ]; then
    printf 'Decision: Direct\n'
    printf 'Outbound: direct\n'
    printf 'Reason: direct only mode\n'
    return 0
  fi

  match="$(custom_domain_match "$rules_custom_direct_domains" "$target" 2>/dev/null || true)"
  if [ -n "$match" ]; then
    printf 'Decision: Direct\n'
    printf 'Outbound: direct\n'
    printf 'Reason: user direct domain (%s)\n' "$match"
    return 0
  fi

  match="$(custom_domain_match "$rules_custom_proxy_domains" "$target" 2>/dev/null || true)"
  if [ -n "$match" ]; then
    printf 'Decision: Proxy\n'
    printf 'Outbound: anytls-out\n'
    printf 'Reason: user proxy domain (%s)\n' "$match"
    return 0
  fi

  match="$(rule_set_domain_match "$rules_direct_rule_set" "$target" 2>/dev/null || true)"
  if [ -n "$match" ]; then
    printf 'Decision: Direct\n'
    printf 'Outbound: direct\n'
    printf 'Reason: direct rule-set (%s)\n' "$match"
    return 0
  fi

  match="$(rule_set_domain_match "$rules_proxy_rule_set" "$target" 2>/dev/null || true)"
  if [ -n "$match" ]; then
    printf 'Decision: Proxy\n'
    printf 'Outbound: anytls-out\n'
    printf 'Reason: proxy rule-set (%s)\n' "$match"
    return 0
  fi

  if [ "$rules_mode" = "whitelist" ]; then
    printf 'Decision: Proxy\n'
    printf 'Outbound: anytls-out\n'
    printf 'Reason: whitelist default\n'
  else
    printf 'Decision: Direct\n'
    printf 'Outbound: direct\n'
    printf 'Reason: blacklist default\n'
  fi
}

write_inline_domain_rule() {
  list="$1"
  outbound="$2"
  domains="$(printf '%s\n' "$list" | awk '
    function trim(s) { sub(/^[ \t\r\n]+/, "", s); sub(/[ \t\r\n]+$/, "", s); return s }
    function emit(v) {
      gsub(/\\/,"\\\\",v)
      gsub(/"/,"\\\"",v)
      if (count > 0) printf ","
      printf "\"%s\"", v
      count++
    }
    {
      line = trim($0)
      if (line == "" || line ~ /^#/) next
      if (line ~ /^full:/) line = substr(line, 6)
      else if (line ~ /^domain:/) line = substr(line, 8)
      else if (line ~ /^\+\./) line = substr(line, 3)
      if (line !~ /^[A-Za-z0-9_.-]+$/) next
      emit(line)
    }
  ')"
  [ -n "$domains" ] || return 0
  printf '{ "domain_suffix": [%s], "outbound": "%s" }' "$domains" "$outbound"
}

