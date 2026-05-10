'use strict';
'require view';
'require form';

return view.extend({
  render: function() {
    var m = new form.Map('stargate', _('Node'));

    m.description = _('Manage a small AnyTLS node list. Use a node to copy it into the active sing-box config.');

    var s = m.section(form.NamedSection, 'node', 'node', _('Active node'));
    s.anonymous = true;

    var type = s.option(form.ListValue, 'type', _('Type'));
    type.value('anytls', 'AnyTLS');
    type.default = 'anytls';

    var label = s.option(form.Value, 'label', _('Label'));
    label.default = 'primary';

    var server = s.option(form.Value, 'server', _('Server'));
    server.placeholder = 'example.com';
    server.rmempty = false;

    var port = s.option(form.Value, 'server_port', _('Port'));
    port.datatype = 'port';
    port.default = '443';

    var password = s.option(form.Value, 'password', _('Password'));
    password.password = true;
    password.rmempty = false;

    var sni = s.option(form.Value, 'sni', _('SNI'));
    sni.placeholder = 'example.com';

    var insecure = s.option(form.Flag, 'insecure', _('Allow insecure TLS'));
    insecure.default = '1';
    insecure.rmempty = false;

    var i = m.section(form.NamedSection, 'inbound', 'inbound', _('Local inbound'));
    i.anonymous = true;

    var socksListen = i.option(form.Value, 'socks_listen', _('SOCKS listen'));
    socksListen.default = '127.0.0.1';
    var socksPort = i.option(form.Value, 'socks_port', _('SOCKS port'));
    socksPort.datatype = 'port';
    socksPort.default = '10808';

    var httpListen = i.option(form.Value, 'http_listen', _('HTTP listen'));
    httpListen.default = '127.0.0.1';
    var httpPort = i.option(form.Value, 'http_port', _('HTTP port'));
    httpPort.datatype = 'port';
    httpPort.default = '10809';

    return m.render();
  }
});
