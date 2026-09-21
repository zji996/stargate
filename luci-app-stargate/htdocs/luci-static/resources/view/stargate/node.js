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

    // Dedicated ports only. Nodes themselves are added, edited and removed
    // through the backend actions so validation stays in one place.
    var n = m.section(form.GridSection, 'node_item', _('Dedicated proxy ports'));
    n.description = _('Give a node its own LAN SOCKS/HTTP port. Domestic and private destinations still go direct; proxied traffic from that port uses this node. Listening on 0.0.0.0 exposes the port on every interface, so keep WAN input closed in the firewall.');
    n.anonymous = false;
    n.addremove = false;

    var nLabel = n.option(form.DummyValue, 'label', _('Label'));
    var nServer = n.option(form.DummyValue, 'server', _('Server'));
    var nPort = n.option(form.DummyValue, 'server_port', _('Port'));

    var nEnablePort = n.option(form.Flag, 'enable_port', _('Dedicated port'));
    nEnablePort.default = '0';
    nEnablePort.rmempty = false;

    var nSocksPort = n.option(form.Value, 'socks_port', _('SOCKS port'));
    nSocksPort.datatype = 'port';
    nSocksPort.placeholder = '10818';
    nSocksPort.depends('enable_port', '1');

    var nHttpPort = n.option(form.Value, 'http_port', _('HTTP port'));
    nHttpPort.datatype = 'port';
    nHttpPort.placeholder = '10819';
    nHttpPort.depends('enable_port', '1');

    var nListen = n.option(form.Value, 'listen', _('Listen address'));
    nListen.datatype = 'ipaddr';
    nListen.default = '0.0.0.0';
    nListen.depends('enable_port', '1');

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
