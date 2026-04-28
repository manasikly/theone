# One-Keys-Vless

GitHub 只保留两个文件：

- `README.md`
- `server/deploy/ubuntu-auto.sh`

## curl 一键安装

默认 443（推荐）：

```bash
curl -fsSL https://raw.githubusercontent.com/manasikly/theone/main/server/deploy/ubuntu-auto.sh | sudo bash -s -- --protocol reality --server-name www.cloudflare.com
```

443 被占用时改 2443：

```bash
curl -fsSL https://raw.githubusercontent.com/manasikly/theone/main/server/deploy/ubuntu-auto.sh | sudo bash -s -- --protocol reality --listen-port 2443 --server-name www.cloudflare.com
```

说明：以上地址为公开仓库可直接使用的安装入口。

## 参数

- `--protocol reality`：使用 Reality
- `--listen-port`：可选，默认 443
- `--server-name`：Reality 握手域名
- `--public-host`：可选，不写自动探测公网 IP

## 安装后验证

```bash
systemctl is-active sing-box
sing-box check -c /etc/sing-box/config.json
```
