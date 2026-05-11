'use strict';
'require view';
'require form';
'require fs';
'require ui';

return view.extend({
  load: function() {
    return fs.exec_direct('/usr/share/stargate/stargate.sh', [ 'firewall-status' ]).catch(function() {
      return '';
    });
  },

  render: function(status) {
    var m = new form.Map('stargate', _('Advanced'));
    m.description = _('Forwarding and system integration settings for transparent proxy.');

    var s = m.section(form.NamedSection, 'inbound', 'inbound', _('Forwarding'));
    s.anonymous = true;

    var panel = s.option(form.DummyValue, '_forwarding_actions', _('Forwarding rules'));
    panel.rawhtml = true;
    panel.cfgvalue = function() {
      var view = this;
      function button(cmd, label, klass) {
        return E('button', {
          'class': 'btn cbi-button ' + (klass || ''),
          'click': ui.createHandlerFn(view, function() {
            return fs.exec('/usr/share/stargate/stargate.sh', [ cmd ])
              .then(function(res) {
                ui.addNotification(null, E('pre', {}, (res && res.stdout) || label));
                window.setTimeout(function() { window.location.reload(); }, 600);
              })
              .catch(function(err) { ui.addNotification(null, E('pre', {}, err.message), 'danger'); });
          })
        }, [ label ]);
      }

      return E('div', { 'class': 'stargate-advanced-panel' }, [
        E('style', {}, [
          '.stargate-advanced-panel{max-width:960px;margin:0 auto;display:grid;gap:14px}',
          '.stargate-forwarding-card{display:grid;grid-template-columns:1fr auto;gap:16px;align-items:center;padding:16px;border:1px solid rgba(140,140,140,.42);border-radius:6px;background:rgba(127,127,127,.05)}',
          '.stargate-forwarding-status{font-size:12px;line-height:1.55;white-space:pre-wrap;opacity:.82}',
          '.stargate-forwarding-actions{display:flex;gap:10px;flex-wrap:wrap;justify-content:flex-end}',
          '.stargate-forwarding-note{font-size:12px;line-height:1.5;opacity:.72}',
          '@media(max-width:720px){.stargate-forwarding-card{grid-template-columns:1fr}.stargate-forwarding-actions{justify-content:flex-start}}'
        ].join('')),
        E('div', { 'class': 'stargate-forwarding-card' }, [
          E('div', {}, [
            E('div', { 'class': 'stargate-forwarding-status' }, status || _('No firewall backend status.')),
            E('div', { 'class': 'stargate-forwarding-note' }, _('Applies or removes only Stargate-owned transparent proxy forwarding rules. Backend is selected automatically: nftables first, iptables fallback.'))
          ]),
          E('div', { 'class': 'stargate-forwarding-actions' }, [
            button('firewall-apply', _('Apply transparent forwarding'), 'cbi-button-apply'),
            button('firewall-clean', _('Clean Stargate forwarding'), '')
          ])
        ])
      ]);
    };

    return m.render();
  }
});
