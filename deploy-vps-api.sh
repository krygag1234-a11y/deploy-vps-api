#!/bin/bash
# deploy-vps-api.sh — автоматическое разворачивание FastAPI REST API на VPS
# Работает на чистом Ubuntu/Debian VPS
# Usage: ./deploy-vps-api.sh

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Проверка root
if [[ $EUID -ne 0 ]]; then
   log_error "Запустите скрипт от root (sudo ./deploy-vps-api.sh)"
   exit 1
fi

echo "=== VPS API Deployment Script ==="
echo "Этот скрипт разворачивает FastAPI REST API на порту 443"
echo ""

# Запрос данных
read -p "Введите IP адрес VPS [127.0.0.1]: " VPS_IP
VPS_IP="${VPS_IP:-127.0.0.1}"

read -p "Введите SSH пользователя [root]: " SSH_USER
SSH_USER="${SSH_USER:-root}"

read -p "Введите путь к SSH ключу: " SSH_KEY
if [[ -z "$SSH_KEY" ]]; then
    log_error "SSH ключ обязателен"
    exit 1
fi

if [[ ! -f "$SSH_KEY" ]]; then
    log_error "SSH ключ не найден: $SSH_KEY"
    exit 1
fi

log_info "VPS: $SSH_USER@$VPS_IP"
log_info "SSH Key: $SSH_KEY"
echo ""

# Генерация API токена
API_TOKEN="$(openssl rand -base64 32 | tr -d '\n')"
log_info "Сгенерирован API токен"

# Создание vps-api.py с токеном
cat > /tmp/vps-api.py << EOF
from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel
import subprocess

app = FastAPI()

API_TOKEN = "$API_TOKEN"

class CommandRequest(BaseModel):
    command: str

class CommandResponse(BaseModel):
    stdout: str
    stderr: str
    exit_code: int

@app.post("/api/exec")
async def execute_command(
    request: CommandRequest,
    authorization: str = Header(None)
):
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing authorization header")

    token = authorization.replace("Bearer ", "")
    if token != API_TOKEN:
        raise HTTPException(status_code=403, detail="Invalid token")

    try:
        result = subprocess.run(
            request.command,
            shell=True,
            capture_output=True,
            text=True,
            timeout=30
        )
        return CommandResponse(
            stdout=result.stdout,
            stderr=result.stderr,
            exit_code=result.returncode
        )
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=408, detail="Command timeout")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/health")
async def health():
    return {"status": "ok"}
EOF

# Создание systemd service
cat > /tmp/vps-api.service << EOF
[Unit]
Description=VPS REST API
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
ExecStart=/root/venv/bin/uvicorn vps-api:app --host 0.0.0.0 --port 443 --ssl-keyfile /root/key.pem --ssl-certfile /root/cert.pem
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

log_info "[1/7] Обновление системы и установка зависимостей..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=30 "$SSH_USER@$VPS_IP" \
  "apt update && apt install -y python3.12-venv openssl curl 2>&1 | tail -5"

log_info "[2/7] Создание виртуального окружения..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$VPS_IP" \
  "python3 -m venv /root/venv"

log_info "[3/7] Установка FastAPI и Uvicorn..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$VPS_IP" \
  "/root/venv/bin/pip install --quiet fastapi 'uvicorn[standard]'"

log_info "[4/7] Генерация SSL сертификата..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$VPS_IP" \
  "openssl req -x509 -newkey rsa:2048 -keyout /root/key.pem -out /root/cert.pem -days 365 -nodes -subj '/CN=$VPS_IP' 2>/dev/null"

log_info "[5/7] Загрузка файлов на VPS..."
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no /tmp/vps-api.py "$SSH_USER@$VPS_IP:/root/vps-api.py"
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no /tmp/vps-api.service "$SSH_USER@$VPS_IP:/etc/systemd/system/vps-api.service"

log_info "[6/7] Настройка systemd сервиса..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$VPS_IP" \
  "systemctl daemon-reload && systemctl enable vps-api.service"

log_info "[7/7] Запуск сервиса..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$VPS_IP" \
  "systemctl stop vps-api.service 2>/dev/null; pkill -9 uvicorn 2>/dev/null; sleep 1; systemctl start vps-api.service"

log_info "Проверка..."
sleep 3
RESULT=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$VPS_IP" "curl -sk https://localhost/health" 2>/dev/null)

if [[ "$RESULT" == *"ok"* ]]; then
  echo ""
  echo -e "${GREEN}=== УСПЕХ! API развернут ===${NC}"
  echo ""
  echo "URL: https://$VPS_IP/api/exec"
  echo "URL health: https://$VPS_IP/health"
  echo ""
  echo "API Token:"
  echo "$API_TOKEN"
  echo ""
  echo "Пример использования:"
  echo "curl -k -X POST https://$VPS_IP/api/exec \\"
  echo "  -H 'Authorization: Bearer $API_TOKEN' \\"
  echo "  -H 'Content-Type: application/json' \\"
  echo "  -d '{\"command\": \"uptime\"}'"
  echo ""
  echo "Ответ: {\"stdout\": \"...\", \"stderr\": \"...\", \"exit_code\": 0}"

  # Сохранение токена в файл
  echo "$API_TOKEN" > /tmp/vps-api-token.txt
  log_info "Токен сохранён в /tmp/vps-api-token.txt"
else
  log_error "Ошибка: API не отвечает"
  log_info "Логи: journalctl -u vps-api.service -n 20"
  exit 1
fi

# Очистка
rm -f /tmp/vps-api.py /tmp/vps-api.service