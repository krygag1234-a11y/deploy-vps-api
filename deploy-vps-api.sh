#!/bin/bash
# deploy-vps-api.sh — автоматическое разворачивание FastAPI REST API на чистом VPS
# Работает на чистом Ubuntu 22.04+ / Debian 12+
# Запустить: wget -O deploy-vps-api.sh https://raw.githubusercontent.com/krygag1234-a11y/deploy-vps-api/main/deploy-vps-api.sh && chmod +x deploy-vps-api.sh && sudo ./deploy-vps-api.sh

set -e

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Проверка root
if [[ $EUID -ne 0 ]]; then
   log_error "Запустите от root: sudo ./deploy-vps-api.sh"
   exit 1
fi

echo "=== VPS API Deployment ==="
echo "Разворачивание FastAPI REST API на порту 443"
echo ""

# Определение IP
VPS_IP=$(hostname -I | awk '{print $1}')
log_info "IP адрес: $VPS_IP"

# Генерация токена
API_TOKEN=$(openssl rand -base64 32 | tr -d '\n')
log_info "API токен сгенерирован"

log_info "[1/6] Установка зависимостей..."
apt update -qq
apt install -y -qq python3.12-venv openssl curl >/dev/null 2>&1 || true

log_info "[2/6] Создание виртуального окружения..."
python3 -m venv /root/venv

log_info "[3/6] Установка FastAPI и Uvicorn..."
/root/venv/bin/pip install --quiet fastapi 'uvicorn[standard]'

log_info "[4/6] Генерация SSL сертификата..."
openssl req -x509 -newkey rsa:2048 \
  -keyout /root/key.pem -out /root/cert.pem \
  -days 365 -nodes -subj "/CN=$VPS_IP" 2>/dev/null

log_info "[5/6] Создание API приложения..."
cat > /root/vps-api.py << 'PYEOF'
from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel
import subprocess
import socket

app = FastAPI()

API_TOKEN = "__TOKEN_PLACEHOLDER__"

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
    return {"status": "ok", "ip": socket.gethostbyname(socket.gethostname())}

@app.get("/")
async def root():
    return {"message": "VPS API", "endpoints": ["/health", "/api/exec"]}
PYEOF

sed -i "s/__TOKEN_PLACEHOLDER__/$API_TOKEN/" /root/vps-api.py

log_info "[6/6] Настройка systemd сервиса..."
cat > /etc/systemd/system/vps-api.service << 'SVCEOF'
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
SVCEOF

systemctl daemon-reload
systemctl enable vps-api.service
systemctl restart vps-api.service

sleep 2

log_info "Проверка..."
if curl -sk https://localhost/health | grep -q "ok"; then
  echo ""
  echo -e "${GREEN}=== ГОТОВО! ===${NC}"
  echo ""
  echo "Health: https://$VPS_IP/health"
  echo "API:    https://$VPS_IP/api/exec"
  echo ""
  echo "Токен:"
  echo "$API_TOKEN"
  echo ""
  echo "Пример:"
  echo "curl -k -X POST https://$VPS_IP/api/exec \\"
  echo "  -H 'Authorization: Bearer $API_TOKEN' \\"
  echo "  -H 'Content-Type: application/json' \\"
  echo "  -d '{\"command\": \"uptime\"}'"
  echo ""
  echo "Токен сохранён в: /root/api-token.txt"
  echo "$API_TOKEN" > /root/api-token.txt
else
  log_error "Ошибка запуска. Логи:"
  journalctl -u vps-api.service -n 10 --no-pager
  exit 1
fi