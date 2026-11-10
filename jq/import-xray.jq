if ((.routing.rules//[])|length)>0 or ((.outbounds//[])|any(.protocol!="freedom")) then error("complex routing") else . end |
.inbounds[0] as $i |
if ($i|all(keys[];IN("protocol","tag","listen","port","settings","streamSettings")))|not then error("unsupported inbound field") else . end |
if (($i.settings.clients//[])|length)>1 or (($i.settings.accounts//[])|length)>1 then error("multiple users") else . end |
($i.streamSettings//{}) as $s |
if ($s|all(keys[];IN("network","security","tlsSettings","realitySettings","wsSettings","httpSettings","httpupgradeSettings","tcpSettings")))|not then error("unsupported stream option") else . end |
if (($s.tcpSettings.header.type//"none")!="none") or (($s.tlsSettings.allowInsecure//false)==true) or (($i.settings.udp//true)==false) then error("unsupported behavior") else . end |
($s.network//"tcp") as $net |
{
 inbounds:[{
   type:($i.protocol|if .=="dokodemo-door" then "direct" else . end),listen:($i.listen//"::"),listen_port:$i.port,
   users:(if $i.protocol=="socks" then [{username:$i.settings.accounts[0].user,password:$i.settings.accounts[0].pass}]
     elif $i.protocol=="trojan" then [{password:$i.settings.clients[0].password}]
     elif $i.protocol=="vless" or $i.protocol=="vmess" then [{uuid:$i.settings.clients[0].id,flow:($i.settings.clients[0].flow//"")}]
     else [] end)
 } + (if $i.protocol=="shadowsocks" then {method:$i.settings.method,password:$i.settings.password} else {} end)
   + (if $i.protocol=="dokodemo-door" then {override_address:$i.settings.address,override_port:$i.settings.port} else {} end)
   + (if $net=="tcp" then {}
      elif $net=="ws" then {transport:{type:"ws",path:($s.wsSettings.path//"/"),headers:($s.wsSettings.headers//{})}}
      elif $net=="http" or $net=="h2" then {transport:{type:"http",host:($s.httpSettings.host//[]),path:($s.httpSettings.path//"/")}}
      elif $net=="httpupgrade" then {transport:{type:"httpupgrade",host:($s.httpupgradeSettings.host//""),path:($s.httpupgradeSettings.path//"/")}}
      else error("unsupported transport") end)
   + (if $s.security=="reality" then {tls:{enabled:true,server_name:$s.realitySettings.serverNames[0],reality:{enabled:true,private_key:$s.realitySettings.privateKey,short_id:($s.realitySettings.shortIds//[""]),handshake:{server:$s.realitySettings.serverNames[0],server_port:443}}}}
      elif $s.security=="tls" then {tls:{enabled:true,server_name:($s.tlsSettings.serverName//""),certificate_path:$s.tlsSettings.certificates[0].certificateFile,key_path:$s.tlsSettings.certificates[0].keyFile}}
      elif ($s.security//"none")=="none" then {} else error("unsupported TLS") end)
 ],outbounds:[{type:"direct"}]
}
