#!/usr/bin/env bash
# ssh-hardening.sh — SSH hardening + interactive key setup
# Usage: sudo bash ssh-hardening.sh [--port PORT] [--user USERNAME]

set -euo pipefail

# ─── Parse args ───────────────────────────────────────────────────────────────
SSH_PORT=22
TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "")}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) SSH_PORT="$2"; shift 2 ;;
    --user) TARGET_USER="$2"; shift 2 ;;
    *)      shift ;;
  esac
done

if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
  echo "Для какого пользователя добавить ключ? (не root)"
  read -rp "Имя пользователя: " TARGET_USER
fi

TARGET_HOME=$(eval echo "~$TARGET_USER")

# ─── Root check ───────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "Запусти от root: sudo bash $0" >&2
  exit 1
fi

# ─── Step 1: Get public key from user ─────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Шаг 1: Создай SSH-ключ на Windows (если ещё нет)           ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║                                                              ║"
echo "║  Открой PowerShell и выполни:                               ║"
echo "║    ssh-keygen -t ed25519 -C \"my-server\"                     ║"
echo "║                                                              ║"
echo "║  Затем скопируй публичный ключ:                             ║"
echo "║    cat ~\.ssh\id_ed25519.pub                                 ║"
echo "║                                                              ║"
echo "║  Он выглядит так:                                           ║"
echo "║    ssh-ed25519 AAAA....... my-server                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Вставь публичный ключ и нажми Enter:"
read -rp "> " PUBLIC_KEY

# ─── Validate key format ──────────────────────────────────────────────────────
KEY_TYPES="ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|ssh-rsa"
if ! echo "$PUBLIC_KEY" | grep -qE "^($KEY_TYPES) [A-Za-z0-9+/=]+ ?"; then
  echo ""
  echo "  ✗ Ключ не распознан. Убедись, что скопировал строку из файла .pub"
  echo "    Пример: ssh-ed25519 AAAAC3Nza... my-server"
  exit 1
fi
echo "  ✓ Ключ распознан"

# ─── Install key ──────────────────────────────────────────────────────────────
SSH_DIR="$TARGET_HOME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# Не дублировать, если ключ уже есть
if grep -qF "$PUBLIC_KEY" "$AUTH_KEYS" 2>/dev/null; then
  echo "  ✓ Ключ уже добавлен, пропускаем"
else
  echo "$PUBLIC_KEY" >> "$AUTH_KEYS"
  echo "  ✓ Ключ добавлен в $AUTH_KEYS"
fi

chmod 600 "$AUTH_KEYS"
chown -R "$TARGET_USER:$TARGET_USER" "$SSH_DIR"

# ─── Step 2: Harden sshd_config ───────────────────────────────────────────────
echo ""
echo "==> Шаг 2: Настройка sshd"

SSHD_CONFIG="/etc/ssh/sshd_config"
cp "$SSHD_CONFIG" "$SSHD_CONFIG.backup.$(date +%Y%m%d_%H%M%S)"

apply() {
  local key="$1" value="$2"
  if grep -qE "^\s*#?\s*${key}\s" "$SSHD_CONFIG"; then
    sed -i -E "s|^\s*#?\s*${key}\s.*|${key} ${value}|" "$SSHD_CONFIG"
  else
    echo "${key} ${value}" >> "$SSHD_CONFIG"
  fi
}

apply Port                          "$SSH_PORT"
apply Protocol                      2
apply PermitRootLogin               no
apply PasswordAuthentication        no
apply PermitEmptyPasswords          no
apply ChallengeResponseAuthentication no
apply PubkeyAuthentication          yes
apply AuthorizedKeysFile            ".ssh/authorized_keys"
apply MaxAuthTries                  3
apply LoginGraceTime                30
apply ClientAliveInterval           300
apply ClientAliveCountMax           2
apply X11Forwarding                 no
apply AllowTcpForwarding            no
apply LogLevel                      VERBOSE

sshd -t && echo "    Config OK"

# ─── Step 3: fail2ban ─────────────────────────────────────────────────────────
echo ""
echo "==> Шаг 3: fail2ban"
apt-get update -qq
apt-get install -y fail2ban > /dev/null

cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled  = true
port     = $SSH_PORT
maxretry = 5
findtime = 600
bantime  = 3600
backend  = systemd
EOF

systemctl enable --now fail2ban > /dev/null
systemctl restart fail2ban
echo "    5 попыток / 10 мин → бан на 1 час"

# ─── Step 4: UFW ──────────────────────────────────────────────────────────────
echo ""
echo "==> Шаг 4: UFW"
command -v ufw &>/dev/null || apt-get install -y ufw > /dev/null
ufw allow "$SSH_PORT"/tcp comment "SSH" > /dev/null
ufw --force enable > /dev/null
ufw reload > /dev/null
echo "    Порт $SSH_PORT открыт"

# ─── Restart SSH ──────────────────────────────────────────────────────────────
systemctl restart sshd

# ─── Done ─────────────────────────────────────────────────────────────────────
SERVER_IP=$(hostname -I | awk '{print $1}')
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Готово! SSH защищён                                         ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Пользователь : $TARGET_USER"
echo "  Порт         : $SSH_PORT"
echo "  Вход по паролю: отключён (только ключ)"
echo ""
echo "  Подключись из Windows (не закрывая этот сеанс!):"
echo ""
echo "    ssh -p $SSH_PORT -i ~\\.ssh\\id_ed25519 $TARGET_USER@$SERVER_IP"
echo ""
echo "  Убедись, что вход работает, ПЕРЕД закрытием текущего сеанса."