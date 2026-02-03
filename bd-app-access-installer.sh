#!/bin/bash
set -e

DOMAIN="dns1.alamindev.site"
EMAIL="scbuild24@gmail.com"

echo "🔐 Installing Clean Private DNS + Selective Routing"

# -----------------------------
# System
# -----------------------------
apt update && apt upgrade -y
apt install -y curl wget unzip tar socat ufw

# -----------------------------
# Firewall
# -----------------------------
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 853
ufw --force enable

# -----------------------------
# SSL via acme.sh
# -----------------------------
curl https://get.acme.sh | sh
source ~/.bashrc
~/.acme.sh/acme.sh --register-account -m $EMAIL
~/.acme.sh/acme.sh --issue --standalone -d $DOMAIN

mkdir -p /etc/ssl/private /etc/ssl/certs
~/.acme.sh/acme.sh --install-cert -d $DOMAIN \
--key-file /etc/ssl/private/dns.key \
--fullchain-file /etc/ssl/certs/dns.crt

# -----------------------------
# AdGuard Home
# -----------------------------
cd /opt
curl -L https://static.adguard.com/adguardhome/release/AdGuardHome_linux_amd64.tar.gz | tar xz
cd AdGuardHome
./AdGuardHome -s install

# -----------------------------
# Sing-box
# -----------------------------
bash <(curl -fsSL https://sing-box.app/install.sh)

mkdir -p /etc/sing-box

cat > /etc/sing-box/config.json <<EOF
{
  "log": { "level": "info" },
  "dns": {
    "servers": [
      { "tag": "local", "address": "1.1.1.1" },
      { "tag": "bd", "address": "8.8.8.8", "detour": "bd-out" }
    ],
    "rules": [
      { "domain": ["bkash.com","nagad.com.bd","rocket.com.bd"], "server": "bd" }
    ]
  },
  "outbounds": [
    {
      "tag": "bd-out",
      "type": "socks",
      "server": "BD_PROXY_IP",
      "server_port": 1080
    },
    {
      "tag": "direct",
      "type": "direct"
    }
  ]
}
EOF

systemctl enable sing-box
systemctl restart sing-box

echo "✅ Installation Done"
echo "🔐 Private DNS Hostname: $DOMAIN"
echo "🌐 AdGuard Panel: http://$(curl -s ifconfig.me):3000"
