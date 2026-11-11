def proxied:
  (.protocol|endswith("-tls")) and (.external_tls|not);
def external_http: (.protocol|endswith("-tls")) and .external_tls;
def native_tls:
  .protocol|IN("trojan","hysteria2","tuic","anytls","vmess-quic");
def certificate($state; $id):
  first($state.certificates[]|select(.id==$id)) // error("certificate reference missing");
def server_tls($state):
  certificate($state;.certificate_id) as $c |
  {enabled:true,certificate_path:($c.version_dir+"/fullchain.pem"),key_path:($c.version_dir+"/privkey.pem")};
def transport:
  if .protocol|test("-(ws|h2|httpupgrade)-tls$") then
    {type:(.protocol|split("-")|.[1]|if .=="h2" then "http" else . end),path:.path} +
    (if .protocol|test("-ws-") then {headers:{Host:.domain}}
     elif .protocol|test("-h2-") then {host:[.domain]} else {host:.domain} end)
  elif .protocol=="vmess-ws" then {type:"ws",path:.path}
  elif .protocol=="vmess-http" then {type:"http",path:.path}
  elif .protocol=="vmess-quic" then {type:"quic"}
  elif .protocol=="vless-http2-reality" then {type:"http",host:[.reality.sni],path:.path}
  else null end;
def inbound($state):
  . as $n |
  {tag:("in-"+.id),listen:(if proxied or external_http then "127.0.0.1" else .listen end),
   listen_port:(if proxied or external_http then .backend_port else .port end)} +
  (if .protocol|startswith("vmess-") then {type:"vmess",users:[{name:.id,uuid:.uuid,alterId:0}]}
   elif .protocol|startswith("vless-") then {type:"vless",users:[{name:.id,uuid:.uuid,flow:(if .protocol=="vless-reality" then "xtls-rprx-vision" else "" end)}]}
   elif .protocol|startswith("trojan") then {type:"trojan",users:[{name:.id,password:.password}]}
   elif .protocol=="shadowsocks" then {type:"shadowsocks",method:.method,password:.password}
   elif .protocol=="socks" then {type:"socks",users:[{username:.username,password:.password}]}
   elif .protocol=="tuic" then {type:"tuic",users:[{name:.id,uuid:.uuid,password:.password}],congestion_control:"bbr"}
   elif .protocol=="hysteria2" then {type:"hysteria2",users:[{name:.id,password:.password}]}
   elif .protocol=="anytls" then {type:"anytls",users:[{name:.id,password:.password}]}
   elif .protocol=="direct" then {type:"direct",override_address:.target_server,override_port:.target_port}
   else error("unknown inbound protocol") end) +
  (if .protocol|contains("reality") then
    {tls:{enabled:true,server_name:.reality.sni,reality:{enabled:true,handshake:{server:.reality.sni,server_port:443},private_key:.reality.private_key,short_id:[.reality.short_id]}}}
   elif native_tls then {tls:server_tls($state)} + (if .protocol|IN("tuic","hysteria2","vmess-quic") then {tls:(server_tls($state)+{alpn:["h3"]})} else {} end)
   else {} end) +
  (transport as $t|if $t==null then {} else {transport:$t} end);
def client_outbound($state):
  . as $n | inbound($state) |
  {type:.type,server:$n.address,server_port:$n.port} +
  (if .type=="vmess" then {uuid:$n.uuid,security:"auto"}
   elif .type=="vless" then {uuid:$n.uuid,flow:.users[0].flow}
   elif .type=="shadowsocks" then {method:$n.method,password:$n.password}
   elif .type=="socks" then {version:"5",username:$n.username,password:$n.password}
   elif .type=="tuic" then {uuid:$n.uuid,password:$n.password,congestion_control:"bbr",udp_relay_mode:"native"}
   elif .type|IN("trojan","hysteria2","anytls") then {password:$n.password}
   else error("forwarding inbound has no universal share URL") end) +
  (if $n.protocol|contains("reality") then
    {tls:{enabled:true,server_name:$n.reality.sni,utls:{enabled:true,fingerprint:"chrome"},reality:{enabled:true,public_key:$n.reality.public_key,short_id:$n.reality.short_id}}}
   elif ($n|native_tls or proxied or external_http) then
    {tls:{enabled:true,server_name:$n.domain,insecure:(if $n.external_tls then false else (certificate($state;$n.certificate_id).self_signed//false) end)}} +
    (if $n.protocol|IN("hysteria2","tuic","vmess-quic") then {tls:{enabled:true,server_name:$n.domain,insecure:(certificate($state;$n.certificate_id).self_signed//false),alpn:["h3"]}} else {} end)
   else {} end) +
  (if .transport then {transport:.transport} else {} end);
def dns_servers:
  if .settings.dns.type=="local" then [{type:"local",tag:"dns"}]
  else [(.settings.dns+{tag:"dns",domain_resolver:"bootstrap"}),{type:"local",tag:"bootstrap"}] end;
# The core's ip_is_private does not cover shared-address space or all special
# purpose ranges. Block these locally before selecting any node's outbound.
def special_destination_ranges:
  ["0.0.0.0/8","100.64.0.0/10","192.0.0.0/24","192.0.2.0/24",
   "192.88.99.0/24","198.18.0.0/15","198.51.100.0/24","203.0.113.0/24",
   "224.0.0.0/4","240.0.0.0/4","::/96","64:ff9b:1::/48","100::/64",
   "2001:2::/48","2001:10::/28","2001:20::/28","2001:db8::/32",
   "3fff::/20","fec0::/10"];
def config($root):
  . as $state |
  {log:{level:.settings.log_level,timestamp:true},
   dns:{servers:dns_servers,final:"dns"},
   inbounds:[.nodes[]|inbound($state)],
   outbounds:(if (.nodes|length)>0 then [.nodes[]|.outbound+{tag:("out-"+.id)}] else [{type:"direct",tag:"unused"}] end),
   route:{default_domain_resolver:"dns",rule_set:[{type:"local",tag:"geoip-cn",format:"binary",path:($root+"/rules/geoip-cn.srs")}],
     rules:([{action:"sniff",timeout:"300ms"},{action:"resolve",server:"dns"},
             {protocol:["bittorrent"],action:"reject"},{ip_is_private:true,action:"reject"},
             {ip_cidr:special_destination_ranges,action:"reject"},
             {rule_set:["geoip-cn"],action:"reject"}]+
            [.nodes[]|{inbound:[("in-"+.id)],action:"route",outbound:("out-"+.id)}]+[{action:"reject"}])}};
def valid_state:
  .schema_version==1 and (.nodes|type)=="array" and
  all(.nodes[];
    (.id|test("^n-[a-f0-9]{16}$")) and (.port|type)=="number" and .port>=1 and .port<=65535 and
    (.backend_port|type)=="number" and (.outbound|type)=="object" and
    (.outbound.type|IN("direct","shadowsocks","vless","vmess","trojan","hysteria2","tuic","anytls","socks"))) and
  ([.nodes[].id]|length)==([.nodes[].id]|unique|length) and
  ([.nodes[].port]|length)==([.nodes[].port]|unique|length);
