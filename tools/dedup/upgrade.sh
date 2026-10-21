#!/bin/sh
# Upgrades a router's dedup front and, with --server, resizes the decoder on
# its exit server in one go. The decoder restarts first, then the front, so
# both caches start cold once instead of twice. Without --server the decoder
# and its cache are left alone. sing-box and anytls-server are not restarted.
#
# Dry run unless --apply: checks both ends and stages the files on the router
# in /tmp (removed again), without touching configuration or services.
set -eu

usage() {
  cat >&2 <<'USAGE'
usage: tools/dedup/upgrade.sh --router root@ROUTER [--server root@SERVER] [options] [--apply]

  --server HOST        also resize the decoder there; omit to upgrade the front only

  --index-mib N        front index, about 90% of the decoder cache (default 576)
  --cache-mib N        decoder cache (default 640)
  --inflight-mib N     decoder memory for frames being rebuilt (default 128)
  --memory-max-mib N   decoder hard limit, systemd MemoryMax (default 1024)
  --build DIR          stargate-dedup builds from tools/dedup/build.sh
                       (default .local/dedup-build)
USAGE
  exit 2
}

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
router="" server="" apply=0
index_mib=576 cache_mib=640 inflight_mib=128 memory_max_mib=1024
build="$repo/.local/dedup-build"
while [ $# -gt 0 ]; do
  case "$1" in
    --router) router=$2; shift 2 ;;
    --server) server=$2; shift 2 ;;
    --index-mib) index_mib=$2; shift 2 ;;
    --cache-mib) cache_mib=$2; shift 2 ;;
    --inflight-mib) inflight_mib=$2; shift 2 ;;
    --memory-max-mib) memory_max_mib=$2; shift 2 ;;
    --build) build=$2; shift 2 ;;
    --apply) apply=1; shift ;;
    *) usage ;;
  esac
done
[ -n "$router" ] || usage
for n in "$index_mib" "$cache_mib" "$inflight_mib" "$memory_max_mib"; do
  case "$n" in ''|*[!0-9]*) echo "sizes must be whole MiB: $n" >&2; exit 2 ;; esac
done
# The decoder's own formula for its Go soft limit (cmd/dedup -memory-mib).
memory_mib=$((cache_mib * 5 / 4 + inflight_mib + 64))
[ "$memory_mib" -le $((memory_max_mib - 16)) ] || {
  echo "decoder soft limit ${memory_mib} MiB leaves no room under MemoryMax ${memory_max_mib} MiB" >&2
  exit 2
}
[ "$index_mib" -le "$cache_mib" ] || { echo "index-mib must not exceed cache-mib" >&2; exit 2; }

ssh_opts="-o BatchMode=yes -o ConnectTimeout=10"
step() { printf '\n== %s\n' "$*"; }
say() { printf '   %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
on_router() { ssh $ssh_opts "$router" "$@"; }
on_server() { ssh $ssh_opts "$server" "$@"; }

root_files="usr/share/stargate/dedup.sh usr/share/stargate/lib/config.sh etc/init.d/stargate-dedup"
stage=/tmp/stargate-dedup-stage
mode=$([ "$apply" = 1 ] && echo APPLY || echo DRY-RUN)
echo "dedup upgrade ($mode): router $router, server ${server:-(none, decoder left as is)}"

# ---- router preflight ------------------------------------------------------
step "router: preflight"
arch=$(on_router uname -m) || die "cannot reach $router"
case "$arch" in
  aarch64) bin="$build/linux_arm64/stargate-dedup" ;;
  x86_64) bin="$build/linux_amd64/stargate-dedup" ;;
  *) die "unsupported router architecture $arch" ;;
esac
[ -x "$bin" ] || die "missing $bin; run sh tools/dedup/build.sh"
say "front build: $(go version -m "$bin" 2>/dev/null | head -1 | awk '{print $2}') $(sha256sum "$bin" | cut -c1-16)"
on_router sh -s <<'EOF' || die "router is not in a state to upgrade"
set -e
status=$(/usr/share/stargate/dedup.sh status)
printf '%s\n' "$status" | grep -q '^switch: on' || { echo "dedup switch is not on" >&2; exit 1; }
printf '%s\n' "$status" | grep -q '^front: up' || { echo "front is not up" >&2; exit 1; }
/etc/init.d/stargate status >/dev/null || { echo "stargate is not running" >&2; exit 1; }
next=$(/usr/share/stargate/stargate.sh generate 2>/dev/null) || true
cmp -s /etc/stargate/config.json.next /etc/stargate/config.json ||
  { echo "generated sing-box config differs from the running one; resolve that first" >&2; exit 1; }
rm -f /etc/stargate/config.json.next
echo "   switch on, front up, stargate running, sing-box config in sync"
echo "   devices: $(uci -q get stargate.dedup.devices)"
echo "   index_mib: $(uci -q get stargate.dedup.index_mib || echo '(unset)')"
echo "   front: $(pgrep -f '^/usr/bin/stargate-dedup front' | wc -l) process(es), cgroup $(($(cat /sys/fs/cgroup/services/stargate-dedup/memory.current) >> 20)) MiB"
echo "   memory available: $(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo) MiB"
EOF
# The decoder the front answers to now; without --server it stays the same.
old_epoch=$(on_router "/usr/share/stargate/dedup.sh status" | grep -o '"main": {[^}]*' | grep -o '"epoch": "[0-9a-f]*"' | cut -d'"' -f4)
say "main lane decoder: ${old_epoch:-(none yet)}"
changed=""
for f in usr/bin/stargate-dedup $root_files; do
  if [ "$f" = usr/bin/stargate-dedup ]; then src=$bin; else src="$repo/luci-app-stargate/root/$f"; fi
  remote=$(on_router "md5sum /$f 2>/dev/null | cut -d' ' -f1" || true)
  if [ "$remote" = "$(md5sum <"$src" | cut -d' ' -f1)" ]; then
    say "unchanged: /$f"
  else
    say "will replace: /$f"
    changed="$changed $f"
  fi
done
# Files this upgrade does not ship must already match, or they may not fit.
for f in usr/share/stargate/stargate.sh usr/share/stargate/lib/common.sh usr/share/stargate/lib/rules.sh \
  usr/share/stargate/lib/firewall.sh usr/share/stargate/lib/nodes.sh usr/share/stargate/lib/service.sh \
  usr/share/stargate/lib/maintenance.sh; do
  [ "$(on_router "md5sum /$f | cut -d' ' -f1")" = "$(md5sum <"$repo/luci-app-stargate/root/$f" | cut -d' ' -f1)" ] ||
    die "/$f on the router differs from this repository; deploy it first"
done

step "router: stage files in $stage"
on_router "rm -rf $stage && mkdir -p $stage/lib"
on_router "cat > $stage/stargate-dedup && chmod 755 $stage/stargate-dedup" <"$bin"
on_router "cat > $stage/dedup.sh" <"$repo/luci-app-stargate/root/usr/share/stargate/dedup.sh"
on_router "cat > $stage/lib/config.sh" <"$repo/luci-app-stargate/root/usr/share/stargate/lib/config.sh"
on_router "cat > $stage/stargate-dedup.init" <"$repo/luci-app-stargate/root/etc/init.d/stargate-dedup"
for pair in "stargate-dedup:$bin" "dedup.sh:$repo/luci-app-stargate/root/usr/share/stargate/dedup.sh" \
  "lib/config.sh:$repo/luci-app-stargate/root/usr/share/stargate/lib/config.sh" \
  "stargate-dedup.init:$repo/luci-app-stargate/root/etc/init.d/stargate-dedup"; do
  [ "$(on_router "sha256sum $stage/${pair%%:*} | cut -d' ' -f1")" = "$(sha256sum <"${pair#*:}" | cut -d' ' -f1)" ] ||
    die "staged ${pair%%:*} does not match"
done
on_router "sh -n $stage/dedup.sh && sh -n $stage/lib/config.sh && sh -n $stage/stargate-dedup.init && $stage/stargate-dedup front -h 2>&1 | grep -q inflight-wait" ||
  die "staged files do not run on the router"
say "staged and verified: checksums, shell syntax, binary runs on $arch"

# ---- server preflight ------------------------------------------------------
if [ -n "$server" ]; then
step "server: preflight"
on_server bash -s -- "$memory_max_mib" <<'EOF' || die "server is not in a state to resize"
set -eu
max=$1
for unit in anytls-dedup anytls-server; do
  systemctl is-active -q "$unit" || { echo "$unit is not active" >&2; exit 1; }
done
grep -q '^MemoryMax=' /etc/systemd/system/anytls-dedup.service || { echo "unit has no MemoryMax line" >&2; exit 1; }
for key in CACHE_MIB INFLIGHT_MIB MEMORY_MIB MEMORY_MAX_MIB; do
  grep -q "^ANYTLS_DEDUP_$key=" /etc/anytls/dedup.env || { echo "dedup.env lacks ANYTLS_DEDUP_$key" >&2; exit 1; }
done
echo "   current: $(grep -E '^ANYTLS_DEDUP_(CACHE|INFLIGHT|MEMORY|MEMORY_MAX)_MIB=' /etc/anytls/dedup.env | sed 's/ANYTLS_DEDUP_//' | tr '\n' ' ')"
current=$(systemctl show anytls-dedup -p MemoryCurrent --value)
avail=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
echo "   decoder uses $((current >> 20)) MiB; server has $avail MiB available"
# Room for the new limit once the decoder's current memory is freed, plus 256 MiB.
[ $((avail + (current >> 20))) -ge $((max + 256)) ] || { echo "not enough memory for MemoryMax ${max} MiB" >&2; exit 1; }
curl -fsS --max-time 5 --unix-socket /run/anytls-dedup/admin.sock http://dedup/stats >/dev/null ||
  { echo "decoder admin socket does not answer" >&2; exit 1; }
echo "   anytls-server pid $(systemctl show anytls-server -p MainPID --value), decoder healthy"
EOF
fi

step "plan"
if [ -n "$server" ]; then
  say "server: cache ${cache_mib} MiB, inflight ${inflight_mib} MiB, Go limit ${memory_mib} MiB, MemoryMax ${memory_max_mib} MiB; restart anytls-dedup only"
  say "caches start cold once: each conversation's next request is sent in full"
else
  say "server: untouched; the decoder keeps its cache"
  say "the new front's index starts empty: each conversation's next request is sent in full"
fi
say "router: replace${changed:- nothing}; index_mib=${index_mib}; start the new front beside the old (3s linger, up to 30s drain)"

if [ "$apply" != 1 ]; then
  on_router "rm -rf $stage"
  printf '\nDry run complete; nothing was changed. Run again with --apply.\n'
  exit 0
fi

ts=$(date -u +%Y%m%d-%H%M%S)

# ---- server: resize and restart the decoder ---------------------------------
if [ -n "$server" ]; then
step "server: resize decoder"
on_server bash -s -- "$ts" "$cache_mib" "$inflight_mib" "$memory_mib" "$memory_max_mib" <<'EOF' || die "server resize failed (restored)"
set -eu
ts=$1 cache=$2 inflight=$3 memory=$4 max=$5
backup=/root/anytls-dedup-resize-$ts
mkdir -p "$backup"
cp -p /etc/anytls/dedup.env /etc/systemd/system/anytls-dedup.service "$backup/"
server_pid=$(systemctl show anytls-server -p MainPID --value)
old_epoch=$(curl -fsS --unix-socket /run/anytls-dedup/admin.sock http://dedup/stats | grep -o '"epoch":"[0-9a-f]*"')
restore() {
  echo "   restoring from $backup" >&2
  cp -p "$backup/dedup.env" /etc/anytls/dedup.env
  cp -p "$backup/anytls-dedup.service" /etc/systemd/system/anytls-dedup.service
  systemctl daemon-reload
  systemctl restart anytls-dedup
}
trap 'restore' ERR
sed -i -e "s/^ANYTLS_DEDUP_CACHE_MIB=.*/ANYTLS_DEDUP_CACHE_MIB=$cache/" \
  -e "s/^ANYTLS_DEDUP_INFLIGHT_MIB=.*/ANYTLS_DEDUP_INFLIGHT_MIB=$inflight/" \
  -e "s/^ANYTLS_DEDUP_MEMORY_MIB=.*/ANYTLS_DEDUP_MEMORY_MIB=$memory/" \
  -e "s/^ANYTLS_DEDUP_MEMORY_MAX_MIB=.*/ANYTLS_DEDUP_MEMORY_MAX_MIB=$max/" /etc/anytls/dedup.env
sed -i "s/^MemoryMax=.*/MemoryMax=${max}M/" /etc/systemd/system/anytls-dedup.service
systemctl daemon-reload
[ "$(systemctl show anytls-dedup -p MemoryMax --value)" = "$((max * 1024 * 1024))" ]
systemctl restart anytls-dedup
stats=""
for _ in $(seq 30); do
  stats=$(curl -fsS --max-time 2 --unix-socket /run/anytls-dedup/admin.sock http://dedup/stats 2>/dev/null) && break
  sleep 1
done
new_epoch=$(printf '%s' "$stats" | grep -o '"epoch":"[0-9a-f]*"')
[ -n "$new_epoch" ] && [ "$new_epoch" != "$old_epoch" ]
ps -o args= -p "$(systemctl show anytls-dedup -p MainPID --value)" | grep -q -- "-cache-mib $cache "
[ "$(systemctl show anytls-server -p MainPID --value)" = "$server_pid" ]
trap - ERR
echo "   decoder restarted, $new_epoch, MemoryMax ${max} MiB; anytls-server pid $server_pid unchanged"
echo "   backup: $backup"
EOF
fi

# ---- router: swap the front ---------------------------------------------------
step "router: upgrade front"
on_router sh -s -- "$ts" "$index_mib" "$stage" <<'EOF' || die "router upgrade failed (restored)"
set -e
ts=$1 index=$2 stage=$3
backup=/root/stargate-dedup-upgrade-$ts
mkdir -p "$backup"
(cd / && tar czf "$backup/backup.tar.gz" usr/bin/stargate-dedup usr/share/stargate/dedup.sh \
  usr/share/stargate/lib/config.sh etc/init.d/stargate-dedup etc/config/stargate)
singbox_pid=$(pgrep -f '^/usr/bin/sing-box' | head -1)
restore() {
  echo "   restoring from $backup" >&2
  (cd / && tar xzf "$backup/backup.tar.gz")
  /etc/init.d/stargate-dedup start
  exit 1
}
install_file() { cp "$1" "$2.new" && chmod "$3" "$2.new" && mv -f "$2.new" "$2"; }
install_file "$stage/stargate-dedup" /usr/bin/stargate-dedup 755 || restore
install_file "$stage/dedup.sh" /usr/share/stargate/dedup.sh 755 || restore
install_file "$stage/lib/config.sh" /usr/share/stargate/lib/config.sh 644 || restore
install_file "$stage/stargate-dedup.init" /etc/init.d/stargate-dedup 755 || restore
uci set stargate.dedup.index_mib="$index" && uci commit stargate || restore
/usr/share/stargate/stargate.sh generate >/dev/null 2>&1 || restore
cmp -s /etc/stargate/config.json.next /etc/stargate/config.json || { echo "sing-box config would change" >&2; restore; }
rm -f /etc/stargate/config.json.next
/usr/share/stargate/dedup.sh front | grep -q -- "-index-mib $index " || { echo "front arguments lack the new index" >&2; restore; }
/etc/init.d/stargate-dedup start || restore
# The old front lingers 3s and drains for up to 30s.
for _ in $(seq 45); do
  [ "$(pgrep -f '^/usr/bin/stargate-dedup front' | wc -l)" = 1 ] &&
    pgrep -f "^/usr/bin/stargate-dedup front .*-index-mib $index " >/dev/null && break
  sleep 1
done
pgrep -f "^/usr/bin/stargate-dedup front .*-index-mib $index " >/dev/null || { echo "new front is not running" >&2; restore; }
[ "$(pgrep -f '^/usr/bin/stargate-dedup front' | wc -l)" = 1 ] || echo "   note: old front still draining" >&2
[ "$(pgrep -f '^/usr/bin/sing-box' | head -1)" = "$singbox_pid" ] || echo "   WARNING: sing-box pid changed" >&2
rm -rf "$stage"
echo "   front replaced; sing-box pid $singbox_pid unchanged"
echo "   backup: $backup"
EOF

# ---- verify --------------------------------------------------------------------
step "verify"
if [ -n "$server" ]; then
  epoch=$(on_server "curl -fsS --unix-socket /run/anytls-dedup/admin.sock http://dedup/stats" | grep -o '"epoch":"[0-9a-f]*"' | cut -d'"' -f4)
else
  epoch=$old_epoch
fi
for _ in $(seq 30); do
  on_router "/usr/share/stargate/dedup.sh status" | grep -q "\"main\": {[^}]*\"epoch\": \"$epoch\"" && break
  sleep 2
done
# A lane exists once traffic has used it, so a quiet minute is not a failure.
if on_router "/usr/share/stargate/dedup.sh status" | grep -q "\"main\": {[^}]*\"epoch\": \"$epoch\""; then
  say "front lane main answers to decoder $epoch"
else
  say "WARNING: no traffic has reached the new front's main lane within a minute; check dedup.sh status later"
fi
on_router "/usr/share/stargate/dedup.sh status | sed -n '1,6p'" | sed 's/^/   /'
printf '\nUpgrade complete.\n'
