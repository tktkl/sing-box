# 命令与协议兼容矩阵

参考：233boy/sing-box @ `6082f1bf70ed4550a5fbd5c9fe147ba5228189d5`。

## 命令

| 功能 | 参数或别名 | 行为 |
|---|---|---|
| 添加 | a/add | 交互终端按序号选协议；非交互无参数默认 REALITY |
| 修改 | c/change；full/id/host/port/path/passwd/key/method/sni/new/web/name/address/username | 永久 ID 不变；交互菜单只显示该协议可修改的字段 |
| 出口 | outbound；change NODE outbound | 每节点独立副本；省略链接从标准输入读取 |
| 查看 | i/info、list、url、qr | info/debug 脱敏，url/qr 显式显示分享凭据 |
| 删除 | d/del、dd/ddel | 单节点或多个唯一选择；不撤销共享证书 |
| 基础 | v/version、ip、pbk、get-port、ss2022、h/help | 保留快捷方式 |
| 生成 | gen、no-auto-tls | gen 不落盘或签发；no-auto-tls 后端只监听回环 |
| 全局 | dns、log、bbr | 明确全局影响；容器不修改 BBR |
| 服务 | s/status、start/stop/restart、t/test | nginx 参数管理现有 Nginx 服务 |
| 修复 | fix、fix-all、fix-config.json、fix-nginx | 从节点记录重建；不更换凭据 |
| 导入 | import | sing-box/Xray/V2Ray 已知单节点；默认预览 |
| 版本 | u/update、U/update.sh、reinstall | 有锁定兼容清单的 core，版本化脚本发布；共用旧 Nginx 必须由系统包管理器显式升级 |
| 删除安装 | un/uninstall | 删除项目服务/命令，保留数据和共用软件 |
| 透传 | bin；generate/check/format/completion/merge/rule-set/run/tools/geoip/geosite | 由锁定内核决定具体支持情况 |
| Caddy | fix-caddyfile、update caddy、restart caddy | 明确报错并提示替代，不静默改变语义 |
| 备份 | backup、restore | 排除 Token，恢复后标记续期缺少凭据 |

安装默认不创建节点，`--no-node` 继续兼容；仅 `--with-node` 显式创建初始 REALITY 节点。`sb` 打开循环菜单，`0` 返回，删除节点须确认。已有命令的位置参数和非交互行为保留，适合脚本调用。

`auto` 显式重新生成对应值；修改时未给出的字段沿用现有值。为避免凭据变动，常规改端口请用 `port` 而非 `full ... auto`。

## 入口

| 别名 | 规范协议 | 位置参数 | 证书 | Nginx |
|---|---|---|---|---|
| r/reality | vless-reality | port uuid sni | 无 | 无 |
| rh2 | vless-http2-reality | port uuid sni | 无 | 无 |
| ss | shadowsocks | port password method | 无 | 无 |
| tcp/http/ws | vmess-tcp/http/ws | port uuid | 无 | 无 |
| quic | vmess-quic | port uuid | 需要 | 无 |
| wss/h2/hu | vmess-ws/h2/httpupgrade-tls | domain uuid path | 需要 | 需要 |
| vws/vh2/vhu | vless-ws/h2/httpupgrade-tls | domain uuid path | 需要 | 需要 |
| tws/th2/thu | trojan-ws/h2/httpupgrade-tls | domain password path | 需要 | 需要 |
| trojan | trojan | port password | 需要 | 无 |
| hy/hy2 | hysteria2 | port password | 需要 | 无 |
| tuic | tuic | port uuid | 需要，密码独立随机生成 | 无 |
| anytls | anytls | port password domain | 需要 | 无 |
| socks | socks | port username password | 无 | 无 |
| door/direct | direct | port target target-port | 无 | 无 |

所有代理入口、对应出口的 TCP/UDP 支持依赖内核协议能力，实际结果记录在验证报告。`door` 没有通用节点链接，使用指定的转发目标。

HTTP-TLS 使用 `--port` 指定外部端口；原生 TLS 用 `--cert-domain`。`--address` 设置分享连接地址；`--cf-profile` 选择签发凭据；`--certificate` 选择已有证书 ID。

## 出口链接

支持 `direct`、`ss://`（SIP002 及旧 Base64）、`vless://`、`vmess://`（AEAD）、`trojan://`、`hysteria2://`/`hy2://`、`tuic://`、`anytls://`、`socks://`/`socks5://`。

VLESS 支持 TCP、WS、HTTP/H2、HTTPUpgrade、QUIC 和 TLS/REALITY 参数；Vision 仅 TCP。VMess 支持对应传输及 TLS。REALITY 仅为 VLESS 出口配置。Shadowsocks plugin、gRPC、未知行为参数、重复参数、冲突校验设置明确拒绝。

通用链接无法表达任意 JSON 配置，脚本不把任意 core JSON 当成节点链接接受。字符串、URL 编码和密码始终按数据处理。

## 导入边界

只读取 JSON，不执行旧脚本。支持已知的单入口、单用户、直连出口；REALITY 从私钥推导公钥。旧 Caddy 反代 TLS 入口通过 Host 判定域名，先导入或签发相应证书后再应用，不扫描 Caddy 私钥目录。

复杂路由、负载均衡、多用户和未支持行为明确拒绝。导入不修改源文件；已有服务必须使用 `--takeover` 才会停止。旧脚本占用相同快捷命令时，安装器报告冲突而不覆盖。
