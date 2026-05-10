'use strict';
'require view';
'require form';
'require fs';
'require uci';
'require ui';

function parseStatus(text) {
  try {
    return JSON.parse(text || '{}');
  } catch (e) {
    return {};
  }
}

function execNotify(command, args, title) {
  return fs.exec(command, args)
    .then(function(res) {
      ui.addNotification(title || null, E('pre', { 'style': 'white-space:pre-wrap' }, res.stdout || _('Done')));
      return res;
    })
    .catch(function(err) {
      ui.addNotification(title || null, E('pre', { 'style': 'white-space:pre-wrap' }, err.message), 'danger');
    });
}

return view.extend({
  load: function() {
    return Promise.all([
      uci.load('stargate'),
      fs.exec_direct('/usr/share/stargate/stargate.sh', [ 'status' ]).then(parseStatus).catch(function(err) {
        return { service: String(err), singbox: '' };
      })
    ]);
  },

  render: function(data) {
    var status = data[1] || {};
    var m = new form.Map('stargate', _('Stargate'));
    m.description = _('Runtime status, startup mode, and local outlet checks.');

    var s = m.section(form.NamedSection, 'global', 'global', _('Overview'));
    s.anonymous = true;

    var dashboard = s.option(form.DummyValue, '_dashboard', '');
    dashboard.rawhtml = true;
    dashboard.cfgvalue = function() {
      var blocked = !status.node_ready;

      function card(title, value, note, icon) {
        return E('div', { 'class': 'stargate-card' }, [
          E('span', { 'class': 'stargate-icon' }, icon || 'S'),
          E('span', { 'class': 'stargate-card-body' }, [
            E('span', { 'class': 'stargate-card-title' }, title),
            E('span', { 'class': 'stargate-card-value' }, value),
            E('span', { 'class': 'stargate-card-note' }, note || '')
          ])
        ]);
      }

      function actionButton(label, action, cls) {
        return E('button', {
          'class': 'btn cbi-button ' + (cls || 'cbi-button-neutral'),
          'disabled': blocked && action !== 'stop' && action !== 'rollback' ? '' : null,
          'click': function() {
            if (blocked && action !== 'stop' && action !== 'rollback')
              return;
            if (action === 'start-transparent') {
              var mode = document.querySelector('[name="cbid.stargate.inbound.transparent_mode"]');
              var port = document.querySelector('[name="cbid.stargate.inbound.transparent_port"]');
              return execNotify('/usr/share/stargate/stargate.sh', [
                'start-transparent',
                mode && mode.value ? mode.value : 'redirect',
                port && port.value ? port.value : '12345'
              ], _('Operation result'));
            }
            return execNotify('/usr/share/stargate/stargate.sh', [ action ], _('Operation result'));
          }
        }, [ label ]);
      }

      return E('div', { 'class': 'stargate-wrap' }, [
        E('style', {}, [
          '.stargate-wrap{max-width:1180px;margin:0 auto;padding:4px 4px 8px}',
          '.stargate-dashboard{display:grid;grid-template-columns:repeat(4,minmax(190px,1fr));gap:12px;margin:8px 0 14px}',
          '.stargate-card{box-sizing:border-box;display:flex;align-items:center;gap:13px;min-height:92px;padding:14px 15px;border:1px solid rgba(140,140,140,.72);border-radius:6px;background:rgba(127,127,127,.08);text-align:left}',
          '.stargate-card-body{display:block;min-width:0}',
          '.stargate-card-title{display:block;font-size:12px;opacity:.72}',
          '.stargate-card-value{display:block;font-size:19px;font-weight:700;margin-top:5px;line-height:1.18;word-break:break-word}',
          '.stargate-card-note{display:block;font-size:11px;opacity:.72;margin-top:5px;line-height:1.35}',
          '.stargate-icon{display:flex;align-items:center;justify-content:center;flex:0 0 42px;width:42px;height:42px;border-radius:50%;font-size:18px;font-weight:700;color:#fff;background:#687485}',
          '.stargate-alert{max-width:880px;margin:0 auto 14px;padding:11px 13px;border:1px solid rgba(251,99,64,.55);border-radius:6px;color:#fb6340;background:rgba(251,99,64,.08)}',
          '.stargate-runtime{max-width:880px;margin:12px auto 6px;display:grid;grid-template-columns:minmax(200px,1fr) 2fr;gap:12px;align-items:center;padding:14px;border:1px solid rgba(140,140,140,.42);border-radius:6px;background:rgba(127,127,127,.05)}',
          '.stargate-runtime-title{font-size:13px;font-weight:700}',
          '.stargate-runtime-note{font-size:11px;opacity:.72;margin-top:4px;line-height:1.4}',
          '.stargate-runtime-actions{display:flex;justify-content:flex-end;gap:10px;flex-wrap:wrap}',
          '@media screen and (max-width:1180px){.stargate-dashboard{grid-template-columns:repeat(2,minmax(220px,1fr))}}',
          '@media screen and (max-width:720px){.stargate-dashboard,.stargate-runtime{grid-template-columns:1fr}.stargate-card{min-height:84px}.stargate-runtime-actions{justify-content:flex-start}}'
        ].join('')),
        blocked ? E('div', { 'class': 'stargate-alert' }, _('No active node is configured. Add a node on the Node page and choose Use this node before enabling or starting Stargate.')) : '',
        E('div', { 'class': 'stargate-dashboard' }, [
          card(_('Runtime'), blocked ? _('not ready') : (status.service || _('unknown')), blocked ? _('active node required') : (status.transparent_proxy ? _('Transparent proxy') : _('Local proxy')), 'S'),
          card('sing-box', status.singbox || _('not detected'), status.config_file || '/etc/stargate/config.json', 'SB'),
          card(_('Local proxy'), (status.socks_listen || '127.0.0.1') + ':' + (status.socks_port || '10808'), 'HTTP ' + (status.http_listen || '127.0.0.1') + ':' + (status.http_port || '10809'), 'P'),
          card(_('Node'), status.node_ready ? (status.node_server || _('Active node')) : _('not ready'), status.node_ready ? _('AnyTLS primary') : _('Add and use a node first'), 'N')
        ]),
        E('div', { 'class': 'stargate-runtime' }, [
          E('div', {}, [
            E('div', { 'class': 'stargate-runtime-title' }, _('Startup mode')),
            E('div', { 'class': 'stargate-runtime-note' }, _('Local proxy keeps only SOCKS/HTTP. Transparent proxy adds a sing-box transparent inbound; redirect is the default.'))
          ]),
          E('div', { 'class': 'stargate-runtime-actions' }, [
            actionButton(_('Start local proxy'), 'start', 'cbi-button-apply'),
            actionButton(_('Start transparent proxy'), 'start-transparent', 'cbi-button-action'),
            actionButton(_('Stop'), 'stop'),
            actionButton(_('Rollback config'), 'rollback')
          ])
        ])
      ]);
    };

    var tp = m.section(form.NamedSection, 'inbound', 'inbound', _('Transparent proxy'));
    tp.anonymous = true;

    var mode = tp.option(form.ListValue, 'transparent_mode', _('Transparent mode'));
    mode.value('redirect', 'redirect');
    mode.value('tproxy', 'tproxy');
    mode.default = 'redirect';
    mode.rmempty = false;

    var port = tp.option(form.Value, 'transparent_port', _('Transparent port'));
    port.default = '12345';
    port.datatype = 'port';

    return m.render();
  }
});
