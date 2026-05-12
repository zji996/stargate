m = Map("stargate", translate("DNS"))

s = m:section(NamedSection, "dns", "dns", translate("DNS policy"))
s.anonymous = true

mode = s:option(ListValue, "mode", translate("Mode"))
mode:value("tcp_doh", translate("TCP direct + DoH remote"))
mode.default = "tcp_doh"
mode.description = translate("Recommended: direct domains use domestic TCP DNS; domains matched by proxy rules use remote DoH through the selected node.")

strategy = s:option(ListValue, "strategy", translate("Strategy"))
strategy:value("prefer_ipv4", "prefer_ipv4")
strategy:value("prefer_ipv6", "prefer_ipv6")
strategy:value("ipv4_only", "ipv4_only")
strategy:value("ipv6_only", "ipv6_only")
strategy.default = "prefer_ipv4"

local_preset = s:option(ListValue, "local_preset", translate("Direct DNS server"))
local_preset:value("alidns_tcp", translate("AliDNS TCP (recommended)"))
local_preset:value("dnspod_tcp", translate("DNSPod TCP"))
local_preset:value("onedns_tcp", translate("114DNS TCP"))
local_preset:value("custom", translate("Custom"))
local_preset.default = "alidns_tcp"
local_preset.description = translate("Used for direct domains and for resolving the proxy server domain before the tunnel is up.")

local_type = s:option(ListValue, "local_type", translate("Custom direct DNS transport"))
local_type:value("tcp", "TCP")
local_type:value("udp", "UDP")
local_type:value("tls", "TLS")
local_type:value("https", "DoH")
local_type.default = "tcp"
local_type:depends("local_preset", "custom")

local_server = s:option(Value, "local_server", translate("Custom direct DNS server"))
local_server.default = "223.5.5.5"
local_server:depends("local_preset", "custom")

local_path = s:option(Value, "local_path", translate("Custom direct DoH path"))
local_path.default = "/dns-query"
local_path:depends({ local_preset = "custom", local_type = "https" })

remote_preset = s:option(ListValue, "remote_preset", translate("Remote DNS server"))
remote_preset:value("google_doh", translate("Google DoH (recommended)"))
remote_preset:value("quad9_doh", translate("Quad9 DoH"))
remote_preset:value("cloudflare_doh", translate("Cloudflare DoH"))
remote_preset:value("cloudflare_security_doh", translate("Cloudflare Security DoH"))
remote_preset:value("custom", translate("Custom"))
remote_preset.default = "google_doh"
remote_preset.description = translate("Used for domains matched by proxy rules. Presets avoid protocol and path mismatches that often make DNS fail silently.")

remote_type = s:option(ListValue, "remote_type", translate("Custom remote DNS transport"))
remote_type:value("https", "DoH")
remote_type:value("tls", "DoT")
remote_type:value("tcp", "TCP")
remote_type:value("udp", "UDP")
remote_type.default = "https"
remote_type:depends("remote_preset", "custom")

remote_server = s:option(Value, "remote_server", translate("Custom remote DNS server"))
remote_server.default = "dns.google"
remote_server:depends("remote_preset", "custom")

remote_path = s:option(Value, "remote_path", translate("DoH path"))
remote_path.default = "/dns-query"
remote_path:depends({ remote_preset = "custom", remote_type = "https" })

final = s:option(ListValue, "final", translate("Final resolver"))
final:value("remote-doh", translate("Remote"))
final:value("direct-dns", translate("Direct"))
final:value("local", translate("System local"))
final.default = "direct-dns"
final.description = translate("Recommended: Direct. Proxy rule matches still use Remote automatically; Direct only controls the fallback resolver.")

hijack_dns = s:option(Flag, "hijack_dns", translate("DNS redirect"))
hijack_dns.description = translate("Force managed devices to use Stargate DNS when transparent proxy firewall rules are applied.")
hijack_dns.default = "1"
hijack_dns.rmempty = false

hijack_port = s:option(Value, "hijack_port", translate("DNS redirect port"))
hijack_port.default = "1053"
hijack_port.datatype = "port"
hijack_port:depends("hijack_dns", "1")

return m
