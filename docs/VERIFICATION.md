# 验证记录

记录日期：2026-11-11。内核 sing-box 1.14.4，Nginx 1.30.6，Docker Engine 29.5.3，宿主为 Apple Silicon。amd64 通过 Docker 模拟执行，结果仅用于功能兼容性。

## 功能验收

| 项目 | 实际结果 |
|---|---|
| Bash 语法、ShellCheck、Python 语法 | 通过 |
| 节点与配置逻辑 | 稳定 ID、同协议多节点、独立出口副本、并发写、非交互歧义报错通过 |
| 入口模板 | 全部 22 种入口通过真实 sing-box 1.14.4 配置检查 |
| 多容器协议通信 | 54 项通过：21 种代理入口、21 种出口的 TCP/UDP、真实分享链接客户端、door TCP/UDP、出口故障、回滚、证书及空闲连接 |
| Nginx 长连接 | WS、H2、HTTPUpgrade 三条真实链路均在 75 秒无响应后继续收到完整数据；同域名三端口只有一个配置文件 |
| 证书轮换 | 原生 TCP 实际握手确认；HY2、TUIC、VMess-QUIC 使用新证书的公钥固定校验通信通过 |
| 本地 ACME | Pebble 2.10.1＋Certbot 实际 DNS-01 签发、正式 `sb cert renew`、部署队列消费、TXT 清理、实际服务证书均通过 |
| 默认路由屏蔽 | IPv4/IPv6 私网、CGNAT、文档与基准测试等特殊地址、中国 IP、解析到中国 IP 的域名、明文 BT 握手，在出口拨号前拒绝 |
| systemd 生命周期 | 真实 PID 1、专用运行用户、连续端口修改、崩溃恢复、定时续期任务、Nginx 端口交接通过 |
| Nginx 修复与回滚 | 修复损坏模板后节点记录和 sing-box PID 不变；假重载被识别并恢复旧配置 |
| 脚本升级 | 新模板预校验拒绝错误配置；切换脚本后注入安装失败可恢复旧脚本和服务定义；正常重装保留节点记录 |
| 安装器 | 真实公开安装器下载并校验内核、安装、运行、升级、卸载通过；锁定缓存的离线安装也通过 |
| 新 Nginx 默认端口保护 | 真实 dpkg 测试包的 postinst 尝试启动 Nginx，被临时服务屏蔽阻止；默认网站被禁用，80 端口未监听 |
| 备份和导入 | Token 排除、0600 权限、完整性和路径检查、Certbot 执行钩子拒绝恢复、三套已知单节点格式导入通过 |
| 卸载 | 保留节点、凭据、证书和无关 Nginx 文件；删除本项目服务和快捷命令通过 |
| 应用中断恢复 | 配置指针切换后 SIGKILL 整个应用进程组；下一条命令恢复原节点字节、旧监听和事务状态，后续修改正常获得写锁 |
| 正式 Release | `v0.1.0` 标签触发发布成功；四个公开附件下载及校验通过，独立安装器下载同版 Release、`sb update sh 0.1.0` 和完整 systemd 生命周期均通过 |

完整协议、ACME、安装和 systemd 验收在 Ubuntu 24.04 arm64 执行。发行版矩阵运行逻辑测试及真实内核配置检查，不能等同于每个环境都完成全部协议验收。

## 发行版与架构

| 发行版 | arm64 | amd64 |
|---|---|---|
| Debian 12 | 通过 | 通过，模拟执行 |
| Debian 13 | 通过 | 通过，模拟执行 |
| Ubuntu 22.04 | 通过 | 通过，模拟执行 |
| Ubuntu 24.04 | 通过 | 通过，模拟执行 |
| Ubuntu 26.04 | 通过 | 未通过镜像构建：系统 GNU tar 解包时报 `Function not implemented` |

共 9/10 组完成逻辑及内核配置验收。Ubuntu 26.04 amd64 的锁定内核压缩包校验正确，流式读取出的内核能执行 `version`；该环境的 GNU tar 创建归档成员失败，普通文件读写正常，取消 seccomp 后结果相同。以上证据指向本机模拟环境限制，尚未在原生 amd64 或独立 QEMU 环境复验，不能将这组标为通过。

Debian 13 最小镜像的 APT 引导证书路径问题已通过显式指定锁定 CA bundle 修复，TLS 和仓库签名校验保持开启。Docker 文件共享恢复后，重新完成矩阵及真实协议测试。

systemd 容器使用独立 cgroup，启动 PID 1 前把 `/proc/sys/fs/binfmt_misc` 覆盖为只读 tmpfs，并屏蔽 binfmt、模块加载、sysctl 和 udev 服务。安装与 systemd 测试后再次运行 amd64 容器成功。测试没有修改宿主模拟器注册。

## 本轮修复

- H2 开放请求体被 Nginx 默认 60 秒计时器断开：补齐客户端及上游双向超时，75 秒真实空闲测试通过。
- Nginx 模板升级被资源内容比较忽略：记录模板摘要，修复命令强制重建，并验证新代际标记实际生效。
- 连续管理重启耗尽 systemd 启动限速：显式管理启动先清除失败计数，自动崩溃重启仍受服务限速保护。
- `ip_is_private` 未覆盖 CGNAT 等特殊网段：补充本地 CIDR 拒绝规则并测试真实请求。
- 升级缺少旧配置预校验及脚本指针恢复：增加安装前检查和失败恢复，保留旧发布目录。
- 新 Nginx 软件包默认网站可能在安装时启动：安装期间屏蔽新服务，禁用默认网站后再解除屏蔽。
- 内核重复下载：增加每次校验摘要的下载缓存；网络错误保留 TLS 校验并有限重试。

## 未覆盖与外部条件

- **真实 Cloudflare staging：按用户决定暂缓。** 没有测试域名，也没有读取、复制或要求提供 DMIT Token。本地 ACME 的模拟 DNS/manual adapter 不计为 Cloudflare 插件鉴权或真实 TXT 生命周期通过。
- **BBR 实际启用：未验证。** 容器拒绝修改共享内核的路径通过；仍需临时 Linux 虚拟机。
- **Ubuntu 26.04 amd64：** 需要能支持其系统调用的模拟环境或原生 amd64 机器。
- **发行版包仓库完整安装矩阵：未完成。** 九组逻辑结果不代表所有发行版的全新依赖安装、Certbot/Cloudflare 插件或 nginx.org 签名仓库安装都通过。Nginx 的 dpkg 本地测试包只验证安装时端口保护，不替代官方软件包验收。
- **真实断电：未验证。** 已通过 SIGKILL 应用中断、进程启动失败、Nginx 失效重载和安装故障注入；没有将它们表述为断电测试。

## 可复现命令与证据

```bash
make test
make test-e2e
make test-systemd
make test-install
make test-bootstrap
SB_TEST_OFFLINE=1 make test-install
make test-acme-local
make test-docker
```

`make test-install` 使用完整公开安装器。离线选项仅向临时容器正常缓存写入锁定且重新校验的内核包，不替换安装器、`systemctl` 或服务进程。

本机原始日志在 `.test-output/20261111/`，矩阵每轮独立保存在 `.test-output/matrix/<UTC>-<PID>/`，包含基础镜像摘要、测试镜像 ID、源码提交与未提交状态、构建/测试阶段及退出结果。协议测试保留每次 JSON 和 `last-success-e2e.json`，失败重跑不会覆盖最近成功证据。日志目录不进入 Git。

有效报告应同时检查 JSON 状态与退出码，不能只看固定名称的最新日志。全部测试资源使用临时容器和隔离配置；没有挂载宿主真实凭据或修改防火墙。

## 正式发布补充记录

2026-11-11，[Release 工作流](https://github.com/tktkl/sing-box/actions/runs/42946195503) 成功发布 [v0.1.0](https://github.com/tktkl/sing-box/releases/tag/v0.1.0)。独立安装器、源码包、源码包校验文件和 `SHA256SUMS` 均可公开下载；下载所得安装器与标签源码一致。公开包一键安装和真实 `sb update sh 0.1.0` 均已在隔离 systemd 容器验证，升级前后节点记录保持一致。该轮内核使用已校验缓存；此前内核真实下载另已通过。

日志：`.test-output/20261111/published-release-e2e.log`、`published-release-e2e.exit`（0），附件保留在同目录的 `published-v0.1.0/`。

另已核查提交 `6393b38` 的 [GitHub Actions](https://github.com/tktkl/sing-box/actions/runs/42944161214)：10 组逻辑矩阵全部通过，包含原生 amd64 上的 Ubuntu 26.04；本机模拟环境失败记录仍保留。该次远程 integration 在 `make test-systemd` 失败，因此不能将整个 CI 标为通过。发布工作流、逻辑矩阵与本机 systemd 实测是分别记录的证据。

## v0.1.1 交互与安装验收（2026-11-13）

安装默认改为不创建节点；只有显式 `--with-node` 才进入初始 REALITY 创建。真实 systemd 安装器测试没有传 `--no-node`，确认安装后节点数量为零且核心未启动；首次添加、修改、崩溃恢复、重装保留节点及升级失败回退均通过。

新增 `make test-interactive`，用真实 PTY（保留终端回显）驱动 Bash 菜单，验证：

- 主菜单循环、22 项协议编号及映射、两个 REALITY SNI 预设、非法序号重试和 `0` 取消。
- 同协议多节点、密码隐藏输入、按协议筛选修改项、名称和地址修改、端口冲突不变更、独立出口及恢复直连。
- 切换协议保留 ID/端口且另一节点记录不变；自签证书须显式选择，网站菜单仅提供可反代的 HTTP TLS 节点。
- Cloudflare Token 隐藏输入和 0600 凭据权限、DNS 选择、删除确认、节点选择取消，以及操作失败后返回主菜单。
- 网站、服务、日志、备份、更新及维护子菜单能取消返回；不需要输入协议别名或修改字段名。

原有逻辑测试、全部 22 种入口真实内核检查、54 项真实通信、路由拒绝和 SIGKILL 事务恢复回归通过。发布引导按 `VERSION` 校验同版安装包，损坏包及链接成员拒绝执行。没有开展真实 Cloudflare DNS-01 验收，既有外部验证边界继续适用。

本轮日志保存于 `.test-output/20261113/`，包括 `unit.log`、`interactive-final.log`、`install.log`、`e2e-driver.log`、`static-release.log` 及对应退出码。

[v0.1.1 发布工作流](https://github.com/tktkl/sing-box/actions/runs/43353773723) 成功，公开附件已下载并通过 SHA-256 校验。针对公开包再次运行真实 PTY 菜单测试通过；单文件安装入口在没有 `--no-node` 的情况下安装后节点为零，从公开 v0.1.0 升级至 v0.1.1 后节点数量、凭据和记录保持一致，随后完整 systemd 验收通过。本地 ACME 的正式续期及部署回归通过。

公开包证据：`published-interactive.log`、`published-bootstrap.log`、`upgrade-0.1.0.log`、`acme.log`，对应退出码均为 0；附件位于 `published-v0.1.1/`。

## v0.1.2 真实字段显示验收（2026-11-13）

按用户要求移除管理命令的自动脱敏。`sb info`、`sb debug`（全局及单节点）、菜单节点详情和导入预览显示实际字段值。节点摘要和状态仍作为摘要输出，不使用替换标记。

逻辑测试对 SS、REALITY 及独立出口的节点信息和诊断输出与保存记录进行完整 JSON 等值比较；三套导入预览保留原 UUID。真实 PTY 测试确认快捷命令和编号菜单详情均显示保存的密码原值，其他菜单回归通过。安装、重装、节点保留和失败回退的真实 systemd 测试通过，静态检查和发布包引导校验通过。

证据位于 `.test-output/20261113/unredacted/` 的 `unit.log`、`interactive.log`、`install.log`、`static.log` 及对应退出码。

[v0.1.2 发布工作流](https://github.com/tktkl/sing-box/actions/runs/43376207173) 成功。四个公开附件的下载及 SHA-256 校验通过；公开包的逻辑和真实 PTY 测试通过，节点详情显示与保存记录一致的实际凭据。从公开 v0.1.1 升级至 v0.1.2 后，节点记录保持一致，完整 systemd 验收通过。逻辑测试对公开包复用仓库的 ShellCheck 配置，该开发配置不属于运行组件。

对应日志为 `published-unit.log`、`published-interactive.log`、`published-upgrade.log`，退出码均为 0。
