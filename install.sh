#!/usr/bin/env bash
# Установка NaiveProxy (Caddy + sing-box). Запускается прямо на VPS.

set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: sudo $0 domain email" >&2
  exit 1
fi

# Нужен root
if [ "$(id -u)" -ne 0 ]; then
  exit 1
fi

DOMAIN="$1"
EMAIL="$2"

log() { echo -e "\n==> $*"; }
gen() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "$1"; }

# Без openssl нечем генерировать креды, а curl/gnupg нужны дальше
apt-get update -qq
apt-get install -y -qq openssl curl gnupg ca-certificates dnsutils >/dev/null

PROXY_LOGIN="${PROXY_LOGIN:-$(gen 16)}"
PROXY_PASSWORD="${PROXY_PASSWORD:-$(gen 24)}"

# --- Проверка DNS ---
echo "Проверка DNS"
SERVER_IP="$(curl -4 -fsS https://ifconfig.me || true)"
DNS_IPS="$(nslookup -type=A "$DOMAIN" 1.1.1.1 2>/dev/null \
  | awk '/^Name:/{f=1} f && /^Address:/{print $2}' || true)"
if [ -z "$SERVER_IP" ]; then
  echo "Не удалось определить внешний IP сервера, проверку DNS пропускаю."
elif printf '%s\n' "$DNS_IPS" | grep -qxF "$SERVER_IP"; then
  echo "DNS ок: $DOMAIN -> $SERVER_IP"
else
  echo "ВНИМАНИЕ: $DOMAIN -> '$(echo "$DNS_IPS" | paste -sd, -)', а IP сервера $SERVER_IP."
  echo "Caddy не выпустит сертификат, пока A-запись не совпадёт."
fi

# --- Caddy ---
if ! command -v caddy >/dev/null; then
  echo "Установка Caddy"
  apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    > /etc/apt/sources.list.d/caddy-stable.list
  chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
            /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq
  apt-get install -y -qq caddy
else
  echo "Caddy уже установлен, пропускаю"
fi

# --- sing-box ---
if ! command -v sing-box >/dev/null; then
  echo "Установка sing-box"
  case "$(uname -m)" in
    x86_64)  ARCH=amd64 ;;
    aarch64) ARCH=arm64 ;;
    *) echo "Неподдерживаемая архитектура: $(uname -m)" >&2; exit 1 ;;
  esac
  VERSION="$(curl -fsS https://api.github.com/repos/SagerNet/sing-box/releases/latest \
    | grep tag_name | cut -d '"' -f 4 | tr -d 'v')"
  TMP="$(mktemp -d)"
  curl -fsSL -o "$TMP/sb.tar.gz" \
    "https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-${ARCH}.tar.gz"
  tar -xzf "$TMP/sb.tar.gz" -C "$TMP"
  install -o root -g root -m 755 "$TMP"/sing-box-*/sing-box /usr/local/bin/sing-box
  rm -rf "$TMP"
else
  echo "sing-box уже установлен, пропускаю"
fi

# --- Пользователь и каталоги ---
echo "Пользователь и каталоги"
if getent passwd sing-box >/dev/null; then
  echo "Пользователь sing-box уже существует, пропускаю"
else
  useradd -r -s /usr/sbin/nologin -d /etc/sing-box sing-box
fi
mkdir -p /etc/sing-box /var/log/sing-box /var/log/caddy /var/www/html
chown -R sing-box:sing-box /etc/sing-box /var/log/sing-box
chown -R caddy:caddy /var/log/caddy

# --- Конфиг sing-box ---
echo "Конфиг sing-box"
cat > /etc/sing-box/config.json <<CFG_EOF
{
  "log": {
    "level": "warn",
    "output": "/var/log/sing-box/sing-box.log"
  },
  "dns": {
    "servers": [
      { "type": "local", "tag": "local" }
    ]
  },
  "inbounds": [
    {
      "type": "naive",
      "tag": "naive-in",
      "network": "tcp",
      "listen": "127.0.0.1",
      "listen_port": 1080,
      "users": [
        {
          "username": "${PROXY_LOGIN}",
          "password": "${PROXY_PASSWORD}"
        }
      ]
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "domain_resolver": {
        "server": "local",
        "strategy": "ipv4_only"
      }
    }
  ]
}
CFG_EOF
chown sing-box:sing-box /etc/sing-box/config.json
chmod 640 /etc/sing-box/config.json
sing-box check -c /etc/sing-box/config.json

# --- systemd unit ---
echo "systemd unit"
cat > /etc/systemd/system/sing-box.service <<UNIT_EOF
[Unit]
Description=sing-box Service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
Type=simple
User=sing-box
Group=sing-box
AmbientCapabilities=CAP_NET_BIND_SERVICE
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=true
ReadWritePaths=/var/log/sing-box /etc/sing-box

[Install]
WantedBy=multi-user.target
UNIT_EOF

# --- Сайт-заглушка ---
if [ ! -f /var/www/html/index.html ]; then
  echo "Сайт-заглушка"
  cat > /var/www/html/index.html <<HTML_EOF
<!doctype html>
<html lang="ru">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Server is running</title>
  <style>
    body {
      margin: 0;
      font-family: Arial, sans-serif;
      text-align: center;
      padding-top: 80px;
    }

    h1 {
      margin-bottom: 10px;
    }

    p {
      color: #555;
    }
  </style>
</head>
<body>
  <h1>Сервер работает</h1>
  <p>Это простая страница-заглушка для Caddy.</p>
</body>
</html>
HTML_EOF
fi
chown -R caddy:caddy /var/www/html
chmod -R 755 /var/www/html

# --- Caddyfile ---
echo "Caddyfile"
B64="$(printf '%s' "${PROXY_LOGIN}:${PROXY_PASSWORD}" | base64 -w0)"
cat > /etc/caddy/Caddyfile <<CADDY_EOF
{
	email ${EMAIL}
	auto_https disable_redirects
}

:443, https://${DOMAIN} {
	tls {
		issuer acme {
			disable_http_challenge
		}
	}

	log {
		output file /var/log/caddy/access.log {
			roll_size 100mb
			roll_keep 7
			roll_keep_for 168h
		}
		format json
		level INFO
	}

	route {
		@naive {
			method CONNECT
			header Proxy-Authorization "Basic ${B64}"
		}

		handle @naive {
			reverse_proxy h2c://127.0.0.1:1080
		}

		handle {
			root * /var/www/html
			file_server
		}
	}
}
CADDY_EOF
chown root:caddy /etc/caddy/Caddyfile
chmod 640 /etc/caddy/Caddyfile
caddy fmt --overwrite /etc/caddy/Caddyfile
caddy validate --config /etc/caddy/Caddyfile

# --- Файрвол (только если ufw активен) ---
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  echo "ufw: разрешаю 443/tcp"
  ufw allow 443/tcp
fi

# --- Запуск ---
echo "Запуск сервисов"
systemctl daemon-reload
systemctl enable --now sing-box
systemctl restart sing-box
systemctl enable caddy
systemctl restart caddy

# --- Итог ---

KEY="naive+https://${PROXY_LOGIN}:${PROXY_PASSWORD}@${DOMAIN}:443"
echo
echo "================ ГОТОВО ================"
echo "Логин:  $PROXY_LOGIN"
echo "Пароль: $PROXY_PASSWORD"
echo
echo "Ключ для клиента:"
echo "$KEY"
echo
echo "========================================"