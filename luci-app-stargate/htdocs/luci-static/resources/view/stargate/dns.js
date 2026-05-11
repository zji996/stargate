'use strict';
'require view';
'require form';

return view.extend({
  render: function() {
    var m = new form.Map('stargate', _('DNS'));

    var s = m.section(form.NamedSection, 'dns', 'dns', _('DNS policy'));
    s.anonymous = true;

    var mode = s.option(form.ListValue, 'mode', _('Mode'));
    mode.value('tcp_doh', _('TCP direct + DoH remote'));
    mode.default = 'tcp_doh';
    mode.description = _('Recommended: direct domains use domestic TCP DNS; domains matched by proxy rules use remote DoH through the selected node.');

    var strategy = s.option(form.ListValue, 'strategy', _('Strategy'));
    strategy.value('prefer_ipv4', 'prefer_ipv4');
    strategy.value('prefer_ipv6', 'prefer_ipv6');
    strategy.value('ipv4_only', 'ipv4_only');
    strategy.value('ipv6_only', 'ipv6_only');
    strategy.default = 'prefer_ipv4';

    var localPreset = s.option(form.ListValue, 'local_preset', _('Direct DNS server'));
    localPreset.value('alidns_tcp', _('AliDNS TCP (recommended)'));
    localPreset.value('dnspod_tcp', _('DNSPod TCP'));
    localPreset.value('onedns_tcp', _('114DNS TCP'));
    localPreset.value('custom', _('Custom'));
    localPreset.default = 'alidns_tcp';
    localPreset.description = _('Used for direct domains and for resolving the proxy server domain before the tunnel is up.');

    var localType = s.option(form.ListValue, 'local_type', _('Custom direct DNS transport'));
    localType.value('tcp', 'TCP');
    localType.value('udp', 'UDP');
    localType.value('tls', 'TLS');
    localType.value('https', 'DoH');
    localType.default = 'tcp';
    localType.depends('local_preset', 'custom');

    var localServer = s.option(form.Value, 'local_server', _('Custom direct DNS server'));
    localServer.default = '223.5.5.5';
    localServer.depends('local_preset', 'custom');

    var localPath = s.option(form.Value, 'local_path', _('Custom direct DoH path'));
    localPath.default = '/dns-query';
    localPath.depends({ local_preset: 'custom', local_type: 'https' });

    var remotePreset = s.option(form.ListValue, 'remote_preset', _('Remote DNS server'));
    remotePreset.value('quad9_doh', _('Quad9 DoH (recommended)'));
    remotePreset.value('cloudflare_doh', _('Cloudflare DoH'));
    remotePreset.value('cloudflare_security_doh', _('Cloudflare Security DoH'));
    remotePreset.value('google_doh', _('Google DoH'));
    remotePreset.value('custom', _('Custom'));
    remotePreset.default = 'quad9_doh';
    remotePreset.description = _('Used for domains matched by proxy rules. Presets avoid protocol and path mismatches that often make DNS fail silently.');

    var remoteType = s.option(form.ListValue, 'remote_type', _('Custom remote DNS transport'));
    remoteType.value('https', 'DoH');
    remoteType.value('tls', 'DoT');
    remoteType.value('tcp', 'TCP');
    remoteType.value('udp', 'UDP');
    remoteType.default = 'https';
    remoteType.depends('remote_preset', 'custom');

    var remoteServer = s.option(form.Value, 'remote_server', _('Custom remote DNS server'));
    remoteServer.default = '9.9.9.9';
    remoteServer.depends('remote_preset', 'custom');

    var remotePath = s.option(form.Value, 'remote_path', _('DoH path'));
    remotePath.default = '/dns-query';
    remotePath.depends({ remote_preset: 'custom', remote_type: 'https' });

    var final = s.option(form.ListValue, 'final', _('Final resolver'));
    final.value('remote-doh', _('Remote'));
    final.value('direct-dns', _('Direct'));
    final.value('local', _('System local'));
    final.default = 'direct-dns';
    final.description = _('Recommended: Direct. Proxy rule matches still use Remote automatically; Direct only controls the fallback resolver.');

    var hijack = s.option(form.Flag, 'hijack_dns', _('DNS redirect'));
    hijack.description = _('Force managed devices to use Stargate DNS when transparent proxy firewall rules are applied.');
    hijack.default = '1';
    hijack.rmempty = false;

    var hijackPort = s.option(form.Value, 'hijack_port', _('DNS redirect port'));
    hijackPort.default = '1053';
    hijackPort.datatype = 'port';
    hijackPort.depends('hijack_dns', '1');

    return m.render();
  }
});
