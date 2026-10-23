#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0" >&2; exit 1; }

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
  firewall-cmd --permanent --add-port=6443/tcp
  firewall-cmd --permanent --add-port=8472/udp
  firewall-cmd --permanent --add-port=10250/tcp
  firewall-cmd --reload
fi

curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --write-kubeconfig-mode 644" sh -

systemctl enable --now k3s
echo "K3s control plane ready."
echo "Server IP: $(hostname -I | awk '{print $1}')"
echo "Join token:"
cat /var/lib/rancher/k3s/server/node-token
echo "Check: /usr/local/bin/k3s kubectl get nodes -o wide"
