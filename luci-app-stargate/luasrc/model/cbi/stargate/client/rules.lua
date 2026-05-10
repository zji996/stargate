m = Map("stargate", translate("Rules"))

s = m:section(NamedSection, "rules", "rules", translate("GFW based routing"))
s.anonymous = true

mode = s:option(ListValue, "mode", translate("Mode"))
mode:value("gfw", translate("GFW list"))
mode:value("global_proxy", translate("Global proxy"))
mode:value("direct", translate("Direct only"))
mode.default = "gfw"

gfw_rule_set = s:option(Value, "gfw_rule_set", translate("GFW rule-set path"))
gfw_rule_set.default = "/usr/share/stargate/rules/gfw.json"
gfw_rule_set:depends("mode", "gfw")

gfw_outbound = s:option(ListValue, "gfw_outbound", translate("GFW outbound"))
gfw_outbound:value("anytls-out", translate("Proxy"))
gfw_outbound:value("direct", translate("Direct"))
gfw_outbound.default = "anytls-out"
gfw_outbound:depends("mode", "gfw")

default_outbound = s:option(ListValue, "default_outbound", translate("Default outbound"))
default_outbound:value("direct", translate("Direct"))
default_outbound:value("anytls-out", translate("Proxy"))
default_outbound.default = "direct"

private_direct = s:option(Flag, "private_direct", translate("Private IP direct"))
private_direct.default = "1"
private_direct.rmempty = false

block_quic = s:option(Flag, "block_quic", translate("Block QUIC"))
block_quic.default = "0"
block_quic.rmempty = false

return m
