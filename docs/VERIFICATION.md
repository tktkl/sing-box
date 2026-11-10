# 验证记录

记录日期：2026-11-10。内核 sing-box 1.14.4，Nginx 1.30.6，Docker Desktop 29.5.3。

| 层次 | 状态 |
|---|---|
| Bash 语法与 ShellCheck | 已通过 |
| 22 种入口配置真实内核检查 | 已通过 sing-box 1.14.4 |
| 节点独立、并发写、链接往返、备份恢复、已知导入 | 已通过 Ubuntu 24.04 arm64 逻辑测试 |
| 多容器 TCP/UDP 协议测试 | 48 项通过，包含 21 种代理入口、21 种出口及 door TCP/UDP |
| Nginx 各传输与证书实际部署 | WS、HTTPUpgrade、H2 双向链路通过；各协议共享链接经真实客户端使用 |
| 证书轮换 | 原生 TCP 握手通过；HY2、TUIC、VMess-QUIC 经新证书公钥固定校验通过 |
| 真实 systemd 服务与定时器 | 专用用户、端口修改、崩溃恢复、定时器、服务交接、卸载保留无关资源通过 |
| 默认屏蔽 | IPv4 内网、IPv6 回环、中国 IP、域名解析到中国 IP、明文 BT 握手均在拨号前拒绝 |
| 故障回滚 | 启动失败恢复版本和 TCP/UDP；后续管理立即获得锁；Nginx 假重载被识别并回滚 |
| 本地 ACME 与模拟 DNS | Pebble 2.10.1＋Certbot 实际 DNS-01、续期、部署钩子、TXT 清理及服务证书验证通过 |
| 真实 Cloudflare staging | 待测试专用域名与 Token |
| BBR 真机/虚拟机启用 | 未验证，容器拒绝修改 |

## 发行版与架构

| 环境 | 结果 |
|---|---|
| Ubuntu 24.04 arm64 | 逻辑测试、真实协议链路、真实 systemd、本地 ACME 均通过 |
| Debian 12 arm64 | 逻辑及真实内核模板检查通过 |
| Debian 13 arm64 | 镜像可拉取；APT TLS/网络失败，未完成验证 |
| Ubuntu 22.04/26.04 arm64 | 未完成矩阵验证；Docker Desktop 文件共享请求挂起后停止后续构建 |
| amd64 | 初始 BusyBox 可运行；后续模拟注册受到特权 systemd 容器影响，内核 amd64 制品校验通过，完整发行版矩阵未完成 |

systemd 测试已屏蔽 binfmt、模块加载、sysctl 和 udev 服务，避免它们操作容器外共享机制。测试期间遇到 Docker Desktop 的文件共享请求挂起；源码快照转存到现有容器的本地文件系统后，继续完成了逻辑、协议与回滚验证。Docker 随后停止，最后一轮静态检查后的完整重跑未完成。恢复完整矩阵需要 Docker Desktop 恢复后重新运行，不能据此声明所有目标系统均通过。

## 仍需外部环境的验收

- 真实 Cloudflare DNS-01：需要测试专用域名和通过隐藏输入提供的 Token；没有读取或复制 DMIT 的 Token。
- BBR 实际启用：需要临时 Linux 虚拟机；容器中的拒绝路径已验证。
- 完整安装器的发行版包仓库兼容性、长时间空闲连接、断电恢复及正式发布升级仍需在完整矩阵中验证。现有升级命令拒绝未锁定内核，并不会把共用旧 Nginx 的重载误报为版本升级成功。

`.test-output/` 保存本次本地测试日志和 JSON 结果，不进入版本库。保留的通过记录包括 `unit.log`、`unit-matrix24.log`、`certificate-e2e.json`、`fault-final.json`、`routes.log`、`systemd.log`、`acme-local.log`。完整协议测试曾以 48 项、退出码 0 完成；原固定名称的 `e2e.json` 后被一次环境中断重跑覆盖，因此测试器已改为额外保存每次运行和最近成功记录。最新日志不必然代表成功，须检查退出码。

Docker 镜像、内核和 ACME 工具摘要见锁定清单。

测试使用隔离网络、假域名和临时证书；模拟 DNS 不计为真实 Cloudflare 验收通过。
