#!/bin/sh
set -eu

base=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
command -v bwrap >/dev/null || { echo 'bwrap is required for isolated installer checks.' >&2; exit 1; }
command -v lua >/dev/null
command -v jq >/dev/null
temporary=$(mktemp -d)
cleanup() {
  if [ "${STARGATE_TEST_KEEP_TMP:-0}" = 1 ]; then
    printf 'Isolated fixture files retained at %s\n' "$temporary"
  else
    rm -rf "$temporary"
  fi
}
trap cleanup EXIT HUP INT TERM
count=0
failed=0

fail() { echo "$*" >&2; return 1; }
fixture() {
  root="$temporary/$1"
  mkdir -p "$root/host/usr" "$root/lib" "$root/lib64" "$root/source" "$root/proc" "$root/dev" \
    "$root/mock" "$root/tmp" "$root/root" "$root/fail" "$root/test-state" "$root/package/services" \
    "$root/bundle" "$root/usr/bin" "$root/usr/local/lib" "$root/etc/init.d" "$root/etc/systemd/system" \
    "$root/etc/rc.d" "$root/var/lock" \
    "$root/usr/lib/lua/luci/controller" "$root/usr/lib/lua/luci/model/cbi/stargate/client" \
    "$root/usr/lib/lua/luci/view/stargate" "$root/usr/lib/lua/luci/i18n" "$root/usr/share/luci/menu.d"
  ln -s /host/usr/bin "$root/bin"
  cp "$base"/install-*.sh "$base"/rollback-*.sh "$base/installer-common.sh" "$root/package/"
  cp "$base"/services/* "$root/package/services/"
  cp "$base/tests/mock-rc.common" "$root/etc/rc.common"
  for name in systemctl getent useradd userdel groupadd chown sleep cp install ubus jsonfilter curl; do
    ln -s /source/tests/mock-command.sh "$root/mock/$name"
  done
  ln -s /source/tests/mock-lua.sh "$root/mock/lua"
  ln -s /host/usr/bin/mawk "$root/mock/awk"
  for name in stargate-remote frpc frps; do
    cp "$base/tests/mock-command.sh" "$root/bundle/$name"
    chmod 755 "$root/bundle/$name"
  done
  cp "$base/tests/mock-command.sh" "$root/usr/bin/sing-box"
  chmod 755 "$root/usr/bin/sing-box"
  printf '{"server":"fixture.invalid","port":443,"password":"fixture-only"}\n' >"$root/node.json"
  printf 'fixture-only-enrollment\n' >"$root/enrollment.link"
  chmod 600 "$root/node.json" "$root/enrollment.link"
  printf 'local old = true\n' >"$root/usr/lib/lua/luci/controller/stargate.lua"
  printf '{}\n' >"$root/usr/share/luci/menu.d/luci-app-stargate.json"
  printf 'old translation\n' >"$root/usr/lib/lua/luci/i18n/stargate.zh-cn.lmo"
  cp "$base/../../luci-app-stargate/luasrc/controller/stargate.lua" "$root/bundle/controller.lua"
  cp "$base/../../luci-app-stargate/luasrc/model/cbi/stargate/client/remote.lua" "$root/bundle/remote.lua"
  cp "$base/../../luci-app-stargate/luasrc/view/stargate/remote.htm" "$root/bundle/remote.htm"
  cp "$base/../../luci-app-stargate/root/usr/share/stargate/remote-control.sh" "$root/bundle/remote-control.sh"
  cp "$base/../../luci-app-stargate/root/usr/share/stargate/stargate.sh" "$root/bundle/stargate.sh"
  cp "$base/../../luci-app-stargate/root/usr/share/stargate/lib/maintenance.sh" "$root/bundle/maintenance.sh"
  cp "$base/../../luci-app-stargate/root/usr/share/luci/menu.d/luci-app-stargate.json" "$root/bundle/menu.json"
  printf 'fixture translation\n' >"$root/bundle/stargate.zh-cn.lmo"
  : >"$root/test-state/actions"
}

sandbox() {
  bwrap --unshare-all --uid 0 --gid 0 --die-with-parent \
    --bind "$root" / --ro-bind /usr /host/usr --ro-bind /lib /lib --ro-bind /lib64 /lib64 \
    --ro-bind "$base" /source --proc /proc --dev /dev \
    --setenv PATH /mock:/host/usr/bin:/usr/bin --setenv HOME /root --setenv TMPDIR /tmp \
    --chdir / /bin/sh "$@" >"$root/output" 2>&1
}

install_component() {
  case "$1" in
    server) sandbox /package/install-server.sh /bundle /node.json ;;
    router) sandbox /package/install-router.sh /bundle /enrollment.link ;;
    luci) sandbox /package/install-luci.sh /bundle ;;
  esac
}

backup_dir() {
  selected=$(find "$root/root" -mindepth 1 -maxdepth 1 -type d -name 'stargate-remote*backup-*' \
    -printf '%T@ %p\n' | sort -nr | sed -n '1s/^[^ ]* //p')
  [ -n "$selected" ] || fail 'installer did not create a backup'
  backup=${selected#"$root"}
}

reject_install() {
  if install_component "$1"; then fail "$1 installation unexpectedly succeeded"; fi
}

reject_restore() {
  if sandbox "/package/rollback-$1.sh" "$2"; then fail "$1 rollback unexpectedly succeeded"; fi
}

assert_enabled() {
  case "$1" in
    server) [ -f "$root/test-state/stargate-remote-controller.enabled" ] && [ -f "$root/test-state/stargate-remote-frps.enabled" ] ;;
    router) [ -L "$root/etc/rc.d/S96stargate-remote" ] ;;
  esac
}

assert_running() {
  case "$1" in
    server) [ -f "$root/test-state/stargate-remote-controller.active" ] && [ -f "$root/test-state/stargate-remote-frps.active" ] ;;
    router) [ -f "$root/test-state/router.transport" ] && [ -f "$root/test-state/router.frpc" ] && [ -f "$root/test-state/router.sync" ] ;;
  esac
}

disable_component() {
  case "$1" in
    server) sandbox -c 'systemctl disable --now stargate-remote-frps stargate-remote-controller' ;;
    router) sandbox -c '/etc/init.d/stargate-remote stop; /etc/init.d/stargate-remote disable' ;;
  esac
}

snapshot() {
  (cd "$root" && find etc usr test-state -type f ! -name actions ! -name commands -exec sha256sum '{}' \; | sort) >"$root/snapshot"
}

unchanged() {
  (cd "$root" && find etc usr test-state -type f ! -name actions ! -name commands -exec sha256sum '{}' \; | sort) >"$root/after"
  cmp "$root/snapshot" "$root/after" || fail 'live installation changed after a rejected operation'
}

test_fresh() {
  fixture "fresh-$1"
  install_component "$1" || { cat "$root/output"; return 1; }
  backup_dir
  for file in component paths files.tar.gz checksums complete rollback.sh installer-common.sh; do
    [ -f "$root$backup/$file" ] || fail "missing backup $file"
  done
  case "$1" in
    server|router) assert_enabled "$1"; assert_running "$1" ;;
  esac
  sandbox "$backup/rollback.sh" "$backup" || { cat "$root/output"; return 1; }
  case "$1" in
    server) [ ! -e "$root/etc/stargate-remote/server.json" ] ;;
    router) [ ! -e "$root/usr/bin/stargate-remote" ]; [ ! -e "$root/etc/rc.d/S96stargate-remote" ] ;;
    luci) [ ! -e "$root/usr/lib/lua/luci/model/cbi/stargate/client/remote.lua" ]; rg -q 'local old' "$root/usr/lib/lua/luci/controller/stargate.lua" ;;
  esac
}

test_upgrade() {
  fixture "upgrade-$1-$2"
  install_component "$1" || { cat "$root/output"; return 1; }
  if [ "$1" = server ]; then
    identity_checksum=$(sha256sum "$root/etc/stargate-remote/server.json")
  fi
  case "$2" in
    disabled) disable_component "$1" ;;
    enabled-stopped)
      case "$1" in
        server) sandbox -c 'systemctl stop stargate-remote-frps stargate-remote-controller' ;;
        router) sandbox -c '/etc/init.d/stargate-remote stop' ;;
      esac
      ;;
    disabled-running)
      case "$1" in
        server) sandbox -c 'systemctl disable stargate-remote-frps stargate-remote-controller' ;;
        router) sandbox -c '/etc/init.d/stargate-remote disable' ;;
      esac
      ;;
  esac
  # Distinct names also check repeated installation within the same second.
  : >"$root/test-state/actions"
  install_component "$1" || { cat "$root/output"; return 1; }
  case "$2" in
    running|enabled-stopped) assert_enabled "$1" ;;
    *) if assert_enabled "$1"; then fail 'upgrade enabled a disabled installation'; fi ;;
  esac
  case "$2" in
    running|disabled-running) assert_running "$1" ;;
    *)
      if assert_running "$1"; then fail 'upgrade started a stopped installation'; fi
      if rg -q 'systemctl start|router start' "$root/test-state/actions"; then
        fail 'upgrade temporarily started a stopped installation'
      fi
      ;;
  esac
  if [ "$1" = router ]; then
    [ "$(rg -c '^agent prepare ' "$root/test-state/commands")" = 2 ] || fail 'router upgrade did not regenerate its configuration'
    backup_dir
    if tar -tzf "$root$backup/files.tar.gz" | rg -q '/\.update-lock(/|$)'; then
      fail 'router snapshot archived a temporary configuration lock'
    fi
  else
    [ "$(rg -c '^agent prepare-server ' "$root/test-state/commands")" = 2 ] || fail 'server upgrade did not regenerate frps configuration'
    [ "$identity_checksum" = "$(sha256sum "$root/etc/stargate-remote/server.json")" ] || fail 'server upgrade changed device identities'
    [ "$(rg -c '^agent server-init ' "$root/test-state/commands")" = 1 ] || fail 'server upgrade initialized identities a second time'
  fi
}

test_reject_backup() {
  fixture "backup-$1-$2"
  install_component "$1" || { cat "$root/output"; return 1; }
  if [ "$2" = missing-member ]; then
    install_component "$1" || { cat "$root/output"; return 1; }
  fi
  backup_dir
  case "$2" in
    empty) backup=/root/stargate-remote-backup-empty; mkdir "$root$backup" ;;
    missing) rm "$root$backup/files.tar.gz" ;;
    damaged) printf 'damaged archive\n' >"$root$backup/files.tar.gz" ;;
    incomplete) rm "$root$backup/complete" ;;
    unknown) printf 'stargate-remote-backup-v1:unknown\n' >"$root$backup/component" ;;
    paths)
      printf 'etc/unrelated\n' >>"$root$backup/paths"
      sandbox -c ". /package/installer-common.sh; sg_kind=$1; backup=$backup; cd \"\$backup\"; sg_metadata_hashes >checksums"
      ;;
    member)
      printf 'unrelated fixture\n' >"$root/etc/unrelated"
      sandbox -c "tar -C / -czf $backup/files.tar.gz etc/unrelated; . /package/installer-common.sh; sg_kind=$1; backup=$backup; cd \"\$backup\"; sg_metadata_hashes >checksums"
      ;;
    missing-member)
      [ -s "$root$backup/paths" ] || fail 'missing-member fixture did not record installed objects'
      sandbox -c "tar -C / -czf $backup/files.tar.gz -T /dev/null; . /package/installer-common.sh; sg_kind=$1; backup=$backup; cd \"\$backup\"; sg_metadata_hashes >checksums"
      ;;
    saved-enabled|saved-active)
      case "$1:$2" in
        server:saved-enabled) saved_file=controller.enabled ;;
        server:saved-active) saved_file=controller.active ;;
        router:saved-enabled) saved_file=enabled ;;
        router:saved-active) saved_file=running ;;
      esac
      printf 'invalid-saved-state\n' >"$root$backup/$saved_file"
      sandbox -c ". /package/installer-common.sh; sg_kind=$1; backup=$backup; cd \"\$backup\"; sg_metadata_hashes >checksums"
      ;;
    cross)
      other=luci; [ "$1" != luci ] || other=server
      printf 'stargate-remote-backup-v1:%s\n' "$other" >"$root$backup/component"
      ;;
  esac
  snapshot
  cp "$root/test-state/actions" "$root/actions-before" 2>/dev/null || : >"$root/actions-before"
  reject_restore "$1" "$backup"
  unchanged
  cmp "$root/actions-before" "$root/test-state/actions" || fail 'rejected backup stopped or changed a service'
}

test_bad_package() {
  fixture "package-$1-$2"
  install_component "$1" || { cat "$root/output"; return 1; }
  snapshot
  case "$2" in
    verify) touch "$root/fail/verify" ;;
    init) printf '#!/bin/sh /etc/rc.common\nif then\n' >"$root/package/services/stargate-remote.init" ;;
    template) printf '<%% local = %%>\n' >"$root/bundle/remote.htm" ;;
    menu) printf '{}\n' >"$root/bundle/menu.json" ;;
    missing) rm "$root/bundle/remote.lua" ;;
  esac
  reject_install "$1"
  unchanged
}

test_locked() {
  fixture "lock-$1"
  install_component "$1" || { cat "$root/output"; return 1; }
  snapshot
  mkdir -p "$root/var/lock/stargate-remote-install"
  reject_install "$1"
  unchanged
  backup_dir
  reject_restore "$1" "$backup"
  unchanged
}

test_router_offline() {
  fixture router-offline
  install_component router || { cat "$root/output"; return 1; }
  touch "$root/fail/offline"
  install_component router || { cat "$root/output"; return 1; }
  assert_running router
}

test_router_incomplete() {
  fixture router-incomplete
  touch "$root/fail/router-frpc"
  reject_install router
  [ ! -e "$root/usr/bin/stargate-remote" ] || fail 'partial service startup retained a failed first installation'
}

test_router_busy_snapshot() {
  fixture router-busy-snapshot
  install_component router || { cat "$root/output"; return 1; }
  mkdir "$root/etc/stargate-remote/.update-lock"
  printf 'another updater\n' >"$root/etc/stargate-remote/.update-lock/owner.json"
  snapshot
  reject_install router
  unchanged
  [ -f "$root/etc/stargate-remote/.update-lock/owner.json" ] || fail 'installer removed another updater lock'
  [ ! -e "$root/var/lock/stargate-remote-install" ] || fail 'busy snapshot left the installation lock held'
}

test_copy_failure() {
  fixture "copy-$1"
  install_component "$1" || { cat "$root/output"; return 1; }
  snapshot
  case "$1" in
    server) destination=/etc/systemd/system/stargate-remote-frps.service ;;
    router) destination=/usr/bin/frpc.next ;;
    luci) destination=/usr/lib/lua/luci/model/cbi/stargate/client/remote.lua ;;
  esac
  printf '%s\n' "$destination" >"$root/fail/copy-target"
  reject_install "$1"
  unchanged
}

test_service_failure() {
  fixture "service-$1"
  install_component "$1" || { cat "$root/output"; return 1; }
  snapshot
  touch "$root/fail/$1-start"
  reject_install "$1"
  unchanged
  assert_running "$1"
}

test_server_health() {
  fixture server-health
  install_component server || { cat "$root/output"; return 1; }
  snapshot
  touch "$root/fail/health"
  reject_install server
  unchanged
  assert_running server
}

test_server_prepare_failure() {
  fixture server-prepare-failure
  install_component server || { cat "$root/output"; return 1; }
  snapshot
  touch "$root/fail/prepare-server"
  reject_install server
  unchanged
  assert_running server
}

test_first_failure() {
  fixture "first-failure-$1"
  case "$1" in
    server) touch "$root/fail/prepare-server" ;;
    router) touch "$root/fail/prepare" ;;
    luci) printf '/usr/lib/lua/luci/model/cbi/stargate/client/remote.lua\n' >"$root/fail/copy-target" ;;
  esac
  snapshot
  reject_install "$1"
  unchanged
}

test_restore_bad_init() {
  fixture restore-bad-init
  install_component router || { cat "$root/output"; return 1; }
  install_component router || { cat "$root/output"; return 1; }
  backup_dir
  printf '#!/bin/sh /etc/rc.common\nif then\n' >"$root/etc/init.d/stargate-remote"
  sandbox "$backup/rollback.sh" "$backup" || { cat "$root/output"; return 1; }
  sandbox -n /etc/init.d/stargate-remote
  assert_running router
  assert_enabled router
}

test_singbox_maintenance() {
  fixture "singbox-$1"
  install_component router || { cat "$root/output"; return 1; }
  cp "$base/../../luci-app-stargate/root/usr/share/stargate/lib/maintenance.sh" "$root/maintenance.sh"
  cp "$base/tests/mock-stargate.init" "$root/etc/init.d/stargate"
  chmod 755 "$root/etc/init.d/stargate"
  mkdir -p "$root/etc/stargate"
  printf '{}\n' >"$root/etc/stargate/config.json"
  touch "$root/test-state/main.running"
  cp "$base/tests/mock-command.sh" "$root/upload"
  printf '\n# new candidate\n' >>"$root/upload"
  checksum=$(sha256sum "$root/usr/bin/sing-box")
  : >"$root/test-state/actions"
  case "$1" in
    reject-remote) touch "$root/fail/remote-config" ;;
    restart-failure) touch "$root/fail/router-restart" ;;
  esac
  command='. /maintenance.sh; load_config() { singbox_bin=/usr/bin/sing-box; config_file=/etc/stargate/config.json; tmp_prefix=/tmp/stargate; }; singbox_upgrade /upload'
  if [ "$1" = success ] || [ "$1" = rollback ]; then
    sandbox -c "$command" || { cat "$root/output"; return 1; }
    cmp "$root/upload" "$root/usr/bin/sing-box" || fail 'upgrade did not publish the candidate'
    rg -q '^main restart$' "$root/test-state/actions" || fail 'main proxy was not restarted'
    rg -q '^router restart$' "$root/test-state/actions" || fail 'remote transport was not restarted'
    if [ "$1" = rollback ]; then
      sandbox -c '. /maintenance.sh; load_config() { singbox_bin=/usr/bin/sing-box; config_file=/etc/stargate/config.json; tmp_prefix=/tmp/stargate; }; singbox_rollback' || { cat "$root/output"; return 1; }
      [ "$checksum" = "$(sha256sum "$root/usr/bin/sing-box")" ] || fail 'rollback did not restore old sing-box'
    fi
  else
    if sandbox -c "$command"; then fail 'invalid upgrade unexpectedly succeeded'; fi
    [ "$checksum" = "$(sha256sum "$root/usr/bin/sing-box")" ] || fail 'failed upgrade changed system sing-box'
    if [ "$1" = reject-remote ]; then
      [ ! -s "$root/test-state/actions" ] || fail 'configuration rejection restarted a service'
    fi
  fi
  assert_running router
  [ -e "$root/test-state/main.running" ]
  [ ! -e "$root/var/lock/stargate-remote-install" ] || fail 'maintenance did not release deployment lock'
}

test_standby() {
  fixture standby
  sandbox /package/install-router.sh /bundle || { cat "$root/output"; return 1; }
  [ -f "$root/etc/stargate-remote/installed" ]
  [ ! -e "$root/etc/stargate-remote/profile.json" ]
  if assert_enabled router || assert_running router; then fail 'standby was activated'; fi
  sandbox /package/install-router.sh /bundle || { cat "$root/output"; return 1; }
  [ ! -e "$root/etc/stargate-remote/profile.json" ]
  install_component router || { cat "$root/output"; return 1; }
  [ -f "$root/etc/stargate-remote/profile.json" ]
  assert_running router
}

test_bridge() {
  fixture "bridge-$1"
  sandbox /package/install-router.sh /bundle || { cat "$root/output"; return 1; }
  mkdir -p "$root/usr/share/stargate"
  cp "$root/bundle/remote-control.sh" "$root/usr/share/stargate/remote-control.sh"
  printf '#!/bin/sh\n[ "$1" = node-add-link-file ] || exit 1\n[ -s "$2" ] || exit 1\n[ ! -e /fail/node-import ] || exit 1\ntouch /test-state/node-imported\n' >"$root/usr/share/stargate/stargate.sh"
  chmod 755 "$root/usr/share/stargate/stargate.sh"
  printf 'unchanged-primary\n' >"$root/test-state/primary"
  case "$1" in import-failure) touch "$root/fail/node-import" ;; sync-failure) touch "$root/fail/offline" ;; esac
  activate=0
  [ "$1" != sync-failure ] || activate=1
  if sandbox /usr/share/stargate/remote-control.sh enroll --link-file /enrollment.link --activate "$activate" --import-proxy 1; then
    case "$1" in import-failure|sync-failure) fail 'expected bridge failure' ;; esac
  else
    case "$1" in import-failure|sync-failure) ;; *) cat "$root/output"; fail 'bridge enrollment failed' ;; esac
  fi
  [ -f "$root/etc/stargate-remote/profile.json" ] || fail 'issued identity was discarded'
  [ "$(cat "$root/test-state/primary")" = unchanged-primary ]
  [ ! -e "$root/var/lock/stargate-remote-install" ]
  [ -z "$(find "$root/tmp" -name 'stargate-remote-import.*' -print)" ] || fail 'private import file leaked'
  identity=$(sha256sum "$root/etc/stargate-remote/profile.json")
  if sandbox /usr/share/stargate/remote-control.sh enroll --link-file /enrollment.link; then fail 'existing identity was replaced'; fi
  [ "$identity" = "$(sha256sum "$root/etc/stargate-remote/profile.json")" ]
  rm -f "$root/fail/offline"
  sandbox /usr/share/stargate/remote-control.sh start || { cat "$root/output"; return 1; }
  assert_enabled router
  assert_running router
  mkdir "$root/etc/stargate-remote/.update-lock"
  if sandbox /usr/share/stargate/remote-control.sh stop; then fail 'stop interrupted a configuration update'; fi
  assert_running router
  rmdir "$root/etc/stargate-remote/.update-lock"
  sandbox /usr/share/stargate/remote-control.sh stop
  if assert_enabled router || assert_running router; then fail 'stop did not disable component'; fi
}

test_enrollment_recovery() {
  fixture enrollment-recovery
  touch "$root/fail/prepare"
  reject_install router
  recovery=$(find "$root/root" -name 'stargate-remote-enrollment-*' -type d -print)
  [ -f "$recovery/profile.json" ] || fail 'consumed enrollment identity has no recovery copy'
  [ "$(stat -c %a "$recovery/profile.json")" = 600 ]
  [ "$(stat -c %a "$recovery")" = 700 ]
  [ ! -e "$root/etc/stargate-remote/profile.json" ]
  rm "$root/fail/prepare"
  sandbox /package/install-router.sh /bundle
  cp "$recovery/profile.json" "$root/etc/stargate-remote/profile.json"
  sandbox /bundle/remote-control.sh start
  [ -f "$root/etc/stargate-remote/frpc.json" ]
}

run() {
  label=$1; shift
  count=$((count + 1))
  set +e
  (set -e; "$@") >"$temporary/scenario-$count.log" 2>&1
  result=$?
  set -e
  if [ "$result" != 0 ]; then
    printf 'FAIL %s\n' "$label" >&2
    cat "$temporary/scenario-$count.log" >&2
    failed=$((failed + 1))
  fi
}

for component in server router luci; do
  run "$component fresh install and rollback" test_fresh "$component"
  run "$component install and rollback lock" test_locked "$component"
  run "$component copy failure preserves prior files" test_copy_failure "$component"
  run "$component first install failure restores pre-install files" test_first_failure "$component"
done
for component in server router; do
  for state in running disabled enabled-stopped disabled-running; do run "$component upgrade preserves $state" test_upgrade "$component" "$state"; done
  for kind in empty missing damaged incomplete cross unknown paths member missing-member saved-enabled saved-active; do run "$component rejects $kind backup before stopping" test_reject_backup "$component" "$kind"; done
  run "$component rejects failed binary verification" test_bad_package "$component" verify
  run "$component start failure restores old installation" test_service_failure "$component"
done
for kind in empty missing damaged incomplete cross unknown paths member missing-member; do run "LuCI rejects $kind backup before changes" test_reject_backup luci "$kind"; done
run 'server health failure restores old installation' test_server_health
run 'server prepare failure restores identities and running services' test_server_prepare_failure
run 'router rejects invalid service script' test_bad_package router init
run 'router offline upgrade retains services' test_router_offline
run 'router requires all three processes' test_router_incomplete
run 'router busy configuration update prevents snapshot changes' test_router_busy_snapshot
run 'router rollback restores a broken current init' test_restore_bad_init
for kind in template menu missing; do run "LuCI rejects $kind package" test_bad_package luci "$kind"; done
for kind in reject-remote success restart-failure rollback; do run "system sing-box maintenance $kind" test_singbox_maintenance "$kind"; done
run 'router standby install, upgrade and enrollment' test_standby
run 'failed installation preserves consumed enrollment identity' test_enrollment_recovery
for kind in success import-failure sync-failure; do run "link enrollment bridge $kind" test_bridge "$kind"; done
printf 'Installer isolation: %s scenarios, %s failures\n' "$count" "$failed"
[ "$failed" -eq 0 ]
