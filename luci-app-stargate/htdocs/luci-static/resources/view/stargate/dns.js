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

    var strategy = s.option(form.ListValue, 'strategy', _('Strategy'));
    strategy.value('prefer_ipv4', 'prefer_ipv4');
    strategy.value('prefer_ipv6', 'prefer_ipv6');
    strategy.value('ipv4_only', 'ipv4_only');
    strategy.value('ipv6_only', 'ipv6_only');
    strategy.default = 'prefer_ipv4';

    var localType = s.option(form.ListValue, 'local_type', _('Direct DNS transport'));
    localType.value('tcp', 'TCP');
    localType.value('udp', 'UDP');
    localType.value('tls', 'TLS');
    localType.value('https', 'DoH');
    localType.default = 'tcp';

    var localServer = s.option(form.Value, 'local_server', _('Direct DNS server'));
    localServer.default = '223.5.5.5';

    var remoteType = s.option(form.ListValue, 'remote_type', _('Remote DNS transport'));
    remoteType.value('https', 'DoH');
    remoteType.value('tls', 'DoT');
    remoteType.value('tcp', 'TCP');
    remoteType.value('udp', 'UDP');
    remoteType.default = 'https';

    var remoteServer = s.option(form.Value, 'remote_server', _('Remote DNS server'));
    remoteServer.default = '1.1.1.1';

    var remotePath = s.option(form.Value, 'remote_path', _('DoH path'));
    remotePath.default = '/dns-query';
    remotePath.depends('remote_type', 'https');

    var final = s.option(form.ListValue, 'final', _('Final resolver'));
    final.value('remote-doh', _('Remote'));
    final.value('direct-dns', _('Direct'));
    final.value('local', _('System local'));
    final.default = 'remote-doh';

    var hijack = s.option(form.Flag, 'hijack_dns', _('DNS hijack'));
    hijack.default = '0';
    hijack.rmempty = false;

    return m.render();
  }
});
