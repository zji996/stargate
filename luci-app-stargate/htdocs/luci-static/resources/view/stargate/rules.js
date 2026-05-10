'use strict';
'require view';
'require form';
'require fs';
'require ui';

return view.extend({
  load: function() {
    return fs.exec_direct('/usr/share/stargate/stargate.sh', [ 'rules-status' ]).catch(function() {
      return '';
    });
  },

  render: function(status) {
    var m = new form.Map('stargate', _('Rules'));
    m.description = _('Use Loyalsoldier rules with small user overrides. Rules are not bundled; update them explicitly before generating config.');

    var s = m.section(form.NamedSection, 'rules', 'rules', _('Rule policy'));
    s.anonymous = true;

    var mode = s.option(form.ListValue, 'mode', _('Mode'));
    mode.value('ruleset', _('Loyalsoldier direct/proxy rules'));
    mode.value('global_proxy', _('Global proxy'));
    mode.value('direct', _('Direct only'));
    mode.default = 'ruleset';
    mode.description = _('Recommended: use upstream direct-list and proxy-list. User direct/proxy domains are matched before upstream rules.');

    var source = s.option(form.ListValue, 'source', _('Rule source'));
    source.value('loyalsoldier', 'Loyalsoldier/v2ray-rules-dat');
    source.default = 'loyalsoldier';
    source.depends('mode', 'ruleset');

    var sourceBase = s.option(form.Value, 'source_base_url', _('Source base URL'));
    sourceBase.default = 'https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release';
    sourceBase.depends('mode', 'ruleset');

    var directSet = s.option(form.Value, 'direct_rule_set', _('Direct rule-set path'));
    directSet.default = '/usr/share/stargate/rules/direct.json';
    directSet.depends('mode', 'ruleset');

    var proxySet = s.option(form.Value, 'proxy_rule_set', _('Proxy rule-set path'));
    proxySet.default = '/usr/share/stargate/rules/proxy.json';
    proxySet.depends('mode', 'ruleset');

    var proxyOutbound = s.option(form.ListValue, 'proxy_outbound', _('Proxy outbound'));
    proxyOutbound.value('anytls-out', _('Proxy'));
    proxyOutbound.value('direct', _('Direct'));
    proxyOutbound.default = 'anytls-out';
    proxyOutbound.depends('mode', 'ruleset');

    var final = s.option(form.ListValue, 'default_outbound', _('Default outbound'));
    final.value('direct', _('Direct'));
    final.value('anytls-out', _('Proxy'));
    final.default = 'direct';

    var directDomains = s.option(form.TextValue, 'custom_direct_domains', _('User direct domains'));
    directDomains.rows = 5;
    directDomains.wrap = 'off';
    directDomains.description = _('One domain per line. These domains always go direct and take priority over upstream proxy rules.');
    directDomains.depends('mode', 'ruleset');

    var proxyDomains = s.option(form.TextValue, 'custom_proxy_domains', _('User proxy domains'));
    proxyDomains.rows = 5;
    proxyDomains.wrap = 'off';
    proxyDomains.description = _('One domain per line. These domains always use the proxy outbound and take priority over upstream direct rules.');
    proxyDomains.depends('mode', 'ruleset');

    var actions = s.option(form.DummyValue, '_rules_actions', _('Rule actions'));
    actions.rawhtml = true;
    actions.cfgvalue = function() {
      return E('div', { 'class': 'stargate-rule-actions' }, [
        E('style', {}, [
          '.stargate-rule-actions{display:grid;gap:10px;max-width:920px}',
          '.stargate-rule-action-row{display:flex;gap:10px;align-items:center;flex-wrap:wrap}',
          '.stargate-rule-status{white-space:pre-wrap;font-size:12px;opacity:.78;padding:10px;border-top:1px solid rgba(127,127,127,.18)}'
        ].join('')),
        E('div', { 'class': 'stargate-rule-action-row' }, [
          E('button', {
            'class': 'btn cbi-button cbi-button-apply',
            'click': ui.createHandlerFn(this, function() {
              return fs.exec('/usr/share/stargate/stargate.sh', [ 'rules-update' ])
                .then(function(res) { ui.addNotification(null, E('pre', {}, res.stdout || _('Rules updated'))); })
                .catch(function(err) { ui.addNotification(null, E('pre', {}, err.message), 'danger'); });
            })
          }, [ _('Update Loyalsoldier rules') ]),
          E('button', {
            'class': 'btn cbi-button',
            'click': ui.createHandlerFn(this, function() {
              return fs.exec('/usr/share/stargate/stargate.sh', [ 'rules-status' ])
                .then(function(res) { ui.addNotification(null, E('pre', {}, res.stdout || '')); });
            })
          }, [ _('Refresh status') ])
        ]),
        E('div', { 'class': 'stargate-rule-status' }, status || '')
      ]);
    };
    actions.depends('mode', 'ruleset');

    var privateDirect = s.option(form.Flag, 'private_direct', _('Private IP direct'));
    privateDirect.default = '1';
    privateDirect.rmempty = false;

    var blockQuic = s.option(form.Flag, 'block_quic', _('Block QUIC'));
    blockQuic.default = '0';
    blockQuic.rmempty = false;

    return m.render();
  }
});
