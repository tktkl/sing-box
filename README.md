# sb-manager

sing-box 多节点管理脚本，使用 `sb` 命令添加、修改、分享和删除节点。每个节点可以单独设置直连或代理出口，多次添加相同协议会创建多个独立节点。

## 安装

适用系统：Debian 12/13、Ubuntu 22.04/24.04/26.04，支持 amd64、arm64，需要 systemd。

将下面的 `YOUR_PUBLIC_IP` 替换为服务器的公网 IPv4 或 IPv6 地址。

### root 用户

```bash
apt-get update && apt-get install -y curl ca-certificates tar gzip coreutils
curl -fsSL https://github.com/tktkl/sing-box/releases/latest/download/install.sh -o sb-install.sh && \
  bash sb-install.sh --address YOUR_PUBLIC_IP
```

### 非 root 用户（有 sudo 权限）

```bash
sudo apt-get update && sudo apt-get install -y curl ca-certificates tar gzip coreutils
curl -fsSL https://github.com/tktkl/sing-box/releases/latest/download/install.sh -o sb-install.sh && \
  sudo bash sb-install.sh --address YOUR_PUBLIC_IP
```

没有 sudo 权限时，先执行 `su -` 切换为 root，再按 root 用户的步骤安装。本脚本不支持无管理员权限安装。

安装默认创建一个 REALITY 节点。只安装管理脚本、暂不创建节点，在安装命令末尾加 `--no-node`：

```bash
bash sb-install.sh --address YOUR_PUBLIC_IP --no-node
```

非 root 用户执行该命令时同样加 `sudo`。安装后，请在服务器防火墙和云平台安全组放行节点使用的端口。

## 安装后怎么用

root 用户输入 `sb` 打开菜单，普通用户输入 `sudo sb`：

```bash
sb
```

**下面所有管理命令均以 root 为例；非 root 用户在命令前加 `sudo`，例如 `sudo sb list`。** `sing-box` 与 `sb` 是同一套管理命令的两个入口。

先查看安装时创建的节点，再获取分享链接导入客户端：

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
| 查看一个节点 | `sb info NODE` |
| 获取分享链接 | `sb url NODE` |
| 显示分享二维码 | `sb qr NODE` |
| 查看脚本和内核版本 | `sb version` |

## 添加节点

### REALITY：无需自有域名和证书

```bash
sb add reality 24443 auto apps.mzstatic.com
sb add reality 24444 auto xp.apple.com
```

这两条命令分别创建两个节点，端口为 `24443`、`24444`，`auto` 表示自动生成 UUID。省略协议和参数执行 `sb add`，会自动创建一个默认 REALITY 节点。

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

默认通过安装时填写的公网 IP 连接，证书域名用于 TLS SNI。证书自动续期，也可以手动检查和续期：

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

默认出口为直连。要让某个节点通过另一个代理访问网络，执行以下命令，再粘贴 SS、VLESS 等节点链接并回车：

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
| 更新管理脚本 | `sb update sh` |
| 备份 | `sb backup /root/sb-backup.tar.gz` |
| 恢复备份 | `sb restore /root/sb-backup.tar.gz` |
| 卸载脚本和服务 | `sb uninstall` |

备份包含节点凭据和证书，**不包含 Cloudflare Token**；恢复后需重新执行 `sb cert token set primary` 才能自动续期。卸载保留节点、证书和凭据数据。

更多参数见 [完整命令与协议表](docs/COMPATIBILITY.md)。[开发与测试](docs/DEVELOPMENT.md)、[验证记录](docs/VERIFICATION.md) 单独维护。
