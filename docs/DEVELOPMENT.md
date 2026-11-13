# 开发与测试

项目使用 Bash 5＋jq，管理一个 sing-box 进程。实现记录见 [IMPLEMENTATION.md](IMPLEMENTATION.md)，各环境的实测结果和未覆盖项见 [VERIFICATION.md](VERIFICATION.md)。

## 本地开发

```bash
git clone https://github.com/tktkl/sing-box.git
cd sing-box
make test-image
make test
make test-interactive
make test-core-update
make test-core-update-live
make test-e2e
make test-systemd
make test-install
make test-bootstrap
make test-acme-local
make test-docker
```

测试镜像、内核、Nginx、规则集和 ACME 工具锁定校验值。测试使用隔离网络、临时文件和测试证书，不挂载宿主真实配置。systemd 验收使用特权隔离容器；BBR 在容器中拒绝修改共享内核参数。

`test-install` 调用公开安装器并验证服务、升级和卸载；`test-bootstrap` 验证单文件入口从正式 Release 下载完整安装包。网络受限时可使用 `SB_TEST_OFFLINE=1 make test-install`，将锁定内核放入容器的正常下载缓存；此模式不计为外部下载路径验收通过。

`test-interactive` 使用真实 PTY 驱动 Bash，验证编号菜单、输入隐藏、取消、协议切换、节点独立和错误返回主菜单。安装验收另外检查默认安装后节点数量为零。

`test-core-update` 在无网络容器内注入发布元数据、字段补丁和版本包装器，实际调用已锁定内核进行配置校验及进程启动。验证最新版本选择、仅检查、字段源码回退、摘要/来源/预发布拒绝、配置不兼容、启动失败、保留停止状态和 SIGKILL 后恢复；模拟版本不等同于真实未来版本验证。`test-core-update-live` 连接官方发布 API，从上一稳定分支 1.13.14 的真实内核升级至当时最新稳定版，检查节点数据不变和后续管理操作；网络或 API 限流失败须单独记录。

内核更新先在配置锁之外下载和生成字段报告，进入锁后再次校验配置和旧内核摘要。`core-update.json` 记录切换状态，`core-versions/` 保存旧二进制及受信元数据；配置事务和内核事务共同恢复旧版本。不要把候选二进制直接覆盖至运行路径，或通过跳过 `check_core_version` 接受未经校验的新版本。

`test-acme-local` 使用本地 ACME 服务和一小时有效期证书，调用正式 `sb cert renew`，验证钩子和实际部署。真实 Cloudflare staging 验收单独执行，需要测试域名和通过隐藏输入配置的 Token；本地模拟 DNS 不替代真实 Cloudflare 验收。

## 发行版矩阵

矩阵验证逻辑和真实内核配置，协议通信另由 `test-e2e` 验证。可以只运行部分环境：

```bash
SB_TEST_DISTROS='debian-12 ubuntu-24.04' SB_TEST_ARCHES=amd64 make test-docker
```

每次运行的日志和 JSON 结果保存在 `.test-output/matrix/`，记录基础镜像摘要、测试镜像 ID、源码提交、未提交状态及测试阶段。`.test-output/` 不进入 Git，判断结果需同时检查退出码和报告状态。

## 发布

推送与 `VERSION` 一致的版本标签（例如 `v0.1.0`），会触发 `.github/workflows/release.yml`。工作流生成源码包、独立安装器和 SHA-256 文件，创建 Release，并下载公开附件进行校验。

`install.sh` 中的引导版本需与 `VERSION` 同步，发布说明放在 `docs/RELEASE-v<版本>.md`。发布前可以从完整源码目录验证升级：

```bash
sudo sb update sh --from /path/to/verified/source
```
