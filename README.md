# sb-manager

使用一个 sing-box 进程管理多个独立节点。原始 Bash 5＋jq 实现，参考 233boy 的命令习惯，运行时不下载或执行其脚本。

默认内核 **sing-box 1.14.4**。每次 `add` 创建一个新节点；入口、凭据和出口副本属于该节点，协议相同也不合并。修改配置会短暂中断连接。

## 安装

面向 Debian 12/13、Ubuntu 22.04/24.04/26.04，amd64/arm64。各环境实际验证结果见 [验证记录](docs/VERIFICATION.md)。

在目标 Linux 上下载正式 Release 的独立安装器执行：

```bash
curl -fsSL https://github.com/tktkl/sing-box/releases/download/v0.1.0/install.sh -o sb-install.sh && sudo bash sb-install.sh --address YOUR_PUBLIC_IP
```

把 `YOUR_PUBLIC_IP` 替换为服务器公网 IP。独立入口下载同版本正式发布包，验证 SHA-256 和包结构后执行；脚本为 `0.1.0`，内核为 `1.14.4`。下载或校验失败即停止。

也可以取得并检查完整仓库后安装；公开仓库使用 HTTPS，不需要配置 GitHub SSH 密钥：

```bash
git clone https://github.com/tktkl/sing-box.git
cd sing-box
sudo bash install.sh --address YOUR_PUBLIC_IP
```

安装默认创建一个 REALITY 节点；`--no-node` 只初始化。安装器拒绝覆盖其他项目的 `sb`、`sing-box` 快捷命令。不会关闭防火墙。

配置根目录 `/etc/sb-manager`；内核、脚本在 `/usr/local/lib/sb-manager`。管理命令需 root，实际 sing-box 使用专用用户运行。系统服务名 `sb-manager.service`。

## 独立节点

```bash
sb add reality 24443 auto apps.mzstatic.com
sb add reality 24444 auto xp.apple.com
sb list

sb port n-YOUR_NODE_ID 24445
sb sni n-YOUR_NODE_ID xp.apple.com
sb new n-YOUR_NODE_ID ss auto auto aes-256-gcm
sb outbound n-YOUR_NODE_ID
sb url n-YOUR_NODE_ID
```

`outbound` 隐藏读取链接；非交互可从标准输入传入。输入 `direct` 选择直连。两个节点粘贴同一链接也保存各自的副本。分享链接包含节点凭据；`info`、`debug` 默认脱敏。

节点有稳定 ID；变更端口和协议不会改变 ID。快捷选择支持端口、协议、名称；非交互模式下多个匹配会报错。`port` 修改公网端口，内部回环端口由脚本维护。

REALITY 默认预设 `apps.mzstatic.com`，另一个候选为 `xp.apple.com`，也支持自定义。默认检查目标 TLS 1.3；`--skip-probe` 可显式离线配置，不改变其他节点。

## Cloudflare DNS-01 证书

仅当 TLS 节点或网站需要证书时安装 Certbot 依赖。使用 Let’s Encrypt ECDSA 证书，默认 DNS 传播等待 60 秒。

```bash
sb cert token set primary
sb cert issue proxy.example.com --profile primary --email you@example.com
sb cert check

sb add hy2 24446 auto --cert-domain proxy.example.com
sb add anytls 24447 auto proxy.example.com
sb add vws proxy.example.com auto /tunnel --port 24448
```

Token 仅存 root 专用文件，限目标 Zone 的 DNS 编辑权限。脚本只创建和清理 ACME TXT，不改 A/AAAA、橙云、网站配置。默认通过公网 IP 连接，并携带证书域名 SNI；不要求 A/AAAA 指向本机。

可使用 `cert import <域名> <证书链> <私钥>` 导入可信证书。显式自签使用 `--self-signed`，其分享链接会标明需要跳过公共 CA 校验。导入证书不会自动创建网站。

## Nginx 按需使用

- WS/H2/HTTPUpgrade-TLS：Nginx 终止 TLS，反代到回环地址的节点入口。
- 原生 Trojan、AnyTLS、Hysteria2、TUIC、VMess-QUIC：sing-box 直接加载证书。
- REALITY、SS、Socks、普通 VMess：无须 Nginx；需要证书的实际传输例外见能力表。

只有反代或网站域名生成 Nginx 文件。一个域名一个文件，同域名节点仍占各自独立的公网端口。

```bash
sb web n-YOUR_HTTP_TLS_NODE https://www.example.org
sb web --domain website.example.com --port 443 --profile primary
sb restart nginx
sb fix-nginx
```

默认伪装为本地静态页面；远程伪装验证上游 HTTPS 证书。独立网站不会自动成为原生 TCP/UDP 代理端口的 HTTP 回落。

新装 Nginx 锁定 1.30.6，验证 APT 签名。已有版本不足时拒绝依赖相应能力的操作，不替换现有 Nginx。Caddy 命令已移除并提供替代说明。

## 全局操作和恢复

```bash
sb dns cf
sb log warn
sb status
sb test
sb backup /root/sb-backup.tar.gz
sb restore /root/sb-backup.tar.gz
sb import /etc/sing-box/conf
sb import /path/to/known-config.json --apply
```

DNS、默认屏蔽、证书、进程和更新可能影响多个节点，菜单和帮助会标明。默认阻止 BT、中国 IP 和内网/非公网地址。BT 识别不能覆盖所有混淆流量。出口不可用时不自动转为直连。

配置先校验再切换，失败恢复上一版。证书先验证，再成对发布到不可变目录；实际服务握手用于确认部署。配置版本保留最近 10 个历史版本。

备份包含运行凭据、证书和状态，文件权限 `0600`；**排除 Cloudflare Token**。恢复后要重新配置 Token 才能续期。导入默认预览；未知行为拒绝转换。`--takeover` 显式授权停止已知旧核心服务，不修改旧脚本目录。

内核更新只接受锁定兼容清单中的版本。稳定安装器和源码包通过 [GitHub Release](https://github.com/tktkl/sing-box/releases/latest) 发布，`sb update sh` 自动获取稳定 Release，也可用 `sb update sh 0.1.0` 指定版本，或 `sb update sh --from /path/to/verified/source` 从本地完整源码升级。推送与 `VERSION` 一致的 `v*` 标签会触发 Release 工作流，生成并验证附件。卸载移除本项目服务及快捷命令，保留数据，供备份或人工清理。

重装或升级先用新脚本校验现有节点和 Nginx 配置，再切换脚本版本；失败恢复旧脚本和服务定义。锁定内核的下载缓存位于配置目录的 `cache/`，每次使用都检查 SHA-256。`fix-nginx` 强制重建并验证模板，不更换节点凭据或重启 sing-box。

## 开发与测试

```bash
make test-image
make test
make test-e2e
make test-systemd
make test-install
make test-acme-local
make test-docker
```

测试镜像、内核、Nginx、规则集和 ACME 工具锁定校验值。测试仅使用隔离的网络、临时文件和假证书，不挂载宿主真实配置。systemd 验收使用特权隔离容器；BBR 在容器里拒绝修改内核参数。

`test-install` 调用公开安装器，随后验证真实服务、升级及卸载。网络受限时可用 `SB_TEST_OFFLINE=1 make test-install`，把已下载的锁定内核放入容器的正常缓存；这不算外部下载路径验收通过。`test-acme-local` 使用一小时有效期的测试证书，调用正式 `sb cert renew`，验证续期钩子和实际部署。

矩阵日志和 JSON 结果按运行分别保存在 `.test-output/matrix/`，包含镜像摘要、源码提交及未提交状态。可用 `SB_TEST_DISTROS='debian-12 ubuntu-24.04' SB_TEST_ARCHES=amd64 make test-docker` 缩小范围。完整发行版矩阵验证逻辑及内核配置，真实协议测试单独执行。

真实 Cloudflare staging 验收单独执行，使用测试域名和通过隐藏输入配置的 Token。它不会把 staging 证书部署给生产节点。

兼容命令与协议组合详见 [兼容表](docs/COMPATIBILITY.md)。
