# sb-manager

sing-box 多节点管理脚本，使用 `sb` 命令添加、修改、分享和删除节点。每个节点可以单独设置直连或代理出口，多次添加相同协议会创建多个独立节点。

## 安装

适用系统：Debian 12/13、Ubuntu 22.04/24.04/26.04，支持 amd64、arm64，需要 systemd。

安装时自动获取公网 IP，无需手动填写。

### root 用户

```bash
apt-get update && apt-get install -y curl ca-certificates tar gzip coreutils
curl -fsSL https://github.com/tktkl/sing-box/releases/latest/download/install.sh -o sb-install.sh && \
  bash sb-install.sh
```

### 非 root 用户（有 sudo 权限）

```bash
sudo apt-get update && sudo apt-get install -y curl ca-certificates tar gzip coreutils
curl -fsSL https://github.com/tktkl/sing-box/releases/latest/download/install.sh -o sb-install.sh && \
  sudo bash sb-install.sh
```

没有 sudo 权限时，先执行 `su -` 切换为 root，再按 root 用户的步骤安装。本脚本不支持无管理员权限安装。

自动检测失败，或需要指定其他公网 IP 时，才添加 `--address`：

```bash
bash sb-install.sh --address YOUR_PUBLIC_IP
```

将 `YOUR_PUBLIC_IP` 替换为客户端实际连接的公网 IPv4 或 IPv6 地址；非 root 用户在命令前加 `sudo`。

安装只安装管理脚本和服务，**不会自动创建节点**。安装完成后执行：

```bash
sb
```

非 root 用户执行 `sudo sb`。在菜单中选择「1) 添加节点」，再按序号选择协议；端口、凭据等可按提示填写或使用默认值。创建节点后，请在服务器防火墙和云平台安全组放行节点使用的端口。

## 安装后怎么用

root 用户输入 `sb` 打开菜单，普通用户输入 `sudo sb`：

```bash
sb
```

**下面所有管理命令均以 root 为例；非 root 用户在命令前加 `sudo`，例如 `sudo sb list`。** `sing-box` 与 `sb` 是同一套管理命令的两个入口。

菜单中的添加、修改、出口、证书、网站和维护操作都可按序号选择，输入 `0` 返回。也可以使用下面的快捷命令。

创建节点后查看节点列表，再获取分享链接导入客户端：

```bash
sb list
sb url NODE
```

`NODE` 替换为 `sb list` 输出的节点 `id`，例如 `n-0123456789abcdef`。也可以用节点端口或唯一名称选择节点；有多个匹配时会提示选择，推荐使用 ID。

| 操作 | 命令 |
|---|---|
| 打开菜单 | `sb` |
| 查看帮助 | `sb help` |
| 查看所有节点 | `sb list` |
| 查看完整节点信息和真实凭据 | `sb info NODE` |
| 获取分享链接 | `sb url NODE` |
| 显示分享二维码 | `sb qr NODE` |
| 查看脚本和内核版本 | `sb version` |

菜单中的「完整节点信息」、`sb info`、`sb debug` 和导入预览均显示真实字段值，包括 UUID、密码、REALITY 密钥及出口参数，不自动替换为脱敏标记。

## 添加节点

### REALITY：无需自有域名和证书

```bash
sb add reality 24443 auto apps.mzstatic.com
sb add reality 24444 auto xp.apple.com
```

这两条命令分别创建两个节点，端口为 `24443`、`24444`，`auto` 表示自动生成 UUID。直接执行 `sb add` 会打开协议选择菜单，所有 22 种协议和传输组合都按序号列出。

### Shadowsocks

```bash
sb add ss 24445 auto aes-256-gcm
```

`24445` 是端口，`auto` 表示自动生成密码，`aes-256-gcm` 是加密方式。

### 需要证书的协议

先准备自己控制的域名和该域名的 Cloudflare DNS Token。将 `proxy.example.com` 替换为自己的域名，执行：

```bash
sb cert token set primary
sb cert issue proxy.example.com --profile primary
```

第一条命令会提示输入 Token，输入不回显；`primary` 是这份凭据的名称。然后按需添加节点：

```bash
# Trojan
sb add trojan 24446 auto --cert-domain proxy.example.com

# Hysteria2
sb add hy2 24447 auto --cert-domain proxy.example.com

# TUIC
sb add tuic 24448 auto --cert-domain proxy.example.com

# AnyTLS
sb add anytls 24449 auto proxy.example.com

# VLESS + WebSocket + TLS
sb add vws proxy.example.com auto /tunnel --port 24450
```

分享链接默认使用自动获取或手动指定的公网 IP，证书域名用于 TLS SNI。证书自动续期，也可以手动检查和续期：

```bash
sb cert list
sb cert check proxy.example.com
sb cert renew proxy.example.com
```

## 修改和删除节点

将 `NODE` 替换为要操作的节点 ID。

| 操作 | 命令 |
|---|---|
| 交互选择修改项 | `sb change NODE` |
| 修改公网端口 | `sb port NODE 24500` |
| 修改 REALITY 的 SNI | `sb sni NODE xp.apple.com` |
| 重新生成 UUID（适用 VLESS、VMess、TUIC） | `sb id NODE auto` |
| 重新生成密码（适用 SS、Trojan 等） | `sb passwd NODE auto` |
| 将协议切换为 SS，保留原端口并生成密码 | `sb new NODE ss --password auto --method aes-256-gcm` |
| 修改 HTTP 传输路径 | `sb path NODE /new-path` |
| 修改 TLS 证书域名 | `sb host NODE new.example.com` |
| 删除一个节点 | `sb del NODE` |

修改证书域名前，先为新域名签发证书。修改后使用 `sb url NODE` 重新获取链接并更新客户端配置。

单个节点的协议、凭据和出口独立保存；应用配置会短暂重启 sing-box，其他节点的现有连接也会暂时中断。

## 给节点设置出口

默认出口为直连。要让某个节点通过另一个代理访问网络，执行以下命令，按序号选择「粘贴代理节点链接」，再粘贴 SS、VLESS 等节点链接并回车：

```bash
sb outbound NODE
```

恢复直连：

```bash
sb outbound NODE direct
```

每个节点保存自己的出口副本。两个节点使用同一个出口链接时，修改其中一个不会更改另一个的出口设置。

## 伪装网站

WS/H2/HTTPUpgrade-TLS 节点可以设置伪装网站，脚本会按需使用 Nginx：

```bash
sb web NODE https://www.example.org
```

将网址替换为要反代的 HTTP/HTTPS 网站。不设置远程网址时，默认显示本地静态页面。需要单独建立一个网站时：

```bash
sb web --domain website.example.com --port 443 --profile primary
```

REALITY、SS 和原生 TLS/QUIC 节点不需要为此创建 Nginx 配置。

## 服务、更新和备份

| 操作 | 命令 |
|---|---|
| 查看运行状态 | `sb status` |
| 启动 / 停止 / 重启 | `sb start` / `sb stop` / `sb restart` |
| 查看实时日志（按 Ctrl+C 退出） | `sb log` |
| 检查配置 | `sb test` |
| 从节点记录修复配置 | `sb fix-all` |
| 重启 Nginx | `sb restart nginx` |
| 修复 Nginx 配置 | `sb fix-nginx` |
| 更新管理脚本到最新稳定版 | `sb update sh` |
| 检查最新内核、字段变化和配置兼容性 | `sb update core --check` |
| 更新 sing-box 内核到最新稳定版 | `sb update core` |
| 备份 | `sb backup /root/sb-backup.tar.gz` |
| 恢复备份 | `sb restore /root/sb-backup.tar.gz` |
| 卸载脚本和服务 | `sb uninstall` |

更新时无需填写版本号：

```bash
# root 用户
sb update sh
sb update core

# 非 root 用户
sudo sb update sh
sudo sb update core
```

`sb update core` 从 sing-box 官方获取最新稳定版，校验下载文件，并提示新增和移除的配置字段。也可以先执行 `sb update core --check`，只检查、不更新。字段检测不完整时会明确提示；新字段需管理脚本适配后按需启用，不会自动修改已有节点。配置不兼容会保留旧内核，服务启动失败会恢复旧内核和配置。

备份包含节点凭据和证书，**不包含 Cloudflare Token**；恢复后需重新执行 `sb cert token set primary` 才能自动续期。卸载保留节点、证书和凭据数据。

更多参数见 [完整命令与协议表](docs/COMPATIBILITY.md)。[开发与测试](docs/DEVELOPMENT.md)、[验证记录](docs/VERIFICATION.md) 单独维护。
