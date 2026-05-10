'use strict';
'require view';
'require form';
'require fs';
'require ui';

return view.extend({
  load: function() {
    return fs.exec_direct('/usr/share/stargate/stargate.sh', [ 'status' ]).then(function(text) {
      try {
        return JSON.parse(text || '{}');
      } catch (e) {
        return {};
      }
    }).catch(function() {
      return {};
    });
  },

  render: function(status) {
    var m = new form.Map('stargate', _('Component Settings'));
    m.description = _('Manage sing-box component paths and explicit config lifecycle actions.');

    var ops = m.section(form.NamedSection, 'global', 'global', _('Runtime maintenance'));
    ops.anonymous = true;

    var logLevel = ops.option(form.ListValue, 'log_level', _('Log level'));
    logLevel.value('debug', 'debug');
    logLevel.value('info', 'info');
    logLevel.value('warn', 'warn');
    logLevel.value('error', 'error');
    logLevel.default = 'warn';

    var bin = ops.option(form.Value, 'singbox_bin', _('sing-box binary'));
    bin.default = '/usr/bin/sing-box';

    var configFile = ops.option(form.Value, 'config_file', _('Generated config'));
    configFile.default = '/etc/stargate/config.json';

    var workDir = ops.option(form.Value, 'work_dir', _('Work directory'));
    workDir.default = '/etc/stargate';

    var actions = ops.option(form.DummyValue, '_actions', _('Maintenance actions'));
    actions.rawhtml = true;
    actions.cfgvalue = function() {
      var blocked = !status.node_ready;
      var blockedNote = _('Blocked until an active node is configured on the Node page.');

      function actionButton(label, note, command, args, cls, requiresNode) {
        var disabled = !!requiresNode && blocked;
        return E('div', { 'class': 'stargate-component-action' }, [
          E('button', {
            'class': 'btn cbi-button ' + (cls || 'cbi-button-neutral'),
            'disabled': disabled ? '' : null,
            'click': ui.createHandlerFn(this, function() {
              if (disabled)
                return;
              return fs.exec(command, args)
                .then(function(res) { ui.addNotification(null, E('p', {}, res.stdout || label)); })
                .catch(function(err) { ui.addNotification(null, E('p', {}, err.message), 'danger'); });
            })
          }, [ label ]),
          E('div', { 'class': 'stargate-component-note' }, disabled ? [ note, E('br'), E('strong', {}, blockedNote) ] : note)
        ]);
      }

      return E('div', { 'class': 'stargate-component-actions' }, [
        E('style', {}, [
          '.stargate-component-actions{display:grid;gap:10px;max-width:920px}',
          '.stargate-component-action{display:grid;grid-template-columns:120px 1fr;gap:12px;align-items:center;padding:12px;border-top:1px solid rgba(127,127,127,.18)}',
          '.stargate-component-note{font-size:12px;opacity:.76;line-height:1.45}',
          '@media screen and (max-width:720px){.stargate-component-action{grid-template-columns:1fr}}'
        ].join('')),
        actionButton(_('Generate'), _('Build the next sing-box config from UCI. It only writes the staging file and does not start the service.'), '/usr/share/stargate/stargate.sh', [ 'generate' ], null, true),
        actionButton(_('Check'), _('Run sing-box check against the staging config before it becomes active.'), '/usr/share/stargate/stargate.sh', [ 'check' ], null, true),
        actionButton(_('Apply'), _('Validate and replace the active config. It does not enable transparent proxy or change firewall rules.'), '/usr/share/stargate/stargate.sh', [ 'apply' ], 'cbi-button-apply', true),
        actionButton(_('Restart'), _('Restart only the Stargate sing-box service with the current active config.'), '/etc/init.d/stargate', [ 'restart' ], 'cbi-button-action', true),
        actionButton(_('Rollback'), _('Restore the last backup config created before Apply. If Stargate is running, it restarts with the restored config.'), '/usr/share/stargate/stargate.sh', [ 'rollback' ], null, false)
      ]);
    };

    return m.render();
  }
});
