m = Map("stargate", translate("Node"))

s = m:section(NamedSection, "node", "node", translate("Primary node"))
s.anonymous = true

type = s:option(ListValue, "type", translate("Type"))
type:value("anytls", "AnyTLS")
type.default = "anytls"

label = s:option(Value, "label", translate("Label"))
label.default = "primary"

server = s:option(Value, "server", translate("Server"))
server.placeholder = "example.com"
server.rmempty = false

port = s:option(Value, "server_port", translate("Port"))
port.datatype = "port"
port.default = "443"

password = s:option(Value, "password", translate("Password"))
password.password = true
password.rmempty = false

sni = s:option(Value, "sni", translate("SNI"))
sni.placeholder = "example.com"

insecure = s:option(Flag, "insecure", translate("Allow insecure TLS"))
insecure.default = "1"
insecure.rmempty = false

i = m:section(NamedSection, "inbound", "inbound", translate("Local inbound"))
i.anonymous = true

socks_listen = i:option(Value, "socks_listen", translate("SOCKS listen"))
socks_listen.default = "127.0.0.1"

socks_port = i:option(Value, "socks_port", translate("SOCKS port"))
socks_port.datatype = "port"
socks_port.default = "10808"

http_listen = i:option(Value, "http_listen", translate("HTTP listen"))
http_listen.default = "127.0.0.1"

http_port = i:option(Value, "http_port", translate("HTTP port"))
http_port.datatype = "port"
http_port.default = "10809"

return m
