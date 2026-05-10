m = Map("stargate", translate("DNS"))

s = m:section(NamedSection, "dns", "dns", translate("DNS policy"))
s.anonymous = true

mode = s:option(ListValue, "mode", translate("Mode"))
mode:value("tcp_doh", translate("TCP direct + DoH remote"))
mode.default = "tcp_doh"

strategy = s:option(ListValue, "strategy", translate("Strategy"))
strategy:value("prefer_ipv4", "prefer_ipv4")
strategy:value("prefer_ipv6", "prefer_ipv6")
strategy:value("ipv4_only", "ipv4_only")
strategy:value("ipv6_only", "ipv6_only")
strategy.default = "prefer_ipv4"

local_type = s:option(ListValue, "local_type", translate("Direct DNS transport"))
local_type:value("tcp", "TCP")
local_type:value("udp", "UDP")
local_type:value("tls", "TLS")
local_type:value("https", "DoH")
local_type.default = "tcp"

local_server = s:option(Value, "local_server", translate("Direct DNS server"))
local_server.default = "223.5.5.5"

remote_type = s:option(ListValue, "remote_type", translate("Remote DNS transport"))
remote_type:value("https", "DoH")
remote_type:value("tls", "DoT")
remote_type:value("tcp", "TCP")
remote_type:value("udp", "UDP")
remote_type.default = "https"

remote_server = s:option(Value, "remote_server", translate("Remote DNS server"))
remote_server.default = "1.1.1.1"

remote_path = s:option(Value, "remote_path", translate("DoH path"))
remote_path.default = "/dns-query"
remote_path:depends("remote_type", "https")

final = s:option(ListValue, "final", translate("Final resolver"))
final:value("remote-doh", translate("Remote"))
final:value("direct-dns", translate("Direct"))
final:value("local", translate("System local"))
final.default = "remote-doh"

hijack_dns = s:option(Flag, "hijack_dns", translate("DNS hijack"))
hijack_dns.default = "0"
hijack_dns.rmempty = false

return m
