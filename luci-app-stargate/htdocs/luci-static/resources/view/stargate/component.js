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
        '#cbi-stargate .cbi-section{max-width:1040px;margin:0 auto 18px;border-radius:8px;padding:0;overflow:hidden;box-shadow:0 0 .5rem 0 rgba(0,0,0,.22);background:rgba(127,127,127,.06)}',
        '#cbi-stargate .cbi-section>h3{margin:0;padding:16px 22px;font-size:16px;font-weight:700;line-height:1.3;background:rgba(127,127,127,.14);border-bottom:1px solid rgba(127,127,127,.12);color:inherit}',
        '#cbi-stargate .cbi-section-node{padding:0;margin:0;display:flex;flex-direction:column;gap:0}',
        '#cbi-stargate-global-_style{display:none!important}',
        '.stargate-maint-row{display:flex;align-items:center;min-height:64px;box-sizing:border-box;margin:0;padding:14px 22px;border-top:1px solid rgba(127,127,127,.12);width:100%}',
        '.stargate-maint-row:first-of-type{border-top:0}',
        '#cbi-stargate .cbi-value:not(#cbi-stargate-global-_style):not(#cbi-stargate-safety-_actions){display:flex!important;align-items:center!important;min-height:64px!important;box-sizing:border-box!important;margin:0!important;padding:14px 22px!important;border:0!important;border-top:1px solid rgba(127,127,127,.12)!important;width:100%!important;max-width:none!important;line-height:normal!important;background:none!important}',
        '#cbi-stargate .cbi-value>.cbi-value-title,#cbi-stargate .stargate-maint-label{float:none!important;position:static!important;display:block!important;width:200px!important;min-width:200px!important;max-width:200px!important;padding:0!important;margin:0!important;text-align:left!important;font-size:14px!important;font-weight:600!important;color:inherit!important;word-wrap:break-word!important}',
        '#cbi-stargate .cbi-value>.cbi-value-field,#cbi-stargate .stargate-maint-control{float:none!important;position:static!important;display:flex!important;align-items:center!important;gap:10px!important;flex:1 1 auto!important;min-width:0!important;padding:0!important;margin:0!important;width:auto!important}',
        '#cbi-stargate .cbi-value-field>div[data-ui-widget]{width:100%;max-width:480px}',
        '#cbi-stargate .cbi-value-field input[type="text"]{width:100%!important;max-width:480px!important;min-width:0!important;box-sizing:border-box!important}',
        '#cbi-stargate .cbi-value-description{display:none!important}',
        '.stargate-inline-form{display:flex;align-items:center;gap:10px;flex-wrap:wrap;width:100%}',
        '.stargate-inline-form input[type="file"],.stargate-maint-control input[type="file"]{max-width:320px;box-sizing:border-box}',
        '.stargate-maint-panel{width:100%}',
        '.stargate-maint-control .cbi-button,.stargate-maint-control a.cbi-button{min-width:110px;text-align:center;box-sizing:border-box}',
        '.stargate-maint-version{font-family:monospace;font-size:13.5px;opacity:.82;word-break:break-all}',
        '@media screen and (max-width:768px){',
        '  #cbi-stargate .cbi-value:not(#cbi-stargate-global-_style):not(#cbi-stargate-safety-_actions),.stargate-maint-row{flex-direction:column!important;align-items:flex-start!important;gap:8px!important;padding:12px 16px!important}',
        '  #cbi-stargate .cbi-value>.cbi-value-title,#cbi-stargate .stargate-maint-label{width:100%!important;max-width:none!important;margin-bottom:4px!important}',
        '  #cbi-stargate .cbi-value>.cbi-value-field,#cbi-stargate .stargate-maint-control{width:100%!important;flex-wrap:wrap!important}',
        '  #cbi-stargate .cbi-value-field>div[data-ui-widget],#cbi-stargate .cbi-value-field input[type="text"],.stargate-inline-form input[type="file"],.stargate-maint-control input[type="file"]{max-width:100%!important}',
        '}'
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

    var backup = m.section(form.NamedSection, 'safety', 'safety', _('Backup restore'));
    backup.anonymous = true;

    var actions = backup.option(form.DummyValue, '_actions', '');
    actions.rawhtml = true;
    actions.cfgvalue = function() {
      return E('div', { 'class': 'stargate-maint-panel' }, [
        E('style', {}, [
          '#cbi-stargate-safety-_actions{display:block!important;margin:0!important;padding:0!important;border:0!important;width:100%!important;line-height:normal!important}',
          '#cbi-stargate-safety-_actions>.cbi-value-title{display:none!important}',
          '#cbi-stargate-safety-_actions>.cbi-value-field{display:block!important;margin:0!important;width:100%!important}'
        ].join('')),
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
      ]);
    };

    return m.render();
  }
});
