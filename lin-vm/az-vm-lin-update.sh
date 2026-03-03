#!/usr/bin/env bash
set -euo pipefail
exec 2>&1

VM_USER="manager"
VM_PASS="<runtime-secret>"
SSHD_CONFIG="/etc/ssh/sshd_config"

echo "Update phase started."

if ! id -u "${VM_USER}" >/dev/null 2>&1; then
  sudo useradd -m -s /bin/bash "${VM_USER}"
fi

echo "${VM_USER}:${VM_PASS}" | sudo chpasswd
echo "root:${VM_PASS}" | sudo chpasswd
sudo passwd -u "${VM_USER}" || true
sudo passwd -u root || true
sudo chage -E -1 "${VM_USER}" || true
sudo chage -E -1 root || true

sudo DEBIAN_FRONTEND=noninteractive apt update -y
sudo DEBIAN_FRONTEND=noninteractive apt install --upgrade -y apt-utils ufw nodejs npm git curl python-is-python3 python3-venv

sudo sed -i -E 's/^#?Port .*/Port 444/' "${SSHD_CONFIG}"
sudo sed -i -E 's/^#?PasswordAuthentication .*/PasswordAuthentication yes/' "${SSHD_CONFIG}"
sudo sed -i -E 's/^#?PubkeyAuthentication .*/PubkeyAuthentication no/' "${SSHD_CONFIG}"
sudo sed -i -E 's/^#?PermitRootLogin .*/PermitRootLogin yes/' "${SSHD_CONFIG}"
sudo sed -i -E 's/^#?AllowTcpForwarding .*/AllowTcpForwarding yes/' "${SSHD_CONFIG}"
sudo sed -i -E 's/^#?GatewayPorts .*/GatewayPorts yes/' "${SSHD_CONFIG}"

sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
TCP_PORTS=(80 443 444 8444 3389 389 5173 3000 3001 8080 5432 3306 6837 4000 4001 5000 5001 6000 6001 6060 7000 7001 7070 8000 8001 9000 9001 9090 2222 3333 4444 5555 6666 7777 8888 9999 11434)
for PORT in "${TCP_PORTS[@]}"; do
  sudo ufw allow "${PORT}/tcp"
done

sudo ufw --force enable
sudo setcap 'cap_net_bind_service=+ep' /usr/bin/node || true
sudo setcap 'cap_net_bind_service=+ep' /usr/sbin/sshd || true

sudo systemctl daemon-reload
sudo systemctl disable --now ssh.socket || true
sudo systemctl unmask ssh.service || true
sudo systemctl enable --now ssh.service
sudo systemctl restart ssh.service

echo "Version Info:"
lsb_release -a || true

echo "OPEN Ports:"
ss -tlnp | grep -E ':(80|443|444|8444|3389|389|5173|3000|3001|8080|5432|3306|6837|4000|4001|5000|5001|6000|6001|6060|7000|7001|7070|8000|8001|9000|9001|9090|2222|3333|4444|5555|6666|7777|8888|9999|11434)\b' || true

echo "Firewall STATUS:"
sudo ufw status verbose

echo "SSHD CONFIG:"
grep -E "^(Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|AllowTcpForwarding|GatewayPorts)" "${SSHD_CONFIG}" || true

echo "Update phase completed."
