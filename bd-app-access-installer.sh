#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
#  Private DoH Server Auto-Setup for bKash/Nagad/Rocket Geo-Bypass
#  Domain     : bkdns.shop
#  VPS IP     : 167.235.48.96
#  Email      : scbuild24@gmail.com
#  Zone ID    : ae28459b7ca62debaba87329cbc13555
#  Cloudflare Global API Key : -2bbba8028a4ceb628b79e4c21feb35339b0c0
#  Upstream DNS (BD-like) : 103.145.164.32
# ──────────────────────────────────────────────────────────────────────────────

# Variables (edit only if needed)
DOMAIN="bkdns.shop"
VPS_IP="167.235.48.96"
EMAIL="scbuild24@gmail.com"
CF_ZONE_ID="ae28459b7ca62debaba87329cbc13555"
CF_API_KEY="-2bbba8028a4ceb628b79e4c21feb35339b0c0"   # Global API Key (not token)
UPSTREAM_DNS="103.145.164.32"                          # Change if not working

SUBDOMAIN="dns.${DOMAIN}"                              # Recommended for Private DNS: dns.bkdns.shop
DOH_PATH="/dns-query"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}Starting private DoH setup for ${DOMAIN} ...${NC}\n"

# 1. Update & install basics
apt update && apt upgrade -y
apt install -y curl wget nano net-tools ufw software-properties-common

# 2. Firewall: allow SSH + HTTP + HTTPS
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# 3. Install Unbound (recursive resolver)
apt install -y unbound

cat <<EOF > /etc/unbound/unbound.conf.d/10-private-resolver.conf
server:
    verbosity: 1
    interface: 127.0.0.1
    port: 5335
    do-ip4: yes
    do-ip6: no
    do-udp: yes
    do-tcp: yes
    access-control: 127.0.0.0/8 allow
    access-control: 10.0.0.0/8 allow
    access-control: 172.16.0.0/12 allow
    access-control: 192.168.0.0/16 allow
    hide-identity: yes
    hide-version: yes
    harden-glue: yes
    harden-dnssec-stripped: yes
    cache-min-ttl: 300
    cache-max-ttl: 86400
    prefetch: yes
    qname-minimisation: yes

forward-zone:
    name: "."
    forward-addr: ${UPSTREAM_DNS}
    # Add more BD DNS if you find better ones, e.g.:
    # forward-addr: 103.77.188.18
    # forward-addr: 103.77.188.19
EOF

systemctl restart unbound
systemctl enable unbound

# Quick local test
dig @127.0.0.1 -p 5335 google.com +short || { echo -e "${RED}Unbound failed!${NC}"; exit 1; }

# 4. Install cloudflared (DoH frontend)
wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
dpkg -i cloudflared-linux-amd64.deb || apt install -f -y

mkdir -p /etc/cloudflared
cat <<EOF > /etc/cloudflared/config.yml
proxy-dns: true
proxy-dns-port: 5053
proxy-dns-upstream:
  - 127.0.0.1:5335
proxy-dns-no-ipv6: true
loglevel: info
EOF

cloudflared service install
systemctl start cloudflared
systemctl enable cloudflared

# Test
dig @127.0.0.1 -p 5053 example.com +short || { echo -e "${RED}cloudflared failed!${NC}"; exit 1; }

# 5. Install Nginx + Certbot with Cloudflare plugin
apt install -y nginx certbot python3-certbot-dns-cloudflare

# Cloudflare credentials (Global API Key format)
mkdir -p /root/.secrets
cat <<EOF > /root/.secrets/cloudflare.ini
dns_cloudflare_email = ${EMAIL}
dns_cloudflare_api_key = ${CF_API_KEY}
EOF
chmod 600 /root/.secrets/cloudflare.ini

# Get certificate (use --preferred-challenges dns)
certbot certonly --non-interactive --agree-tos --email "${EMAIL}" \
  --dns-cloudflare --dns-cloudflare-credentials /root/.secrets/cloudflare.ini \
  --dns-cloudflare-propagation-seconds 60 \
  -d "${DOMAIN}" -d "${SUBDOMAIN}"

# 6. Nginx config for DoH
cat <<EOF > /etc/nginx/sites-available/doh
server {
    listen 80;
    server_name ${DOMAIN} ${SUBDOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN} ${SUBDOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    location ${DOH_PATH} {
        proxy_pass http://127.0.0.1:5053/dns-query;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 90s;
        proxy_connect_timeout 90s;
    }

    location / {
        return 200 "Private DoH - use ${SUBDOMAIN} in Android Private DNS";
        add_header Content-Type text/plain;
    }
}
EOF

ln -sf /etc/nginx/sites-available/doh /etc/nginx/sites-enabled/
nginx -t || { echo -e "${RED}Nginx config error!${NC}"; exit 1; }
systemctl restart nginx

# 7. Final info
echo -e "\n${GREEN}Setup completed!${NC}"
echo "1. Add these A records in Cloudflare (DNS only / grey cloud):"
echo "   - ${DOMAIN}      → ${VPS_IP}"
echo "   - ${SUBDOMAIN}   → ${VPS_IP}"
echo "   Wait 5-30 min for DNS propagation."
echo ""
echo "2. On Android → Settings → Network → Private DNS → hostname:"
echo "   → ${SUBDOMAIN}"
echo ""
echo "3. Test DoH:"
echo "   curl -s -H 'accept: application/dns-json' 'https://${SUBDOMAIN}${DOH_PATH}?name=google.com&type=A'"
echo ""
echo "4. Check logs if needed:"
echo "   journalctl -u unbound -f"
echo "   journalctl -u cloudflared -f"
echo "   tail -f /var/log/nginx/error.log"
echo ""
echo -e "${GREEN}Good luck with bKash / Nagad / Rocket! If still blocked → it's probably client IP check → need BD VPN.${NC}"
