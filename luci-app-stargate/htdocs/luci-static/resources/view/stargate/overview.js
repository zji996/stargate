'use strict';
'require view';
'require form';
'require fs';
'require uci';

function parseStatus(text) {
  try {
    return JSON.parse(text || '{}');
  } catch (e) {
    return {};
  }
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
    m.description = _('Runtime status, proxy mode, and local outlet checks.');

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
          '#cbi-stargate-global-enabled,#cbi-stargate-inbound-transparent_proxy{max-width:880px;margin:12px auto;padding:14px;border:1px solid rgba(140,140,140,.42);border-radius:6px;background:rgba(127,127,127,.05);display:grid;grid-template-columns:minmax(180px,260px) 1fr;gap:12px;align-items:center}',
          '#cbi-stargate-global-enabled .cbi-value-title,#cbi-stargate-inbound-transparent_proxy .cbi-value-title{font-weight:700}',
          '#cbi-stargate-global-enabled .cbi-value-description,#cbi-stargate-inbound-transparent_proxy .cbi-value-description{display:block;margin-top:5px;font-size:11px;line-height:1.45;opacity:.72}',
          '#cbi-stargate-global-enabled .cbi-value-field,#cbi-stargate-inbound-transparent_proxy .cbi-value-field{display:flex;align-items:center;justify-content:flex-start;min-height:34px}',
          '#cbi-stargate-global-enabled input[type="checkbox"],#cbi-stargate-inbound-transparent_proxy input[type="checkbox"]{width:22px;height:22px;margin:0 10px 0 0;vertical-align:middle}',
          '#cbi-stargate-inbound-transparent_proxy.stargate-disabled{opacity:.58}',
          '#cbi-stargate-inbound-transparent_proxy.stargate-disabled input[type="checkbox"]{cursor:not-allowed}',
          '#cbi-stargate-inbound-transparent_proxy.stargate-disabled .cbi-value-description:after{content:" ' + _('Enable local proxy first.') + '";color:#fb9a05}',
          '#cbi-stargate-inbound-transparent_mode,#cbi-stargate-inbound-transparent_port{max-width:880px;margin-left:auto;margin-right:auto}',
          '@media screen and (max-width:1180px){.stargate-dashboard{grid-template-columns:repeat(2,minmax(220px,1fr))}}',
          '@media screen and (max-width:720px){.stargate-dashboard,#cbi-stargate-global-enabled,#cbi-stargate-inbound-transparent_proxy{grid-template-columns:1fr}.stargate-card{min-height:84px}}'
        ].join('')),
        blocked ? E('div', { 'class': 'stargate-alert' }, _('No active node is configured. Add a node on the Node page and choose Use this node before enabling or starting Stargate.')) : '',
        E('div', { 'class': 'stargate-dashboard' }, [
          card(_('Runtime'), blocked ? _('not ready') : (status.service || _('unknown')), blocked ? _('active node required') : (status.transparent_proxy ? _('Transparent proxy') : _('Local proxy')), 'S'),
          card('sing-box', status.singbox || _('not detected'), status.config_file || '/etc/stargate/config.json', 'SB'),
          card(_('Local proxy'), (status.socks_listen || '127.0.0.1') + ':' + (status.socks_port || '10808'), 'HTTP ' + (status.http_listen || '127.0.0.1') + ':' + (status.http_port || '10809'), 'P'),
          card(_('Node'), status.node_ready ? (status.node_server || _('Active node')) : _('not ready'), status.node_ready ? _('AnyTLS primary') : _('Add and use a node first'), 'N')
        ]),
      ]);
    };

    var local = s.option(form.Flag, 'enabled', _('Local proxy'));
    local.description = _('Enable Stargate with local SOCKS/HTTP inbounds only. Use Save & Apply in the bottom-right corner to commit this choice.');
    local.default = '0';
    local.rmempty = false;

    var tp = m.section(form.NamedSection, 'inbound', 'inbound', _('Transparent proxy'));
    tp.anonymous = true;

    var enabled = tp.option(form.Flag, 'transparent_proxy', _('Transparent proxy'));
    enabled.description = _('Optional transparent inbound. Enable local proxy first, then configure forwarding on the Advanced page.');
    enabled.default = '0';
    enabled.rmempty = false;

    var mode = tp.option(form.ListValue, 'transparent_mode', _('Transparent mode'));
    mode.value('redirect', 'redirect');
    mode.value('tproxy', 'tproxy');
    mode.default = 'redirect';
    mode.rmempty = false;
    mode.depends('transparent_proxy', '1');

    var port = tp.option(form.Value, 'transparent_port', _('Transparent port'));
    port.default = '12345';
    port.datatype = 'port';
    port.depends('transparent_proxy', '1');

    return m.render().then(function(node) {
      function syncRuntimeCheckboxes() {
        var localBox = node.querySelector('[name="cbid.stargate.global.enabled"][type="checkbox"]');
        var transparentBox = node.querySelector('[name="cbid.stargate.inbound.transparent_proxy"][type="checkbox"]');
        var transparentRow = node.querySelector('#cbi-stargate-inbound-transparent_proxy');

        if (!localBox || !transparentBox)
          return;

        if (!localBox.checked)
          transparentBox.checked = false;

        if (transparentRow)
          transparentRow.classList.toggle('stargate-disabled', !localBox.checked);
      }

      var localBox = node.querySelector('[name="cbid.stargate.global.enabled"][type="checkbox"]');
      var transparentBox = node.querySelector('[name="cbid.stargate.inbound.transparent_proxy"][type="checkbox"]');
      if (localBox)
        localBox.addEventListener('change', syncRuntimeCheckboxes);
      if (transparentBox)
        transparentBox.addEventListener('change', function() {
          if (localBox && !localBox.checked)
            transparentBox.checked = false;
          syncRuntimeCheckboxes();
        });
      syncRuntimeCheckboxes();

      return node;
    });
  }
});
