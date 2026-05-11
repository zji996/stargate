'use strict';
'require view';
'require form';
'require fs';
'require ui';

return view.extend({
  render: function() {
    var m = new form.Map('stargate', _('Maintenance'));
    m.description = _('Maintain sing-box paths, future component upgrades, and Stargate backup restore.');

    var s = m.section(form.NamedSection, 'global', 'global', _('sing-box settings'));
    s.anonymous = true;

    var style = s.option(form.DummyValue, '_style', '');
    style.rawhtml = true;
    style.cfgvalue = function() {
      return E('style', {}, [
        '#cbi-stargate-global{max-width:960px;margin:0 auto 18px;border-radius:6px;overflow:hidden;background:rgba(127,127,127,.06)}',
        '#cbi-stargate-global>legend{display:flex;align-items:center;min-height:58px;box-sizing:border-box;margin:0;padding:0 22px;width:100%;border:0;background:rgba(127,127,127,.14);font-size:22px;font-weight:700}',
        '#cbi-stargate-global .cbi-section-node{padding:0}',
        '#cbi-stargate-global-_style{display:none}',
        '#cbi-stargate-global-singbox_bin,#cbi-stargate-global-_current_version,#cbi-stargate-global-_upgrade_actions{display:grid;grid-template-columns:220px minmax(320px,520px);gap:16px;align-items:center;min-height:72px;box-sizing:border-box;margin:0;padding:14px 22px;border-top:1px solid rgba(127,127,127,.10)}',
        '#cbi-stargate-global-singbox_bin .cbi-value-title,#cbi-stargate-global-_current_version .cbi-value-title,#cbi-stargate-global-_upgrade_actions .cbi-value-title{text-align:right;font-size:15px;font-weight:600}',
        '#cbi-stargate-global-singbox_bin .cbi-value-field,#cbi-stargate-global-_current_version .cbi-value-field,#cbi-stargate-global-_upgrade_actions .cbi-value-field{display:block;margin:0;width:auto}',
        '#cbi-stargate-global-singbox_bin .cbi-value-description{display:none}',
        '#cbi-stargate-global-singbox_bin input[type="text"]{width:100%;max-width:520px;box-sizing:border-box}',
        '.stargate-inline-form{display:flex;align-items:center;gap:10px;flex-wrap:wrap}',
        '.stargate-inline-form input[type="file"]{max-width:300px}',
        '.stargate-maint{display:grid;gap:18px;max-width:960px;margin:0 auto 18px}',
        '.stargate-maint-panel{border-radius:6px;overflow:hidden;background:rgba(127,127,127,.06)}',
        '.stargate-maint-head{display:flex;align-items:center;min-height:58px;padding:0 22px;background:rgba(127,127,127,.14)}',
        '.stargate-maint-title{font-size:22px;font-weight:700;line-height:1.2}',
        '.stargate-maint-row{display:grid;grid-template-columns:220px minmax(320px,520px);gap:16px;align-items:center;min-height:72px;padding:14px 22px;border-top:1px solid rgba(127,127,127,.10)}',
        '.stargate-maint-row:nth-child(odd){background:rgba(127,127,127,.045)}',
        '.stargate-maint-label{text-align:right;font-size:15px;font-weight:600}',
        '.stargate-maint-control{display:flex;align-items:center;gap:10px;min-width:0}',
        '.stargate-maint-control input[type="file"]{width:100%;max-width:300px;box-sizing:border-box}',
        '.stargate-maint-control .cbi-button,.stargate-maint-control a.cbi-button{min-width:118px;text-align:center;box-sizing:border-box}',
        '.stargate-maint-version{opacity:.82}',
        '@media screen and (max-width:820px){#cbi-stargate-global-singbox_bin,#cbi-stargate-global-_current_version,#cbi-stargate-global-_upgrade_actions,.stargate-maint-row{grid-template-columns:1fr;gap:8px}#cbi-stargate-global-singbox_bin .cbi-value-title,#cbi-stargate-global-_current_version .cbi-value-title,#cbi-stargate-global-_upgrade_actions .cbi-value-title,.stargate-maint-label{text-align:left}.stargate-maint-control{flex-wrap:wrap}}'
      ].join(''));
    };

    var bin = s.option(form.Value, 'singbox_bin', _('sing-box binary'));
    bin.default = '/usr/bin/sing-box';

    var currentVersion = s.option(form.DummyValue, '_current_version', _('Current version'));
    currentVersion.rawhtml = true;
    currentVersion.cfgvalue = function() {
      return E('span', { 'class': 'stargate-maint-version' }, _('Use the Lua CBI page on this router to show live version.'));
    };

    var upgradeActions = s.option(form.DummyValue, '_upgrade_actions', _('Component upgrades'));
    upgradeActions.rawhtml = true;
    upgradeActions.cfgvalue = function() {
      return E('form', { 'class': 'stargate-inline-form', 'method': 'post', 'action': L.url('admin/services/stargate/singbox_upgrade'), 'enctype': 'multipart/form-data' }, [
        E('input', { 'type': 'file', 'name': 'binary' }),
        E('input', { 'type': 'hidden', 'name': 'upgrade', 'value': '1' }),
        E('input', { 'class': 'cbi-button cbi-button-action', 'type': 'submit', 'value': _('Upload upgrade') }),
        E('button', {
          'class': 'btn cbi-button',
          'click': ui.createHandlerFn(this, function() {
            return fs.exec('/usr/share/stargate/stargate.sh', [ 'singbox-rollback' ])
              .then(function(res) { ui.addNotification(null, E('p', {}, res.stdout || _('Rollback'))); })
              .catch(function(err) { ui.addNotification(null, E('p', {}, err.message), 'danger'); });
          })
        }, _('Rollback'))
      ]);
    };

    var backup = m.section(form.NamedSection, 'global', 'global', '');
    backup.anonymous = true;

    var actions = backup.option(form.DummyValue, '_actions', '');
    actions.rawhtml = true;
    actions.cfgvalue = function() {
      return E('div', { 'class': 'stargate-maint' }, [
        E('style', {}, [
          '#cbi-stargate-global-_actions{display:block;margin:0;padding:0;border:0}',
          '#cbi-stargate-global-_actions>.cbi-value-title{display:none}',
          '#cbi-stargate-global-_actions>.cbi-value-field{display:block;margin:0;width:100%}'
        ].join('')),
        E('div', { 'class': 'stargate-maint-panel' }, [
          E('div', { 'class': 'stargate-maint-head' }, E('div', { 'class': 'stargate-maint-title' }, _('Backup restore'))),
          E('div', { 'class': 'stargate-maint-row' }, [
            E('div', { 'class': 'stargate-maint-label' }, _('Create backup file')),
            E('div', { 'class': 'stargate-maint-control' }, E('a', { 'class': 'cbi-button cbi-button-apply', 'href': L.url('admin/services/stargate/backup_download') }, _('Download backup')))
          ]),
          E('form', { 'class': 'stargate-maint-row', 'method': 'post', 'action': L.url('admin/services/stargate/backup_restore'), 'enctype': 'multipart/form-data' }, [
            E('div', { 'class': 'stargate-maint-label' }, _('Restore backup file')),
            E('div', { 'class': 'stargate-maint-control' }, [
              E('input', { 'type': 'file', 'name': 'archive', 'accept': '.tar.gz,.tgz,application/gzip' }),
              E('input', { 'type': 'hidden', 'name': 'restore', 'value': '1' }),
              E('input', { 'class': 'cbi-button cbi-button-action', 'type': 'submit', 'value': _('Restore backup') })
            ])
          ]),
          E('div', { 'class': 'stargate-maint-row' }, [
            E('div', { 'class': 'stargate-maint-label' }, _('Restore default config')),
            E('div', { 'class': 'stargate-maint-control' }, E('button', {
              'class': 'btn cbi-button cbi-button-negative',
              'click': ui.createHandlerFn(this, function() {
                if (!confirm(_('Reset Stargate config to defaults and stop the service?')))
                  return;
                return fs.exec('/usr/share/stargate/stargate.sh', [ 'reset-defaults' ])
                  .then(function(res) { ui.addNotification(null, E('p', {}, res.stdout || _('Reset'))); })
                  .catch(function(err) { ui.addNotification(null, E('p', {}, err.message), 'danger'); });
              })
            }, _('Reset')))
          ]),
          E('div', { 'class': 'stargate-maint-row' }, [
            E('div', { 'class': 'stargate-maint-label' }, _('Rollback generated config')),
            E('div', { 'class': 'stargate-maint-control' }, E('button', {
              'class': 'btn cbi-button',
              'click': ui.createHandlerFn(this, function() {
                return fs.exec('/usr/share/stargate/stargate.sh', [ 'rollback' ])
                  .then(function(res) { ui.addNotification(null, E('p', {}, res.stdout || _('Rollback'))); })
                  .catch(function(err) { ui.addNotification(null, E('p', {}, err.message), 'danger'); });
              })
            }, _('Rollback')))
          ])
        ])
      ]);
    };

    return m.render();
  }
});
