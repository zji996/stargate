"""Regression cases for DNS, route priority and unresolved destination handling."""
import ipaddress
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])


def match(rule, domain, ip, inbound_tag=None):
    if 'network' in rule:
        return False
    if 'inbound' in rule:
        if not inbound_tag or inbound_tag not in rule['inbound']:
            return False
    elif inbound_tag:
        # If rule doesn't specify inbound, it matches all inbounds
        pass
    if 'ip_is_private' in rule:
        return bool(ip) and any(ipaddress.ip_address(ip) in ipaddress.ip_network(c) for c in
                                ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '127.0.0.0/8'))
    if 'domain_suffix' in rule or 'domain_regex' in rule:
        return any(domain == s or domain.endswith('.' + s) for s in rule.get('domain_suffix', [])) or any(
            re.search(p, domain) for p in rule.get('domain_regex', [])
        )
    if 'ip_cidr' in rule:
        return bool(ip) and any(ipaddress.ip_address(ip) in ipaddress.ip_network(c) for c in rule['ip_cidr'])
    if 'rule_set' in rule:
        # A domain that appears in both real source lists, plus user override cases.
        domains = {
            'proxy': {'www.gstatic.com', 'force-direct.example'},
            'direct': {'www.gstatic.com', 'force-proxy.example', 'baidu.com'},
        }
        return domain in domains.get(rule['rule_set'], set())
    return True


def decision(rules, field, domain, ip='', resolved_ip='', inbound_tag=None):
    for rule in rules:
        if match(rule, domain, ip, inbound_tag=inbound_tag):
            if rule.get('action') == 'resolve':
                ip = ip or resolved_ip
            elif field in rule:
                return rule[field]
    return None


for mode in ('blacklist', 'whitelist', 'global_proxy', 'direct'):
    config = json.loads((root / (mode + '.json')).read_text())
    dns, route = config['dns'], config['route']
    assert dns['final'] == ('remote-doh' if mode in ('whitelist', 'global_proxy') else 'direct-dns')
    assert route['final'] == ('anytls-out' if mode in ('whitelist', 'global_proxy') else 'direct')
    inbound = next(i for i in config['inbounds'] if i['tag'] == 'dns-in')
    assert inbound['listen'] == '0.0.0.0'
    inbound6 = next(i for i in config['inbounds'] if i['tag'] == 'dns6-in')
    assert inbound6['listen'] == 'fd00::1'
    lan_dns = next(s for s in dns['servers'] if s['tag'] == 'lan-dns')
    assert (lan_dns['server'], lan_dns['server_port'], lan_dns['type']) == ('127.0.0.1', 53, 'tcp')
    for domain in ('printer.lan', 'printer', '7.0.0.10.in-addr.arpa'):
        assert decision(dns['rules'], 'server', domain) == 'lan-dns'
        assert decision(route['rules'], 'outbound', domain) == 'direct'
    assert 'Outbound: direct' in (root / (mode + '.local.txt')).read_text()

    def route_of(domain, ip='', resolved_ip='', inbound_tag=None):
        """Route decision including the final fallback."""
        picked = decision(route['rules'], 'outbound', domain, ip, resolved_ip, inbound_tag)
        return route['final'] if picked is None else picked

    # Dedicated-port nodes: inbounds exist for every enabled node, outbounds
    # only for nodes that differ from the active node.
    inbound_tags = {i['tag'] for i in config['inbounds']}
    outbound_tags = {o['tag'] for o in config['outbounds']}
    assert next(i for i in config['inbounds'] if i['tag'] == 'in-socks-node_jp')['listen_port'] == 10818
    assert next(i for i in config['inbounds'] if i['tag'] == 'in-http-node_jp')['listen_port'] == 10819
    assert next(i for i in config['inbounds'] if i['tag'] == 'in-socks-node_us')['listen_port'] == 10828
    assert next(i for i in config['inbounds'] if i['tag'] == 'in-socks-node_main')['listen_port'] == 10838
    assert 'in-http-node_main' not in inbound_tags
    assert not any(t.endswith('node_off') for t in inbound_tags | outbound_tags)
    assert not any('@' in t for t in inbound_tags | outbound_tags)
    assert {'out-node-node_jp', 'out-node-node_us'} <= outbound_tags
    assert 'out-node-node_main' not in outbound_tags
    jp_out = next(o for o in config['outbounds'] if o['tag'] == 'out-node-node_jp')
    assert (jp_out['server'], jp_out['password']) == ('jp.example.com', 'jp-pass')
    # Tags referenced by rules must all exist.
    for rule in route['rules']:
        for tag in rule.get('inbound', []):
            assert tag in inbound_tags, tag
        if 'outbound' in rule:
            assert rule['outbound'] in outbound_tags, rule
    assert route['final'] in outbound_tags
    # The main-node alias never gets scoped rules; the unscoped rules cover it.
    assert not any('in-socks-node_main' in rule.get('inbound', []) for rule in route['rules'])

    if mode in ('global_proxy', 'direct'):
        # Fixed modes ignore custom and base rules, including GeoIP supplements.
        assert 'Outbound: ' + route['final'] in (root / (mode + '.ip.txt')).read_text()
        for tag in ('in-socks-node_jp', 'in-http-node_jp'):
            expected = 'out-node-node_jp' if mode == 'global_proxy' else 'direct'
            assert route_of('www.gstatic.com', inbound_tag=tag) == expected, (mode, tag)
            assert route_of('baidu.com', inbound_tag=tag) == expected, (mode, tag)
            assert route_of('printer.lan', inbound_tag=tag) == 'direct'
            assert route_of('x.example', '10.0.0.5', inbound_tag=tag) == 'direct'
        assert route_of('www.gstatic.com', inbound_tag='in-socks-node_main') == route['final']
        continue
    for domain, outbound, resolver in (
        ('www.gstatic.com', 'anytls-out', 'remote-doh'),
        ('both.example', 'direct', 'direct-dns'),
        ('force-direct.example', 'direct', 'direct-dns'),
        ('force-proxy.example', 'anytls-out', 'remote-doh'),
        ('baidu.com', 'direct', 'direct-dns'),
    ):
        assert decision(dns['rules'], 'server', domain) == resolver, (mode, domain, 'dns')
        assert decision(route['rules'], 'outbound', domain) == outbound, (mode, domain, 'route')
    # Explicit direct domains beat even known proxy IP supplements.
    assert decision(route['rules'], 'outbound', 'force-direct.example', '104.244.43.7') == 'direct'
    # Resolve must re-evaluate IP supplements; previously these fell through.
    assert decision(route['rules'], 'outbound', 'unlisted.example', resolved_ip='104.244.43.7') == 'anytls-out'
    for ip, outbound in (('198.51.100.7', 'direct'), ('203.0.113.7', 'anytls-out')):
        assert decision(route['rules'], 'outbound', 'unlisted.example', ip) == outbound
        assert decision(route['rules'], 'outbound', 'unlisted.example', resolved_ip=ip) == outbound

    # Multi-outbound routing by inbound tag.
    unmatched = 'out-node-node_jp' if mode == 'whitelist' else 'direct'
    for jp in ('in-socks-node_jp', 'in-http-node_jp'):
        # Direct rules are shared: LAN, private, user direct and base direct win everywhere.
        assert route_of('printer.lan', inbound_tag=jp) == 'direct'
        assert route_of('x.example', '10.0.0.5', inbound_tag=jp) == 'direct'
        assert route_of('both.example', inbound_tag=jp) == 'direct'
        assert route_of('force-direct.example', '104.244.43.7', inbound_tag=jp) == 'direct'
        assert route_of('baidu.com', inbound_tag=jp) == 'direct'
        assert route_of('unlisted.example', '198.51.100.7', inbound_tag=jp) == 'direct'
        # Proxy hits bind to the node behind the inbound.
        assert route_of('www.gstatic.com', inbound_tag=jp) == 'out-node-node_jp'
        assert route_of('force-proxy.example', inbound_tag=jp) == 'out-node-node_jp'
        assert route_of('unlisted.example', '203.0.113.7', inbound_tag=jp) == 'out-node-node_jp'
        assert route_of('unlisted.example', '104.244.43.7', inbound_tag=jp) == 'out-node-node_jp'
        # Resolve re-check keeps the inbound binding.
        assert route_of('unlisted.example', resolved_ip='104.244.43.7', inbound_tag=jp) == 'out-node-node_jp'
        assert route_of('unlisted.example', resolved_ip='203.0.113.7', inbound_tag=jp) == 'out-node-node_jp'
        assert route_of('unlisted.example', resolved_ip='198.51.100.7', inbound_tag=jp) == 'direct'
        assert route_of('unlisted.example', resolved_ip='10.0.0.5', inbound_tag=jp) == 'direct'
        # Unmatched traffic: blacklist direct, whitelist follows the node.
        assert route_of('unlisted.example', resolved_ip='192.0.2.9', inbound_tag=jp) == unmatched, (mode, jp)
    assert route_of('www.gstatic.com', inbound_tag='in-socks-node_us') == 'out-node-node_us'
    assert route_of('unlisted.example', resolved_ip='192.0.2.9', inbound_tag='in-socks-node_us') == (
        'out-node-node_us' if mode == 'whitelist' else 'direct')
    # Main inbounds and the main-node alias keep using anytls-out.
    for main in ('transparent-in', 'socks-in', 'http-in', 'in-socks-node_main'):
        assert route_of('www.gstatic.com', inbound_tag=main) == 'anytls-out', (mode, main)
        assert route_of('baidu.com', inbound_tag=main) == 'direct', (mode, main)
        assert route_of('unlisted.example', resolved_ip='192.0.2.9', inbound_tag=main) == (
            'anytls-out' if mode == 'whitelist' else 'direct'), (mode, main)
    # DNS rules are shared and unaffected by dedicated inbounds.
    assert not any('inbound' in rule for rule in dns['rules'])

print('routing regressions passed')
