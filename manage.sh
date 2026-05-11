#!/bin/sh
set -eu

usage() {
  cat <<'USAGE'
Usage:
  sh manage.sh check
  sh manage.sh check shell
  sh manage.sh check docs
  sh manage.sh check secrets
USAGE
}

check_shell() {
  sh -n scripts/stargate.sh
  sh -n manage.sh
  sh -n luci-app-stargate/root/usr/share/stargate/stargate.sh
  sh -n luci-app-stargate/root/etc/init.d/stargate
  luac -p luci-app-stargate/luasrc/controller/stargate.lua
  find luci-app-stargate/luasrc/model/cbi/stargate -type f -name '*.lua' | while IFS= read -r file; do
    luac -p "$file"
  done
}

check_docs() {
  missing=0
  for file in \
    README.md \
    AGENTS.md \
    docs/README.md \
    docs/current.md \
    docs/roadmap.md \
    docs/reference/architecture.md \
    docs/reference/naming.md \
    .gitmodules \
    luci-app-stargate/Makefile \
    luci-app-stargate/luasrc/controller/stargate.lua \
    luci-app-stargate/root/etc/config/stargate \
    luci-app-stargate/root/usr/share/luci/menu.d/luci-app-stargate.json \
    luci-app-stargate/root/usr/share/rpcd/acl.d/luci-app-stargate.json
  do
    if [ ! -f "$file" ]; then
      echo "missing: $file" >&2
      missing=1
    fi
  done
  for dir in \
    third_party/openwrt-passwall2 \
    third_party/sing-box
  do
    if [ ! -d "$dir" ]; then
      echo "missing: $dir" >&2
      missing=1
    fi
  done
  return "$missing"
}

check_json() {
  for file in \
    luci-app-stargate/root/usr/share/luci/menu.d/luci-app-stargate.json \
    luci-app-stargate/root/usr/share/rpcd/acl.d/luci-app-stargate.json
  do
    python3 -m json.tool "$file" >/dev/null
  done
}

check_js() {
  if command -v node >/dev/null 2>&1; then
    for file in luci-app-stargate/htdocs/luci-static/resources/view/stargate/*.js; do
      node --check "$file" >/dev/null
    done
  fi
}

check_i18n() {
  if command -v msgfmt >/dev/null 2>&1; then
    msgfmt -c -o /dev/null luci-app-stargate/po/zh-cn/stargate.po
  fi
  python3 tools/po2lmo.py luci-app-stargate/po/zh-cn/stargate.po /tmp/stargate.zh-cn.lmo
}

check_secrets() {
  if rg -n -I \
    -e '192\.168\.[0-9]{1,3}\.[1-9][0-9]{0,2}' \
    -e '[0-9]{6,12}Qwe' \
    -e 'ssh''pass' \
    -e 'root@''192\.' \
    -e 'Bleach''Wrt' \
    -e 'R[0-9]{2}\.[0-9]{2}' \
    --glob '!third_party/**' \
    --glob '!.git/**' \
    .; then
    echo "potential environment-specific secret or hardcoding found" >&2
    return 1
  fi
}

action="${1:-}"
target="${2:-all}"

case "$action:$target" in
  check:all|check:"")
    check_shell
    check_docs
    check_json
    check_js
    check_i18n
    check_secrets
    ;;
  check:shell)
    check_shell
    ;;
  check:docs)
    check_docs
    ;;
  check:json)
    check_json
    ;;
  check:js)
    check_js
    ;;
  check:i18n)
    check_i18n
    ;;
  check:secrets)
    check_secrets
    ;;
  -h:*|--help:*|help:*|:"")
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
