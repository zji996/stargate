'use strict';
'require view';
'require form';
'require fs';
'require ui';

return view.extend({
  load: function() {
    return fs.exec_direct('/usr/share/stargate/stargate.sh', [ 'logs' ]).catch(function() {
      return '';
    });
  },

  render: function(logs) {
    var m = new form.Map('stargate', _('Logs'));
    m.description = _('Recent Stargate and sing-box logs.');

    var s = m.section(form.NamedSection, 'global', 'global', _('Recent logs'));
    s.anonymous = true;

    var box = s.option(form.DummyValue, '_logs', '');
    box.rawhtml = true;
    box.cfgvalue = function() {
      function reloadWith(cmd) {
        return fs.exec_direct('/usr/share/stargate/stargate.sh', [ cmd ]).then(function(text) {
          var pre = document.querySelector('.stargate-log-box');
          if (pre)
            pre.textContent = text || _('No logs');
        });
      }

      return E('div', {}, [
        E('style', {}, [
          '.stargate-log-actions{display:flex;gap:10px;flex-wrap:wrap;justify-content:flex-end;margin:0 0 12px}',
          '.stargate-log-box{white-space:pre-wrap;overflow:auto;max-height:560px;margin:0;padding:14px;border:1px solid rgba(127,127,127,.28);border-radius:6px;background:rgba(0,0,0,.16);font-size:12px;line-height:1.55}'
        ].join('')),
        E('div', { 'class': 'stargate-log-actions' }, [
          E('button', {
            'class': 'btn cbi-button',
            'click': function() { return reloadWith('logs'); }
          }, [ _('Filtered logs') ]),
          E('button', {
            'class': 'btn cbi-button',
            'click': function() { return reloadWith('logs-raw'); }
          }, [ _('Raw logs') ]),
          E('button', {
            'class': 'btn cbi-button cbi-button-reset',
            'click': function() {
              return fs.exec_direct('/usr/share/stargate/stargate.sh', [ 'logs-clear' ]).then(function(text) {
                ui.addNotification(null, E('pre', {}, text || _('Logs cleared')));
                return reloadWith('logs');
              });
            }
          }, [ _('Clear logs') ])
        ]),
        E('pre', { 'class': 'stargate-log-box' }, logs || _('No logs'))
      ]);
    };

    return m.render();
  }
});
