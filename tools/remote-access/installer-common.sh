#!/bin/sh

# Shared only by this component's installers and their bundled rollback scripts.
sg_begin() {
  sg_kind=$1
  sg_lock=/var/lock/stargate-remote-install
  sg_owns_lock=0
  sg_config_locked=0
  sg_rollback_ready=0
  umask 077
  [ "$(id -u)" = 0 ] || { echo 'root is required' >&2; exit 1; }
  if [ "${STARGATE_REMOTE_LOCK_HELD:-0}" != 1 ]; then
    mkdir -p /var/lock
    mkdir "$sg_lock" 2>/dev/null || {
      echo "Another remote-access installation or rollback owns $sg_lock" >&2
      exit 1
    }
    sg_owns_lock=1
  fi
  trap sg_finish EXIT
  trap 'exit 1' HUP INT TERM
}

sg_finish() {
  sg_result=$?
  trap - EXIT HUP INT TERM
  sg_release_config_lock || true
  if [ "$sg_result" -ne 0 ] && [ "$sg_rollback_ready" = 1 ]; then
    if ! STARGATE_REMOTE_LOCK_HELD=1 sh "$backup/rollback.sh" "$backup"; then
      echo "Automatic rollback failed; keep backup $backup for recovery." >&2
    fi
  fi
  [ "$sg_owns_lock" = 0 ] || rmdir "$sg_lock"
  exit "$sg_result"
}

sg_allowed_paths() {
  case "$sg_kind" in
    server) printf '%s\n' etc/stargate-remote usr/local/lib/stargate-remote etc/systemd/system/stargate-remote-controller.service etc/systemd/system/stargate-remote-frps.service ;;
    router) printf '%s\n' etc/stargate-remote usr/bin/stargate-remote usr/bin/frpc etc/init.d/stargate-remote ;;
    luci) printf '%s\n' usr/lib/lua/luci/controller/stargate.lua usr/lib/lua/luci/model/cbi/stargate/client/remote.lua usr/lib/lua/luci/view/stargate/remote.htm usr/share/luci/menu.d/luci-app-stargate.json usr/lib/lua/luci/i18n/stargate.zh-cn.lmo usr/share/stargate/remote-control.sh usr/share/stargate/stargate.sh usr/share/stargate/lib/maintenance.sh ;;
    *) return 1 ;;
  esac
}

sg_backup_files() {
  prefix=stargate-remote-backup
  [ "$sg_kind" != luci ] || prefix=stargate-remote-ui-backup
  backup=$(mktemp -d "/root/$prefix-$(date -u +%Y%m%d-%H%M%S)-XXXXXX")
  printf 'stargate-remote-backup-v1:%s\n' "$sg_kind" >"$backup/component"
  : >"$backup/paths"
  sg_allowed_paths >"$backup/allowed"
  while IFS= read -r path; do
    [ ! -L "/$path" ] || { echo "Refusing managed symlink: /$path" >&2; return 1; }
    [ ! -e "/$path" ] || printf '%s\n' "$path" >>"$backup/paths"
  done <"$backup/allowed"
  tar -C / --exclude=etc/stargate-remote/.update-lock -czf "$backup/files.tar.gz" -T "$backup/paths"
  cp "$base/rollback-$sg_kind.sh" "$backup/rollback.sh"
  cp "$base/installer-common.sh" "$backup/installer-common.sh"
  chmod 700 "$backup/rollback.sh"
}

sg_metadata_hashes() {
  case "$sg_kind" in
    server) sha256sum files.tar.gz paths component controller.active controller.enabled frps.active frps.enabled ;;
    router) sha256sum files.tar.gz paths component running enabled ;;
    luci) sha256sum files.tar.gz paths component ;;
  esac
}

sg_seal_backup() {
  (cd "$backup" && sg_metadata_hashes >checksums)
  echo complete >"$backup/complete"
  sg_validate_backup
}

sg_validate_backup() {
  [ "$(dirname -- "$backup")" = /root ] && [ ! -L "$backup" ] || return 1
  case "$(basename -- "$backup")" in
    *[!a-zA-Z0-9-]*) return 1 ;;
    stargate-remote-backup-*|stargate-remote-ui-backup-*) ;;
    *) return 1 ;;
  esac
  metadata=''
  case "$sg_kind" in
    server) metadata='controller.active controller.enabled frps.active frps.enabled' ;;
    router) metadata='running enabled' ;;
  esac
  for file in component complete paths checksums files.tar.gz $metadata; do
    [ -f "$backup/$file" ] && [ ! -L "$backup/$file" ] || {
      echo 'Incomplete backup; refusing to change the installed component.' >&2
      return 1
    }
  done
  [ "$(cat "$backup/component")" = "stargate-remote-backup-v1:$sg_kind" ] &&
    [ "$(cat "$backup/complete")" = complete ] || {
      echo 'Backup component or completion marker mismatch.' >&2
      return 1
    }
  (cd "$backup" && sg_metadata_hashes) | cmp -s - "$backup/checksums" || {
    echo 'Backup checksum validation failed.' >&2
    return 1
  }
  case "$sg_kind" in
    server)
      for service in controller frps; do
        case "$(cat "$backup/$service.enabled")" in enabled|enabled-runtime|disabled|'') ;; *) return 1 ;; esac
        case "$(cat "$backup/$service.active")" in active|inactive|failed|'') ;; *) return 1 ;; esac
      done ;;
    router)
      for state in enabled running; do
        case "$(cat "$backup/$state")" in 0|1) ;; *) return 1 ;; esac
      done ;;
  esac
  allowed=$(sg_allowed_paths)
  awk -v allowed="$allowed" 'BEGIN {split(allowed, a, "\n"); for (i in a) valid[a[i]]=1} !valid[$0] || seen[$0]++ {exit 1}' "$backup/paths" || return 1
  tar -tzf "$backup/files.tar.gz" >/dev/null || return 1
  # Only regular files and directories under the recorded component paths may restore.
  tar -tvzf "$backup/files.tar.gz" | awk 'substr($1,1,1) != "-" && substr($1,1,1) != "d" {exit 1}' || return 1
  members=$(tar -tzf "$backup/files.tar.gz")
  printf '%s\n' "$members" | awk '
    FILENAME!="-" {if ($0!="") roots[$0]=1; next}
    $0=="" {next}
    {name=$0; sub(/\/$/, "", name); if (name ~ /^\// || name ~ /(^|\/)\.\.(\/|$)/) exit 1;
      ok=0; for (root in roots) {if (name==root) found[root]=1; if (name==root || index(name, root "/")==1) ok=1}; if (!ok) exit 1}
    END {for (root in roots) if (!found[root]) exit 1}
  ' "$backup/paths" - || return 1
}

sg_transaction_ready() {
  sg_rollback_ready=1
}

sg_acquire_config_lock() {
  attempt=0
  while [ "$attempt" -lt 30 ]; do
    if mkdir /etc/stargate-remote/.update-lock 2>/dev/null; then
      sg_config_locked=1
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  echo 'A configuration update is still active; retry installation after it finishes.' >&2
  return 1
}

sg_release_config_lock() {
  if [ "$sg_config_locked" = 1 ]; then
    rmdir /etc/stargate-remote/.update-lock
    sg_config_locked=0
  fi
}

sg_commit() {
  sg_rollback_ready=0
}

sg_restore_server_state() {
  for service in controller frps; do
    unit="stargate-remote-$service"
    case "$(cat "$backup/$service.enabled")" in
      enabled) systemctl enable "$unit" ;;
      enabled-runtime) systemctl enable --runtime "$unit" ;;
      disabled|'') systemctl disable "$unit" ;;
      *) echo 'Unsupported saved systemd enable state.' >&2; return 1 ;;
    esac
  done
  for service in frps controller; do
    [ "$(cat "$backup/$service.active")" = active ] || systemctl stop "stargate-remote-$service"
  done
  for service in controller frps; do
    [ "$(cat "$backup/$service.active")" != active ] || systemctl start "stargate-remote-$service"
  done
}
