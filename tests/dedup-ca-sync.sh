#!/bin/sh
# Run tools/dedup/ca-sync.sh against real name-constrained CAs, with the router,
# trust store update and service manager replaced by recorders.
set -eu
repo_dir="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
command -v openssl >/dev/null 2>&1 || { echo "skip dedup-ca-sync: openssl not found" >&2; exit 0; }
lab="$(mktemp -d)"
trap 'rm -rf "$lab"' EXIT
mkdir -p "$lab/bin" "$lab/ca" "$lab/certs"
echo root@router.test > "$lab/ca/router"
cat > "$lab/bin/ssh" <<STUB
#!/bin/sh
cat "$lab/served.pem"
STUB
cat > "$lab/bin/update-ca-certificates" <<STUB
#!/bin/sh
echo update >> "$lab/calls"
STUB
cat > "$lab/bin/systemctl" <<STUB
#!/bin/sh
echo "systemctl \$*" >> "$lab/calls"
STUB
printf '#!/bin/sh\n' > "$lab/bin/logger"
chmod +x "$lab/bin/"*

# make_ca NAME DNS...: a CA permitted to exactly those names.
make_ca() {
  name=$1; shift
  permitted=$(printf 'permitted;DNS:%s,' "$@" | sed 's/,$//')
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 \
    -keyout "$lab/$name.key" -out "$lab/$name.pem" -subj "/CN=$name" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "nameConstraints=critical,$permitted" 2>/dev/null
}
make_ca old chatgpt.com api.openai.com
make_ca new chatgpt.com api.openai.com api.commandcode.ai
make_ca odd example.com

sync() {
  : > "$lab/calls"
  PATH="$lab/bin:$PATH" STARGATE_DEDUP_CA_DIR="$lab/ca" STARGATE_DEDUP_CERT_DIR="$lab/certs" \
    sh "$repo_dir/tools/dedup/ca-sync.sh" >/dev/null
}
fail() { echo "dedup-ca-sync: $*" >&2; exit 1; }
restarted() { grep -q 'try-restart sub2api.service' "$lab/calls"; }

# Without a domains file the names are the original pair.
cp "$lab/old.pem" "$lab/served.pem"
sync || fail "first install failed"
cmp -s "$lab/old.pem" "$lab/certs/stargate-dedup.crt" && restarted || fail "first install did not install and restart"
sync || fail "unchanged CA failed"
[ ! -s "$lab/calls" ] || fail "unchanged CA touched the store: $(cat "$lab/calls")"

# Rotation: the new CA is pre-installed, the old one kept as prev.
echo "chatgpt.com api.openai.com api.commandcode.ai" > "$lab/ca/domains"
cp "$lab/new.pem" "$lab/certs/stargate-dedup.crt"
cp "$lab/old.pem" "$lab/certs/stargate-dedup-prev.crt"
sync || fail "mid-rotation old CA was rejected"
[ ! -s "$lab/calls" ] && [ -f "$lab/certs/stargate-dedup-prev.crt" ] || fail "mid-rotation changed the store"
cp "$lab/new.pem" "$lab/served.pem"
sync || fail "rotated CA failed"
[ ! -f "$lab/certs/stargate-dedup-prev.crt" ] || fail "prev kept after the router switched"
grep -q update "$lab/calls" && ! restarted || fail "dropping prev should update the store without a restart"

# Anything else is refused and the installed CA stays.
cp "$lab/odd.pem" "$lab/served.pem"
if sync; then fail "a CA for other names was accepted"; fi
cmp -s "$lab/new.pem" "$lab/certs/stargate-dedup.crt" || fail "a refused CA replaced the installed one"
cp "$lab/old.pem" "$lab/served.pem"
if sync; then fail "the old CA was accepted after prev was dropped"; fi
echo "dedup-ca-sync: ok"
