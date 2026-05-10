'use strict';
'require view';
'require form';
'require fs';
'require ui';

function parseStatus(text) {
  var rows = [];
  (text || '').split(/\r?\n/).forEach(function(line) {
    var m = line.match(/^([^:]+):\s*(.*)$/);
    if (m)
      rows.push([ m[1], m[2] ]);
  });
  return rows;
}

return view.extend({
  load: function() {
    return fs.exec_direct('/usr/share/stargate/stargate.sh', [ 'rules-status' ]).catch(function() {
      return '';
    });
  },

  render: function(status) {
    var m = new form.Map('stargate', _('Rules'));
    m.description = _('Use Loyalsoldier as the base rule source. Pick a blacklist or whitelist routing mode, then add only the few domains you want to override.');

    var s = m.section(form.NamedSection, 'rules', 'rules', _('Rule policy'));
    s.anonymous = true;

    var mode = s.option(form.ListValue, 'mode', _('Mode'));
    mode.value('blacklist', _('Blacklist mode'));
    mode.value('whitelist', _('Whitelist mode'));
    mode.value('global_proxy', _('Global proxy'));
    mode.value('direct', _('Direct only'));
    mode.default = 'blacklist';
    mode.description = _('Blacklist: default direct, listed proxy domains use the node. Whitelist: default proxy, listed direct domains go direct.');

    var source = s.option(form.ListValue, 'source', _('Rule source'));
    source.value('loyalsoldier', 'Loyalsoldier/v2ray-rules-dat');
    source.default = 'loyalsoldier';
    source.depends('mode', 'blacklist');
    source.depends('mode', 'whitelist');

    var sourceBase = s.option(form.Value, 'source_base_url', _('Source base URL'));
    sourceBase.default = 'https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release';
    sourceBase.depends('mode', 'blacklist');
    sourceBase.depends('mode', 'whitelist');

    var directSet = s.option(form.Value, 'direct_rule_set', _('Direct rule-set path'));
    directSet.default = '/usr/share/stargate/rules/direct.json';
    directSet.depends('mode', 'blacklist');
    directSet.depends('mode', 'whitelist');

    var proxySet = s.option(form.Value, 'proxy_rule_set', _('Proxy rule-set path'));
    proxySet.default = '/usr/share/stargate/rules/proxy.json';
    proxySet.depends('mode', 'blacklist');
    proxySet.depends('mode', 'whitelist');

    var directDomains = s.option(form.TextValue, 'custom_direct_domains', _('User direct domains'));
    directDomains.rows = 5;
    directDomains.wrap = 'off';
    directDomains.description = _('One domain per line. These domains always go direct and take priority over the base rules.');
    directDomains.depends('mode', 'blacklist');
    directDomains.depends('mode', 'whitelist');

    var proxyDomains = s.option(form.TextValue, 'custom_proxy_domains', _('User proxy domains'));
    proxyDomains.rows = 5;
    proxyDomains.wrap = 'off';
    proxyDomains.description = _('One domain per line. These domains always use the node and take priority over the base rules.');
    proxyDomains.depends('mode', 'blacklist');
    proxyDomains.depends('mode', 'whitelist');

    var actions = s.option(form.DummyValue, '_rules_actions', _('Rule actions'));
    actions.rawhtml = true;
    actions.cfgvalue = function() {
      function statusView(text, message) {
        var rows = parseStatus(text);
        return E('div', { 'class': 'stargate-rule-status' }, [
          message ? E('div', { 'class': 'stargate-rule-ok' }, message) : null,
          rows.length ? rows.map(function(row) {
            return E('div', { 'class': 'stargate-rule-status-row' }, [
              E('span', {}, row[0]),
              E('strong', {}, row[1])
            ]);
          }) : E('div', { 'class': 'stargate-rule-status-row' }, [
            E('span', {}, _('Rule files')),
            E('strong', {}, _('Not updated'))
          ])
        ]);
      }

      return E('div', { 'class': 'stargate-rule-actions' }, [
        E('style', {}, [
          '.stargate-rule-actions{display:grid;gap:12px;max-width:920px}',
          '.stargate-rule-action-row{display:flex;gap:10px;align-items:center;flex-wrap:wrap}',
          '.stargate-rule-status{display:grid;gap:8px;padding:12px;border-top:1px solid rgba(127,127,127,.18)}',
          '.stargate-rule-status-row{display:flex;justify-content:space-between;gap:16px;font-size:13px;line-height:1.45}',
          '.stargate-rule-status-row span{opacity:.72}',
          '.stargate-rule-status-row strong{font-weight:600;text-align:right}',
          '.stargate-rule-ok{padding:8px 10px;border-radius:6px;background:rgba(46,160,67,.16);color:#9fd49f}'
        ].join('')),
        E('div', { 'class': 'stargate-rule-action-row' }, [
          E('button', {
            'class': 'btn cbi-button cbi-button-apply',
            'click': ui.createHandlerFn(this, function(ev) {
              var container = ev.currentTarget.closest('.stargate-rule-actions');
              return fs.exec('/usr/share/stargate/stargate.sh', [ 'rules-update' ])
                .then(function() {
                  return fs.exec_direct('/usr/share/stargate/stargate.sh', [ 'rules-status' ]);
                })
                .then(function(text) {
                  var old = container.querySelector('.stargate-rule-status');
                  old.parentNode.replaceChild(statusView(text, _('Rules updated successfully.')), old);
                })
                .catch(function(err) { ui.addNotification(null, E('pre', {}, err.message), 'danger'); });
            })
          }, [ _('Update base rules') ]),
          E('button', {
            'class': 'btn cbi-button',
            'click': ui.createHandlerFn(this, function(ev) {
              var container = ev.currentTarget.closest('.stargate-rule-actions');
              return fs.exec_direct('/usr/share/stargate/stargate.sh', [ 'rules-status' ])
                .then(function(text) {
                  var old = container.querySelector('.stargate-rule-status');
                  old.parentNode.replaceChild(statusView(text, _('Rule status refreshed.')), old);
                });
            })
          }, [ _('Refresh status') ])
        ]),
        statusView(status)
      ]);
    };
    actions.depends('mode', 'blacklist');
    actions.depends('mode', 'whitelist');

    var privateDirect = s.option(form.Flag, 'private_direct', _('Private IP direct'));
    privateDirect.default = '1';
    privateDirect.rmempty = false;

    var blockQuic = s.option(form.Flag, 'block_quic', _('Block QUIC'));
    blockQuic.default = '0';
    blockQuic.rmempty = false;

    return m.render();
  }
});
