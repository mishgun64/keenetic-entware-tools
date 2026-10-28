#!/bin/sh
# Первоначальная настройка Keenetic + Entware
# Запуск: sh setup-keenetic.sh (от root, из интерактивного терминала)

set -eu

SSH_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOrAkVqWbPt82Bc0CRPjzGgvpVqmuqkdAQLjZQwxgoVd heimc@DESKTOP-LSDOR4T'
AUTH_KEYS=/opt/etc/dropbear/authorized_keys

log() { printf '\n==> %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "Нужен root" >&2; exit 1; }
[ -x /opt/bin/opkg ] || { echo "Entware (/opt/bin/opkg) не найден" >&2; exit 1; }

export PATH=/opt/bin:/opt/sbin:$PATH

# 1. SSH-ключ
log "SSH-ключ -> $AUTH_KEYS"
mkdir -p "$(dirname "$AUTH_KEYS")"
touch "$AUTH_KEYS"
grep -qxF "$SSH_KEY" "$AUTH_KEYS" || echo "$SSH_KEY" >> "$AUTH_KEYS"
chmod 700 "$(dirname "$AUTH_KEYS")"
chmod 600 "$AUTH_KEYS"

# 2. Пароль root (по запросу)
log "Пароль root"
printf 'Сменить пароль root? [y/N] '
read -r ans || ans=n
case "$ans" in
    y|Y|yes|YES) passwd root ;;
    *) echo "Пропущено" ;;
esac

# 3. Пакеты
log "Установка пакетов"
opkg update
opkg install cron nmap neovim htop

# 4. Алиасы root
log "Алиасы"
PROFILE="${HOME:-/opt/root}/.profile"
mkdir -p "$(dirname "$PROFILE")"
touch "$PROFILE"
grep -qxF "alias v='nvim'" "$PROFILE" || echo "alias v='nvim'" >> "$PROFILE"
grep -qxF "alias ll='ls -lh'" "$PROFILE" || echo "alias ll='ls -lah'" >> "$PROFILE"

# 5. Cron: ежедневный opkg upgrade
log "Cron daily opkg-upgrade"
mkdir -p /opt/etc/cron.daily /opt/var/log
cat > /opt/etc/cron.daily/opkg-upgrade <<'EOF'
#!/bin/sh
/opt/bin/opkg update && /opt/bin/opkg upgrade >> /opt/var/log/opkg-upgrade.log 2>&1
EOF
chmod +x /opt/etc/cron.daily/opkg-upgrade
[ -x /opt/etc/init.d/S10cron ] && /opt/etc/init.d/S10cron restart || true

# 6. nfqws2-keenetic + nfqws-keenetic-web
log "nfqws2-keenetic / nfqws-keenetic-web"
opkg update
opkg install ca-certificates wget-ssl
opkg remove wget-nossl || true
mkdir -p /opt/etc/opkg
echo "src/gz nfqws2-keenetic https://nfqws.github.io/nfqws2-keenetic/all" > /opt/etc/opkg/nfqws2-keenetic.conf
echo "src/gz nfqws-keenetic-web https://nfqws.github.io/nfqws-keenetic-web/all" > /opt/etc/opkg/nfqws-keenetic-web.conf
opkg update
opkg install nfqws2-keenetic
opkg install nfqws-keenetic-web

log "Готово"