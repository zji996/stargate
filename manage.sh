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
  for file in luci-app-stargate/root/usr/share/stargate/lib/*.sh; do
    sh -n "$file"
  done
  find tools -type f -name '*.sh' | while IFS= read -r file; do
    sh -n "$file"
  done
  find tests -type f -name '*.sh' | while IFS= read -r file; do
    sh -n "$file"
    sh "$file"
  done
  if command -v luac >/dev/null 2>&1; then
    luac -p luci-app-stargate/luasrc/controller/stargate.lua
    luac -p luci-app-stargate/luasrc/model/stargate/common.lua
    find luci-app-stargate/luasrc/model/cbi/stargate -type f -name '*.lua' | while IFS= read -r file; do
      luac -p "$file"
    done
  elif command -v lua >/dev/null 2>&1; then
    lua -e 'assert(loadfile(arg[1]))' luci-app-stargate/luasrc/controller/stargate.lua
    find luci-app-stargate/luasrc/model/cbi/stargate -type f -name '*.lua' | while IFS= read -r file; do
      lua -e 'assert(loadfile(arg[1]))' "$file"
    done
  elif command -v docker >/dev/null 2>&1 && docker image inspect nickblah/lua:5.1 >/dev/null 2>&1; then
    # Local fallback: reuse an already pulled Lua 5.1 image, never pull during check.
    docker run --rm -v "$PWD/luci-app-stargate/luasrc:/src:ro" nickblah/lua:5.1 sh -c '
      set -e
      luac -p /src/controller/stargate.lua
      luac -p /src/model/stargate/common.lua
      find /src/model/cbi/stargate -type f -name "*.lua" | while IFS= read -r file; do
        luac -p "$file"
      done
    '
  else
    echo "skip Lua syntax check: lua/luac not found (install lua5.1 or pull nickblah/lua:5.1 for docker fallback)" >&2
  fi
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
    docs/reference/s20m-nftables-build.md \
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
    node --check luci-app-stargate/htdocs/luci-static/resources/stargate-cbi.js
    node --check luci-app-stargate/htdocs/luci-static/resources/stargate-overview.js
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
  rg_bin=""
  if command -v rg >/dev/null 2>&1; then
    rg_bin="rg"
  fi

  if [ -n "$rg_bin" ]; then
    if "$rg_bin" -n -I \
      -e '192\.168\.[0-9]{1,3}\.[1-9][0-9]{0,2}' \
      -e '[0-9]{6,12}Qwe' \
      -e 'ssh''pass' \
      -e 'root@''192\.' \
      -e 'Bleach''Wrt' \
      -e 'R[0-9]{2}\.[0-9]{2}' \
      --glob '!third_party/**' \
      --glob '!.git/**' \
      --glob '!docs/current.md' \
      .; then
      echo "potential environment-specific secret or hardcoding found" >&2
      return 1
    fi
  else
    # Split literals the same way as the rg branch so this file never matches itself.
    secret_pattern='192\.168\.[0-9]{1,3}\.[1-9][0-9]{0,2}|[0-9]{6,12}Qwe|ssh''pass|root@''192\.|Bleach''Wrt|R[0-9]{2}\.[0-9]{2}'
    if grep -r -E -n -I \
      --exclude-dir='third_party' \
      --exclude-dir='.git' \
      --exclude='current.md' \
      -e "$secret_pattern" \
      .; then
      echo "potential environment-specific secret or hardcoding found" >&2
      return 1
    fi
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
