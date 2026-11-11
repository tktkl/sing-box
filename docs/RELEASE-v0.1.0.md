# sb-manager v0.1.0

首个公开脚本版本。一个 sing-box 进程管理多个独立节点，使用稳定入口/出口标签；同协议节点、凭据和出口副本分别管理。锁定 sing-box 1.14.4，支持 Certbot Cloudflare DNS-01 和按需 Nginx 1.30.6。

## 安装

在支持的 Debian/Ubuntu 系统执行：

```bash
curl -fsSL https://github.com/tktkl/sing-box/releases/download/v0.1.0/install.sh -o sb-install.sh && sudo bash sb-install.sh --address YOUR_PUBLIC_IP
```

将 `YOUR_PUBLIC_IP` 替换为服务器公网 IP。独立入口下载同版本完整发布包并校验 SHA-256 与包结构；完整安装包也可下载、校验后执行其中的 `install.sh`。已有安装使用 `sb update sh 0.1.0`。

## 验证与边界

- 54 项真实代理链路、TCP/UDP、分享链接、证书轮换及 Nginx 75 秒空闲连接通过。
- 本地 ACME 正式续期命令、真实 systemd、安装升级回退及 SIGKILL 应用恢复通过。
- 发行版/架构逻辑矩阵 9/10 通过；Ubuntu 26.04 amd64 受本机模拟环境 GNU tar 错误影响，尚未标为通过。
- 真实 Cloudflare 签发按用户决定暂缓；BBR 虚拟机启用、完整包仓库安装矩阵和真实断电尚未验证。

完整结果：[验证记录](https://github.com/tktkl/sing-box/blob/v0.1.0/docs/VERIFICATION.md)。

附件包含脚本源码包、独立安装器与 SHA-256 校验文件，不包含 Cloudflare Token 或运行凭据。`SHA256SUMS` 和独立 `.sha256` 文件均使用附件文件名，可在下载目录直接校验。
