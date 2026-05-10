'use strict';
'require view';
'require form';

return view.extend({
  render: function() {
    var m = new form.Map('stargate', _('Rules'));

    var s = m.section(form.NamedSection, 'rules', 'rules', _('GFW based routing'));
    s.anonymous = true;

    var mode = s.option(form.ListValue, 'mode', _('Mode'));
    mode.value('gfw', _('GFW list'));
    mode.value('global_proxy', _('Global proxy'));
    mode.value('direct', _('Direct only'));
    mode.default = 'gfw';

    var set = s.option(form.Value, 'gfw_rule_set', _('GFW rule-set path'));
    set.default = '/usr/share/stargate/rules/gfw.json';
    set.depends('mode', 'gfw');

    var gfwOutbound = s.option(form.ListValue, 'gfw_outbound', _('GFW outbound'));
    gfwOutbound.value('anytls-out', _('Proxy'));
    gfwOutbound.value('direct', _('Direct'));
    gfwOutbound.default = 'anytls-out';
    gfwOutbound.depends('mode', 'gfw');

    var final = s.option(form.ListValue, 'default_outbound', _('Default outbound'));
    final.value('direct', _('Direct'));
    final.value('anytls-out', _('Proxy'));
    final.default = 'direct';

    var privateDirect = s.option(form.Flag, 'private_direct', _('Private IP direct'));
    privateDirect.default = '1';
    privateDirect.rmempty = false;

    var blockQuic = s.option(form.Flag, 'block_quic', _('Block QUIC'));
    blockQuic.default = '0';
    blockQuic.rmempty = false;

    return m.render();
  }
});
