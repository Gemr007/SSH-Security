#!/usr/bin/env bash
# ssh-hardening.sh — SSH hardening + interactive key setup
# Usage: sudo bash ssh-hardening.sh [--port PORT] [--user USERNAME]

set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────
R='\033[0;31m'
G='\033[0;32m'
Y='\033[0;33m'
C='\033[0;36m'
W='\033[1;37m'
D='\033[2;37m'
NC='\033[0m'

OK="${G}✔${NC}"
ERR="${R}✘${NC}"
INFO="${C}→${NC}"
WARN="${Y}!${NC}"

line() { echo -e "${D}────────────────────────────────────────────────────────────${NC}"; }

banner() {
  clear
  echo ""
  echo -e "${C}"
  echo "  ███████╗███████╗██╗  ██╗"
  echo "  ██╔════╝██╔════╝██║  ██║"
  echo "  ███████╗███████╗███████║"
  echo "  ╚════██║╚════██║██╔══██║"
  echo "  ███████║███████║██║  ██║"
  echo "  ╚══════╝╚══════╝╚═╝  ╚═╝  ${W}Hardening Script${C} v2.0"
  echo -e "${NC}"
  line
  echo ""
}

step() {
  echo ""
  echo -e "${W}  ▸ $1${NC}"
  line
}

ok()   { echo -e "  ${OK}  $1"; }
err()  { echo -e "  ${ERR}  ${R}$1${NC}"; }
info() { echo -e "  ${INFO}  $1"; }
warn() { echo -e "  ${WARN}  ${Y}$1${NC}"; }

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

# ─── Root check ───────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  err "Требуются права root: sudo bash $0"
  exit 1
fi

banner

# ─── Ask for username ─────────────────────────────────────────────────────────
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
  echo -e "  ${W}Для какого пользователя настраиваем доступ?${NC}"
  echo -e "  ${D}(не root — будет создан автоматически, если не существует)${NC}"
  echo ""
  read -rp "  Имя пользователя: " TARGET_USER
fi

# ─── Create user if doesn't exist ────────────────────────────────────────────
if ! id "$TARGET_USER" &>/dev/null; then
  echo ""
  warn "Пользователь '${TARGET_USER}' не найден — создаю..."
  useradd -m -s /bin/bash "$TARGET_USER"
  ok "Пользователь '${TARGET_USER}' создан"
  echo ""
  info "Установи пароль (нужен для sudo):"
  passwd "$TARGET_USER"
fi

TARGET_HOME=$(eval echo "~$TARGET_USER")

# ─── Step 1: SSH Key ──────────────────────────────────────────────────────────
step "Шаг 1 из 4 — SSH-ключ"

echo ""
echo -e "  ${D}Если ключа ещё нет, создай его в PowerShell:${NC}"
echo ""
echo -e "  ${C}  ssh-keygen -t ed25519 -C \"my-server\"${NC}"
echo -e "  ${C}  cat ~\\.ssh\\id_ed25519.pub${NC}"
echo ""
echo -e "  ${D}Выглядит примерно так:${NC}"
echo -e "  ${D}  ssh-ed25519 AAAAC3Nza... my-server${NC}"
echo ""
echo -e "  ${W}Вставь публичный ключ и нажми Enter:${NC}"
echo ""
read -rp "  > " PUBLIC_KEY

KEY_TYPES="ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|ssh-rsa"
if ! echo "$PUBLIC_KEY" | grep -qE "^($KEY_TYPES) [A-Za-z0-9+/=]+ ?"; then
  echo ""
  err "Ключ не распознан. Убедись, что скопировал строку из .pub файла"
  exit 1
fi
ok "Ключ распознан"

SSH_DIR="$TARGET_HOME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if grep -qF "$PUBLIC_KEY" "$AUTH_KEYS" 2>/dev/null; then
  warn "Ключ уже был добавлен ранее — пропускаем"
else
  echo "$PUBLIC_KEY" >> "$AUTH_KEYS"
  ok "Ключ записан в ${AUTH_KEYS}"
fi

chmod 600 "$AUTH_KEYS"
chown -R "$TARGET_USER:$TARGET_USER" "$SSH_DIR"

# ─── Step 2: sshd_config ──────────────────────────────────────────────────────
step "Шаг 2 из 4 — Настройка sshd"

SSHD_CONFIG="/etc/ssh/sshd_config"
BACKUP="$SSHD_CONFIG.backup.$(date +%Y%m%d_%H%M%S)"
cp "$SSHD_CONFIG" "$BACKUP"
ok "Резервная копия: ${BACKUP}"

apply() {
  local key="$1" value="$2"
  if grep -qE "^\s*#?\s*${key}\s" "$SSHD_CONFIG"; then
    sed -i -E "s|^\s*#?\s*${key}\s.*|${key} ${value}|" "$SSHD_CONFIG"
  else
    echo "${key} ${value}" >> "$SSHD_CONFIG"
  fi
}

apply Port                              "$SSH_PORT"
apply Protocol                          2
apply PermitRootLogin                   no
apply PasswordAuthentication            no
apply PermitEmptyPasswords              no
apply ChallengeResponseAuthentication   no
apply PubkeyAuthentication              yes
apply AuthorizedKeysFile                ".ssh/authorized_keys"
apply MaxAuthTries                      3
apply LoginGraceTime                    30
apply ClientAliveInterval               300
apply ClientAliveCountMax               2
apply X11Forwarding                     no
apply AllowTcpForwarding                no
apply LogLevel                          VERBOSE

if sshd -t 2>/dev/null; then
  ok "Конфигурация проверена — ошибок нет"
else
  err "Ошибка в конфигурации sshd! Восстанавливаю резервную копию..."
  cp "$BACKUP" "$SSHD_CONFIG"
  exit 1
fi

# ─── Step 3: fail2ban ─────────────────────────────────────────────────────────
step "Шаг 3 из 4 — fail2ban"

info "Устанавливаю пакеты..."
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
ok "fail2ban запущен"
info "Правило: 5 попыток за 10 мин → бан на 1 час"

# ─── Step 4: UFW ──────────────────────────────────────────────────────────────
step "Шаг 4 из 4 — Firewall (UFW)"

command -v ufw &>/dev/null || apt-get install -y ufw > /dev/null
ufw allow "$SSH_PORT"/tcp comment "SSH" > /dev/null
ufw --force enable > /dev/null
ufw reload > /dev/null
ok "Порт ${SSH_PORT}/tcp открыт"
info "Все остальные входящие — закрыты"

# ─── Restart SSH ──────────────────────────────────────────────────────────────
systemctl restart sshd

# ─── Done ─────────────────────────────────────────────────────────────────────
SERVER_IP=$(hostname -I | awk '{print $1}')

echo ""
echo ""
line
echo ""
echo -e "  ${G}${W}  Готово! Сервер защищён.${NC}"
echo ""
echo -e "  ${D}Пользователь   ${NC}${W}${TARGET_USER}${NC}"
echo -e "  ${D}SSH-порт       ${NC}${W}${SSH_PORT}${NC}"
echo -e "  ${D}Пароль         ${NC}${R}отключён${NC}${D} — только ключ${NC}"
echo -e "  ${D}IP-адрес       ${NC}${W}${SERVER_IP}${NC}"
echo ""
line
echo ""
echo -e "  ${W}Команда для подключения (Windows):${NC}"
echo ""
echo -e "  ${C}  ssh -p ${SSH_PORT} -i ~\\.ssh\\id_ed25519 ${TARGET_USER}@${SERVER_IP}${NC}"
echo ""
echo -e "  ${Y}  ⚠  Проверь вход в новой вкладке, не закрывая текущий сеанс!${NC}"
echo ""
line
echo ""
