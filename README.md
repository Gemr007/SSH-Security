# 🔐 SSH Hardening Script

Интерактивный bash-скрипт для быстрой защиты SSH на Linux-серверах (Ubuntu/Debian).  
Настраивает ключевую аутентификацию, ужесточает конфиг sshd, устанавливает fail2ban и UFW.

---

## ⚡ Быстрый старт

```bash
curl -fsSL https://raw.githubusercontent.com/Gemr007/SSH-Security/main/ssh_security.sh \
  | sed 's/\r//' | sudo bash
```

Или скачать и запустить вручную:

```bash
curl -fsSL https://raw.githubusercontent.com/Gemr007/SSH-Security/main/ssh_security.sh -o ssh-hardening.sh
sudo bash ssh-hardening.sh
```

### Параметры запуска

| Флаг | Описание | По умолчанию |
|------|----------|--------------|
| `--port PORT` | SSH-порт | `22` |
| `--user USER` | Пользователь для ключа | текущий |

```bash
sudo bash ssh-hardening.sh --port 2222 --user vpn
```

---

## 🔧 Что делает скрипт

**Шаг 1 — SSH-ключ**
- Создаёт пользователя, если он не существует
- Принимает публичный ключ и записывает в `~/.ssh/authorized_keys`
- Выставляет правильные права на `.ssh/`

**Шаг 2 — sshd_config**
- Отключает вход по паролю и вход под root
- Включает только pubkey-аутентификацию
- Делает резервную копию конфига перед изменениями
- Проверяет конфиг через `sshd -t` перед перезапуском

**Шаг 3 — fail2ban**
- Устанавливает и настраивает fail2ban
- Правило: **5 попыток за 10 мин → бан на 1 час**

**Шаг 4 — UFW**
- Открывает только нужный SSH-порт
- Включает фаервол

---

## 📋 Требования

- Ubuntu / Debian
- Права root (`sudo`)
- SSH-ключ ed25519 (скрипт подскажет, как создать)

---

## 📁 Структура

```
ssh-hardening.sh   — основной скрипт
README.md          — документация
```

Лог выполнения сохраняется в `/var/log/ssh-hardening.log`.

---

## ⚠️ Важно

После запуска **не закрывай текущий сеанс** — сначала убедись, что можешь подключиться в новой вкладке:

```bash
ssh -p 22 -i ~/.ssh/id_ed25519 user@your-server-ip
```

Если что-то пошло не так, резервная копия конфига лежит здесь:

```bash
/etc/ssh/sshd_config.backup.YYYYMMDD_HHMMSS
```

---

## 📄 Лицензия

MIT
