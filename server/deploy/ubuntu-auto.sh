#!/usr/bin/env bash
# ============================================================
#  ubuntu-auto.sh — sing-box Ubuntu 一键自动化部署
#  特性：
#   - 自动匹配 Ubuntu 版本 / CPU 架构
#   - 自动匹配协议 reality / ws-tls
#   - ws-tls 自动申请证书（acme.sh + standalone）
#   - 自动安装 sing-box + systemd + 防火墙放行
#   - 输出客户端连接参数
#
#  用法示例：
#   sudo bash ubuntu-auto.sh --protocol reality
#   sudo bash ubuntu-auto.sh --protocol ws-tls --domain your.domain.com --email you@example.com
# ============================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()  { echo -e "${GREEN}[OK]${NC}   $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
err() { echo -e "${RED}[ERR]${NC}  $*"; exit 1; }

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || err "请用 root 运行：sudo bash $0 ..."
}

check_ubuntu() {
  [[ -f /etc/os-release ]] || err "找不到 /etc/os-release，无法识别系统"
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || err "仅支持 Ubuntu，当前是: ${ID:-unknown}"

  local major="${VERSION_ID%%.*}"
  [[ "$major" =~ ^[0-9]+$ ]] || err "无法识别 Ubuntu 版本: ${VERSION_ID:-unknown}"
  (( major >= 20 )) || err "需要 Ubuntu 20.04+，当前: ${VERSION_ID}"
  ok "系统匹配: Ubuntu ${VERSION_ID}"
}

match_arch() {
  local m
  m="$(uname -m)"
  case "$m" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) err "不支持的架构: $m（仅支持 amd64/arm64）" ;;
  esac
  ok "架构匹配: ${ARCH}"
}

usage() {
  cat <<EOF
用法:
  sudo bash ubuntu-auto.sh [参数]

参数:
  --protocol <reality|ws-tls>     协议类型（默认 reality）
  --listen-port <port>            监听端口（默认 443）
  --uuid <uuid>                   自定义 UUID（默认自动生成）
  --require-vision                强制客户端使用 xtls-rprx-vision flow（默认关闭，兼容更多客户端）

  --domain <fqdn>                 ws-tls 必填；reality 可选
  --email <email>                 ws-tls 申请证书时使用（默认 admin@domain）

  --server-name <sni>             reality 握手域名（默认 www.cloudflare.com）
  --short-id <hex>                reality short_id（默认自动生成 8 字节）
  --public-host <host>            reality 导出链接 host（默认公网 IP）

  --ws-path </path/>              ws 路径（默认 /40c393e/）
  --ws-host <host>                ws Host 头（默认等于 domain）

  --skip-firewall                 跳过防火墙规则配置
  --help                          显示帮助

示例:
  sudo bash ubuntu-auto.sh --protocol reality
  sudo bash ubuntu-auto.sh --protocol reality --listen-port 443 --server-name www.microsoft.com
  sudo bash ubuntu-auto.sh --protocol ws-tls --domain api.example.com --email me@example.com
EOF
}

PROTOCOL="reality"
LISTEN_PORT="443"
UUID=""
DOMAIN=""
EMAIL=""
SERVER_NAME="www.cloudflare.com"
SHORT_ID=""
PUBLIC_HOST=""
WS_PATH="/40c393e/"
WS_HOST=""
SKIP_FIREWALL="false"
REQUIRE_VISION="false"

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --protocol) PROTOCOL="${2:-}"; shift 2 ;;
      --listen-port) LISTEN_PORT="${2:-}"; shift 2 ;;
      --uuid) UUID="${2:-}"; shift 2 ;;
      --domain) DOMAIN="${2:-}"; shift 2 ;;
      --email) EMAIL="${2:-}"; shift 2 ;;
      --server-name) SERVER_NAME="${2:-}"; shift 2 ;;
      --short-id) SHORT_ID="${2:-}"; shift 2 ;;
      --public-host) PUBLIC_HOST="${2:-}"; shift 2 ;;
      --ws-path) WS_PATH="${2:-}"; shift 2 ;;
      --ws-host) WS_HOST="${2:-}"; shift 2 ;;
      --skip-firewall) SKIP_FIREWALL="true"; shift ;;
      --require-vision) REQUIRE_VISION="true"; shift ;;
      --help|-h) usage; exit 0 ;;
      *) err "未知参数: $1（用 --help 查看）" ;;
    esac
  done
}

validate_args() {
  [[ "$PROTOCOL" == "reality" || "$PROTOCOL" == "ws-tls" ]] || err "--protocol 仅支持 reality 或 ws-tls"

  [[ "$LISTEN_PORT" =~ ^[0-9]+$ ]] || err "--listen-port 必须是数字"
  (( LISTEN_PORT >= 1 && LISTEN_PORT <= 65535 )) || err "--listen-port 超出范围"

  if [[ "$PROTOCOL" == "ws-tls" ]]; then
    [[ -n "$DOMAIN" ]] || err "ws-tls 模式需要 --domain"
  fi

  if [[ -z "$EMAIL" && -n "$DOMAIN" ]]; then
    EMAIL="admin@${DOMAIN}"
  fi

  if [[ -z "$WS_HOST" ]]; then
    WS_HOST="$DOMAIN"
  fi
}

check_port_free() {
  if ss -lntp 2>/dev/null | awk '{print $4}' | grep -q ":${LISTEN_PORT}$"; then
    err "端口 ${LISTEN_PORT} 已被占用，请换端口"
  fi
  ok "端口可用: ${LISTEN_PORT}"
}

apt_install_base() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl wget jq openssl ca-certificates gnupg lsb-release apt-transport-https socat qrencode
}

install_sing_box() {
  if command -v sing-box >/dev/null 2>&1; then
    ok "sing-box 已安装: $(sing-box version | head -n1)"
    return
  fi

  log "安装 sing-box 官方 APT 源"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://sing-box.app/gpg.key | gpg --dearmor -o /etc/apt/keyrings/sagernet.gpg
  chmod a+r /etc/apt/keyrings/sagernet.gpg

  local codename
  codename="$(lsb_release -cs)"

  cat >/etc/apt/sources.list.d/sagernet.list <<EOF
# SagerNet sing-box
# Ubuntu codename: ${codename}
deb [signed-by=/etc/apt/keyrings/sagernet.gpg] https://deb.sagernet.org/ ${codename} main
EOF

  apt-get update -y || {
    warn "按 codename 更新失败，回退到通配源 * *"
    cat >/etc/apt/sources.list.d/sagernet.list <<EOF
# SagerNet sing-box fallback
deb [signed-by=/etc/apt/keyrings/sagernet.gpg] https://deb.sagernet.org/ * *
EOF
    apt-get update -y
  }

  apt-get install -y sing-box
  ok "sing-box 安装完成: $(sing-box version | head -n1)"
}

gen_defaults() {
  if [[ -z "$UUID" ]]; then
    UUID="$(sing-box generate uuid)"
  fi

  if [[ -z "$SHORT_ID" ]]; then
    SHORT_ID="$(openssl rand -hex 8)"
  fi

  if [[ -z "$PUBLIC_HOST" ]]; then
    PUBLIC_HOST="$(curl -4s --max-time 8 https://api.ipify.org || true)"
  fi

  [[ -n "$PUBLIC_HOST" ]] || PUBLIC_HOST="YOUR_SERVER_IP"
}

install_acme_if_needed() {
  [[ "$PROTOCOL" == "ws-tls" ]] || return 0

  [[ -n "$DOMAIN" ]] || err "ws-tls 需要 domain"
  [[ -n "$EMAIL" ]] || err "ws-tls 需要 email"

  if [[ ! -x /root/.acme.sh/acme.sh ]]; then
    log "安装 acme.sh"
    curl -fsSL https://get.acme.sh | sh -s email="$EMAIL"
  fi
}

issue_cert_ws_tls() {
  [[ "$PROTOCOL" == "ws-tls" ]] || return 0

  local cert_dir="/etc/sing-box/certs"
  mkdir -p "$cert_dir"

  log "申请证书: ${DOMAIN}（standalone 模式，需占用 80 端口）"

  # 若 80 被占，提醒用户
  if ss -lntp 2>/dev/null | awk '{print $4}' | grep -q ':80$'; then
    warn "检测到 80 端口被占用，证书申请可能失败。将尝试先继续。"
  fi

  /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --force

  /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
    --key-file       "$cert_dir/${DOMAIN}.key" \
    --fullchain-file "$cert_dir/${DOMAIN}.crt" \
    --reloadcmd      "systemctl restart sing-box"

  ok "证书就绪: $cert_dir/${DOMAIN}.crt"
}

write_config_reality() {
  log "生成 reality 配置"

  local kp priv pub flow_field flow_line flow_qs
  kp="$(sing-box generate reality-keypair)"
  priv="$(echo "$kp" | awk '/PrivateKey/ {print $2}')"
  pub="$(echo "$kp" | awk '/PublicKey/ {print $2}')"

  flow_field=""
  flow_line=""
  flow_qs=""
  if [[ "$REQUIRE_VISION" == "true" ]]; then
    flow_field=',
          "flow": "xtls-rprx-vision"'
    flow_line='flow=xtls-rprx-vision'
    flow_qs='&flow=xtls-rprx-vision'
  fi

  mkdir -p /etc/sing-box
  cat >/etc/sing-box/config.json <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "0.0.0.0",
      "listen_port": ${LISTEN_PORT},
      "users": [
        {
          "uuid": "${UUID}"${flow_field}
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${SERVER_NAME}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${SERVER_NAME}",
            "server_port": 443
          },
          "private_key": "${priv}",
          "short_id": ["${SHORT_ID}"]
        }
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" }
  ],
  "route": {
    "final": "direct"
  }
}
EOF

  cat >/etc/sing-box/client-reality.txt <<EOF
# ===== 客户端参数（Reality） =====
server=${PUBLIC_HOST}
server_port=${LISTEN_PORT}
uuid=${UUID}
${flow_line}
security=reality
sni=${SERVER_NAME}
fp=chrome
pbk=${pub}
sid=${SHORT_ID}

# vless 链接：
vless://${UUID}@${PUBLIC_HOST}:${LISTEN_PORT}?encryption=none${flow_qs}&security=reality&sni=${SERVER_NAME}&fp=chrome&pbk=${pub}&sid=${SHORT_ID}&type=tcp#sb-reality-${PUBLIC_HOST}
EOF

  ok "已输出客户端参数: /etc/sing-box/client-reality.txt"
}

write_config_ws_tls() {
  log "生成 ws-tls 配置"

  local cert_dir="/etc/sing-box/certs"
  mkdir -p /etc/sing-box

  cat >/etc/sing-box/config.json <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "0.0.0.0",
      "listen_port": ${LISTEN_PORT},
      "users": [
        { "uuid": "${UUID}" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "certificate_path": "${cert_dir}/${DOMAIN}.crt",
        "key_path": "${cert_dir}/${DOMAIN}.key"
      },
      "transport": {
        "type": "ws",
        "path": "${WS_PATH}",
        "headers": {
          "Host": "${WS_HOST}"
        }
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" }
  ],
  "route": {
    "final": "direct"
  }
}
EOF

  cat >/etc/sing-box/client-ws-tls.txt <<EOF
# ===== 客户端参数（WS+TLS） =====
server=${DOMAIN}
server_port=${LISTEN_PORT}
uuid=${UUID}
network=ws
ws_path=${WS_PATH}
ws_host=${WS_HOST}
security=tls
sni=${DOMAIN}

# vless 链接：
vless://${UUID}@${DOMAIN}:${LISTEN_PORT}?encryption=none&security=tls&sni=${DOMAIN}&type=ws&host=${WS_HOST}&path=$(python3 - <<'PY'
import urllib.parse
print(urllib.parse.quote('${WS_PATH}', safe=''))
PY
)#sb-ws-tls-${DOMAIN}
EOF

  ok "已输出客户端参数: /etc/sing-box/client-ws-tls.txt"
}

disable_ipv6() {
  log "关闭 IPv6"

  cat >/etc/sysctl.d/99-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6     = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6      = 1
EOF

  sysctl --system -q 2>/dev/null || sysctl -p /etc/sysctl.d/99-disable-ipv6.conf

  # 持久化：GRUB 参数（重启后也生效）
  if [[ -f /etc/default/grub ]]; then
    if ! grep -q 'ipv6.disable=1' /etc/default/grub; then
      sed -i 's/^GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="ipv6.disable=1 /' /etc/default/grub
      update-grub 2>/dev/null || grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true
    fi
  fi

  ok "IPv6 已关闭"
}

tune_system() {
  log "系统性能优化（TCP/BBR/文件句柄）"

  cat >/etc/sysctl.d/99-vless-perf.conf <<'EOF'
# ── 网络缓冲区 ──────────────────────────────────────────────
net.core.rmem_max                   = 134217728
net.core.wmem_max                   = 134217728
net.core.rmem_default               = 1048576
net.core.wmem_default               = 1048576
net.core.netdev_max_backlog         = 250000
net.core.somaxconn                  = 4096

# ── TCP 优化 ─────────────────────────────────────────────────
net.ipv4.tcp_rmem                   = 4096 1048576 67108864
net.ipv4.tcp_wmem                   = 4096 1048576 67108864
net.ipv4.tcp_congestion_control     = bbr
net.core.default_qdisc              = fq
net.ipv4.tcp_fastopen               = 3
net.ipv4.tcp_slow_start_after_idle  = 0
net.ipv4.tcp_tw_reuse               = 1
net.ipv4.tcp_fin_timeout            = 15
net.ipv4.tcp_keepalive_time         = 300
net.ipv4.tcp_keepalive_intvl        = 15
net.ipv4.tcp_keepalive_probes       = 5
net.ipv4.tcp_max_syn_backlog        = 8192
net.ipv4.ip_local_port_range        = 1024 65535

# ── 文件句柄 ─────────────────────────────────────────────────
fs.file-max                         = 1048576
EOF

  sysctl --system -q 2>/dev/null || sysctl -p /etc/sysctl.d/99-vless-perf.conf

  # 提升进程文件句柄上限
  if ! grep -q 'singbox-limits' /etc/security/limits.conf; then
    cat >>/etc/security/limits.conf <<'LIMITS'
# singbox-limits
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
LIMITS
  fi

  # 验证 BBR 是否加载
  if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    ok "BBR 已启用"
  else
    warn "BBR 未能启用（内核可能不支持），已跳过"
  fi

  ok "系统性能优化完成"
}

write_systemd() {
  cat >/etc/systemd/system/sing-box.service <<'EOF'
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable sing-box
  systemctl restart sing-box
  systemctl --no-pager --full status sing-box | sed -n '1,10p'
  ok "sing-box 服务已启动"
}

open_firewall() {
  [[ "$SKIP_FIREWALL" == "true" ]] && { warn "已跳过防火墙配置"; return 0; }

  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${LISTEN_PORT}/tcp" || true
    [[ "$PROTOCOL" == "ws-tls" ]] && ufw allow 80/tcp || true
    ok "ufw 已放行端口"
    return
  fi

  if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport "$LISTEN_PORT" -j ACCEPT 2>/dev/null || \
      iptables -I INPUT -p tcp --dport "$LISTEN_PORT" -j ACCEPT
    if [[ "$PROTOCOL" == "ws-tls" ]]; then
      iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p tcp --dport 80 -j ACCEPT
    fi
    warn "已使用 iptables 放行，注意规则持久化"
    return
  fi

  warn "未检测到 ufw/iptables，请手动放行端口 ${LISTEN_PORT}"
}

print_summary() {
  echo ""
  echo "============================================================"
  ok "部署完成"
  echo "protocol      : ${PROTOCOL}"
  echo "listen_port   : ${LISTEN_PORT}"
  echo "uuid          : ${UUID}"
  echo "public_host   : ${PUBLIC_HOST}"

  if [[ "$PROTOCOL" == "reality" ]]; then
    echo "sni           : ${SERVER_NAME}"
    echo "client file   : /etc/sing-box/client-reality.txt"
  else
    echo "domain        : ${DOMAIN}"
    echo "ws_path       : ${WS_PATH}"
    echo "client file   : /etc/sing-box/client-ws-tls.txt"
  fi

  echo "config        : /etc/sing-box/config.json"
  echo "service       : systemctl status sing-box"
  echo "logs          : journalctl -u sing-box -f"
  echo "============================================================"
  echo ""
}

print_client_export() {
  local client_file=""
  local raw_link=""

  if [[ "$PROTOCOL" == "reality" ]]; then
    client_file="/etc/sing-box/client-reality.txt"
  else
    client_file="/etc/sing-box/client-ws-tls.txt"
  fi

  [[ -f "$client_file" ]] || return 0

  raw_link="$(grep -E '^vless://' "$client_file" | tail -n1 || true)"

  echo "======================= CLIENT EXPORT ======================="
  echo "copy_file     : ${client_file}"
  echo ""
  echo "----- BEGIN CLIENT PARAMS -----"
  cat "$client_file"
  echo "----- END CLIENT PARAMS -----"

  if [[ -n "$raw_link" ]]; then
    echo ""
    echo "----- BEGIN VLESS URI -----"
    echo "$raw_link"
    echo "----- END VLESS URI -----"
  fi

  if command -v qrencode >/dev/null 2>&1 && [[ -n "$raw_link" ]]; then
    echo ""
    echo "二维码（终端）:"
    qrencode -t ANSIUTF8 "$raw_link" || true
  fi

  echo "============================================================"
  echo ""
}

main() {
  parse_args "$@"
  require_root
  check_ubuntu
  match_arch
  validate_args
  check_port_free

  log "安装基础依赖"
  apt_install_base

  disable_ipv6
  tune_system
  install_sing_box
  gen_defaults
  open_firewall

  if [[ "$PROTOCOL" == "ws-tls" ]]; then
    install_acme_if_needed
    issue_cert_ws_tls
    write_config_ws_tls
  else
    write_config_reality
  fi

  write_systemd
  print_summary
  print_client_export
}

main "$@"
