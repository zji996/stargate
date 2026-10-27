#!/bin/sh
# Keeps the Stargate dedup CA from the router in a device's system trust store.
# Installed on a dedup device (Sub2API host 8.12) as
# /usr/local/sbin/stargate-dedup-ca-sync and run hourly by a systemd timer.
#
# The router key only allows "cat /etc/stargate/dedup/ca.pem". Leaf
# certificates renew on the router by themselves; this follows CA changes.
# The CA's permitted names must be exactly those in $dir/domains (one line,
# space separated, in the order of the router's UCI stargate.dedup.domains).
#
# Widening the names rotates the CA. To restart the clients only once, the
# rotation pre-installs the new CA as $dest and keeps the old one as $prev
# until the router serves the new one; this script then drops $prev.
set -eu

dir=${STARGATE_DEDUP_CA_DIR:-/etc/stargate-dedup-ca}
certs=${STARGATE_DEDUP_CERT_DIR:-/usr/local/share/ca-certificates}
dest=$certs/stargate-dedup.crt
prev=$certs/stargate-dedup-prev.crt
services="sub2api.service"
# $dir/router holds the router's ssh destination, e.g. root@<router address>.
router=$(cat "$dir/router")
domains="chatgpt.com api.openai.com"
[ -f "$dir/domains" ] && domains=$(cat "$dir/domains")
expected_constraints=$(printf '%s\n' $domains | sed 's/^/DNS:/' | tr '\n' ' ' | sed 's/ $//')

log() { logger -t stargate-dedup-ca -- "$*"; echo "$*"; }

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

ssh -i "$dir/id_ed25519" -o IdentitiesOnly=yes -o BatchMode=yes \
  -o UserKnownHostsFile="$dir/known_hosts" -o StrictHostKeyChecking=yes \
  -o ConnectTimeout=10 "$router" ca >"$tmp" || {
  log "router unreachable or no CA yet; keeping the installed one"
  exit 0
}

# Exactly one certificate, a CA limited to the dedup domains.
[ "$(grep -c 'BEGIN CERTIFICATE' "$tmp")" = 1 ] || { log "rejected: not exactly one certificate"; exit 1; }
text=$(openssl x509 -in "$tmp" -noout -ext basicConstraints,nameConstraints) || { log "rejected: unreadable certificate"; exit 1; }
printf '%s\n' "$text" | grep -q 'CA:TRUE' || { log "rejected: not a CA"; exit 1; }
printf '%s\n' "$text" | grep -A1 'Name Constraints' | grep -q critical || { log "rejected: name constraints not critical"; exit 1; }
got=$(printf '%s\n' "$text" | sed -n '/Permitted:/,$p' | grep -o 'DNS:[^ ,]*' | tr '\n' ' ' | sed 's/ $//')
if [ "$got" != "$expected_constraints" ]; then
  # Mid-rotation the router still serves the old CA, which both stores trust.
  if [ -f "$prev" ] && cmp -s "$tmp" "$prev"; then
    exit 0
  fi
  log "rejected: unexpected permitted names: $got"
  exit 1
fi
printf '%s\n' "$text" | grep -q 'Excluded' && { log "rejected: unexpected excluded names"; exit 1; }
openssl x509 -in "$tmp" -noout -checkend 0 >/dev/null || { log "rejected: expired"; exit 1; }

if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
  if [ -f "$prev" ]; then
    # The router serves the new CA: the old one is no longer needed. Running
    # clients keep it until their next restart, which is harmless.
    rm -f "$prev"
    update-ca-certificates --fresh >/dev/null
    log "router serves the new CA; dropped the previous one"
  fi
  exit 0
fi

install -m 0644 "$tmp" "$dest"
rm -f "$prev"
update-ca-certificates --fresh >/dev/null
log "installed CA $(openssl x509 -in "$dest" -noout -fingerprint -sha256 | cut -d= -f2)"
# Go and Rust clients read the trust store once at start.
for unit in $services; do
  systemctl try-restart "$unit" && log "restarted $unit"
done
