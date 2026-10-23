#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0 SERVER_IP [TOKEN] [NODE_NAME]" >&2; exit 1; }
[[ $# -ge 1 ]] || { echo "Usage: sudo $0 SERVER_IP [TOKEN] [NODE_NAME]" >&2; exit 2; }

SERVER_IP=$1
TOKEN=${K3S_TOKEN:-${2:-}}
NODE_NAME=${3:-$(hostname -s)}
[[ -n $TOKEN ]] || { echo "Set K3S_TOKEN or pass TOKEN as the second argument" >&2; exit 2; }

if systemctl is-active --quiet k3s; then
  echo "k3s.service is active; this host is configured as a server, not an agent" >&2
  exit 1
fi

command -v curl >/dev/null || {
  if command -v dnf >/dev/null; then dnf install -y curl
  else echo "curl is required" >&2; exit 1; fi
}

if command -v dnf >/dev/null; then
  dnf install -y iptables iproute-tc socat conntrack-tools || true
  dnf install -y "kernel-modules-extra-$(uname -r)" || dnf install -y kernel-modules-extra || true
fi

modprobe overlay 2>/dev/null || true
modprobe br_netfilter 2>/dev/null || true
cat >/etc/sysctl.d/99-k3s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system >/dev/null

if command -v firewall-cmd >/dev/null && systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port=8472/udp
  firewall-cmd --permanent --add-port=10250/tcp
  firewall-cmd --reload
fi

curl -sfL https://get.k3s.io | env \
  K3S_URL="https://${SERVER_IP}:6443" \
  K3S_TOKEN="${TOKEN}" \
  INSTALL_K3S_EXEC="agent --node-name ${NODE_NAME}" \
  sh -

systemctl enable --now k3s-agent
echo "K3s node joined: ${NODE_NAME}"
