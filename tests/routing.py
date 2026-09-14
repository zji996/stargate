"""Regression cases for DNS, route priority and unresolved destination handling."""
import ipaddress
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])


def match(rule, domain, ip):
    if 'inbound' in rule or 'network' in rule:
        return False
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


def decision(rules, field, domain, ip='', resolved_ip=''):
    for rule in rules:
        if match(rule, domain, ip):
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
    if mode in ('global_proxy', 'direct'):
        # Fixed modes ignore custom and base rules, including GeoIP supplements.
        assert 'Outbound: ' + route['final'] in (root / (mode + '.ip.txt')).read_text()
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
print('routing regressions passed')
