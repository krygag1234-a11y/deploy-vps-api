#!/bin/bash
# deploy-vps-api.sh — разворачивание FastAPI REST exec-API на чистом VPS.
# Улучшено: реальный публичный IP (не внутренний), домен + Let's Encrypt cert,
# ДВА инстанса (основной :443 + запасной :80, оба HTTPS с тем же cert),
# авто-продление cert с хуками, детальная настройка через флаги/env/интерактив.
#
# Ubuntu 22.04+/24.04, Debian 12+. Запуск от root.
#
# Примеры:
#   sudo ./deploy-vps-api.sh --domain api.example.com
#   sudo ./deploy-vps-api.sh --domain api.example.com --primary-port 443 --fallback-port 80 --email you@example.com
#   sudo DOMAIN=api.example.com ./deploy-vps-api.sh --self-signed   # без LE (cert самоподписанный; НЕ пройдёт проверяющие CA прокси)
#   sudo ./deploy-vps-api.sh --domain api.example.com --token "$(cat /root/api-token.txt)"  # переустановка с тем же токеном
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error(){ echo -e "${RED}[ERROR]${NC} $1"; }

[[ $EUID -eq 0 ]] || { log_error "Запустите от root: sudo ./deploy-vps-api.sh --domain <fqdn>"; exit 1; }

# ── Параметры ────────────────────────────────────────────────────────────────
DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-}"
PRIMARY_PORT="${PRIMARY_PORT:-443}"
FALLBACK_PORT="${FALLBACK_PORT:-80}"      # пустая строка/0 = не ставить запасной
API_TOKEN="${API_TOKEN:-}"
SELF_SIGNED=0
EXEC_TIMEOUT="${API_EXEC_TIMEOUT:-90}"
EXEC_CONCURRENCY="${API_EXEC_CONCURRENCY:-4}"
EXEC_MAX_OUTPUT_BYTES="${API_EXEC_MAX_OUTPUT_BYTES:-1048576}"
EXEC_KILL_GRACE="${API_EXEC_KILL_GRACE:-3}"
ASSUME_YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2;;
    --email) EMAIL="$2"; shift 2;;
    --primary-port) PRIMARY_PORT="$2"; shift 2;;
    --fallback-port) FALLBACK_PORT="$2"; shift 2;;
    --token) API_TOKEN="$2"; shift 2;;
    --exec-timeout) EXEC_TIMEOUT="$2"; shift 2;;
    --exec-concurrency) EXEC_CONCURRENCY="$2"; shift 2;;
    --max-output-bytes) EXEC_MAX_OUTPUT_BYTES="$2"; shift 2;;
    --kill-grace) EXEC_KILL_GRACE="$2"; shift 2;;
    --self-signed) SELF_SIGNED=1; shift;;
    -y|--yes) ASSUME_YES=1; shift;;
    -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) log_error "Неизвестный аргумент: $1"; exit 1;;
  esac
done

[[ "$EXEC_TIMEOUT" =~ ^[0-9]+([.][0-9]+)?$ ]] || { log_error "--exec-timeout должен быть положительным числом"; exit 1; }
[[ "$EXEC_CONCURRENCY" =~ ^[1-9][0-9]*$ ]] || { log_error "--exec-concurrency должен быть целым числом > 0"; exit 1; }
[[ "$EXEC_MAX_OUTPUT_BYTES" =~ ^[1-9][0-9]*$ ]] || { log_error "--max-output-bytes должен быть целым числом > 0"; exit 1; }
[[ "$EXEC_KILL_GRACE" =~ ^[0-9]+([.][0-9]+)?$ ]] || { log_error "--kill-grace должен быть положительным числом"; exit 1; }

# ── Публичный IP (НЕ внутренний hostname -I) ─────────────────────────────────
detect_public_ip(){
  local ip=""
  for u in "https://api.ipify.org" "https://ifconfig.me" "https://ipinfo.io/ip"; do
    ip=$(curl -fsS -m 8 "$u" 2>/dev/null | tr -dc '0-9.') || true
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return; }
  done
  # metadata (Yandex/GCP-подобные) как запас
  ip=$(curl -fsS -m 4 -H 'Metadata-Flavor: Google' \
        "http://169.254.169.254/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip" 2>/dev/null | tr -dc '0-9.') || true
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return; }
  echo ""
}
PUBLIC_IP="$(detect_public_ip)"
INTERNAL_IP="$(hostname -I | awk '{print $1}')"
log_info "Публичный IP: ${PUBLIC_IP:-<не определён>} (внутренний: ${INTERNAL_IP:-?})"

# ── Домен (интерактив, если не задан и не self-signed) ───────────────────────
if [[ -z "$DOMAIN" && $SELF_SIGNED -eq 0 ]]; then
  if [[ $ASSUME_YES -eq 1 ]]; then
    log_error "Не задан --domain. Укажите домен или --self-signed."; exit 1
  fi
  read -rp "Домен для API (A-запись должна указывать на $PUBLIC_IP), напр. api.example.com: " DOMAIN
fi
[[ -z "$DOMAIN" && $SELF_SIGNED -eq 0 ]] && { log_error "Домен обязателен (или --self-signed)."; exit 1; }

# ── Проверка DNS: домен → наш публичный IP ───────────────────────────────────
if [[ -n "$DOMAIN" ]]; then
  RESOLVED="$(getent hosts "$DOMAIN" | awk '{print $1}' | head -1 || true)"
  if [[ -n "$PUBLIC_IP" && "$RESOLVED" != "$PUBLIC_IP" ]]; then
    log_warn "DNS: $DOMAIN → '${RESOLVED:-нет записи}', а публичный IP = $PUBLIC_IP."
    log_warn "Для Let's Encrypt A-запись $DOMAIN должна указывать на $PUBLIC_IP."
    if [[ $SELF_SIGNED -eq 0 && $ASSUME_YES -eq 0 ]]; then
      read -rp "Продолжить попытку LE всё равно? [y/N]: " a; [[ "$a" =~ ^[yY]$ ]] || { log_error "Прервано. Поправьте DNS и повторите."; exit 1; }
    fi
  else
    log_info "DNS OK: $DOMAIN → ${RESOLVED:-?}"
  fi
fi

# ── Токен ────────────────────────────────────────────────────────────────────
if [[ -z "$API_TOKEN" ]]; then
  if [[ -f /root/api-token.txt ]]; then API_TOKEN="$(tr -d '\n' < /root/api-token.txt)"; log_info "Использую существующий токен из /root/api-token.txt";
  else API_TOKEN="$(openssl rand -base64 32 | tr -d '\n=+/' | cut -c1-40)"; log_info "Сгенерирован новый токен"; fi
fi

# Резервная копия текущей установки перед любыми перезаписями.
BACKUP_DIR="/root/deploy-vps-api-backups/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BACKUP_DIR"
for old_path in /root/vps-api.py /root/api-token.txt /etc/systemd/system/vps-api.service /etc/systemd/system/vps-api-fb.service; do
  [[ -e "$old_path" ]] && cp -a "$old_path" "$BACKUP_DIR/"
done
printf '%s\n' "$API_TOKEN" > /root/api-token.txt
chmod 600 /root/api-token.txt
log_info "Резервная копия предыдущей установки: $BACKUP_DIR"

# ── Зависимости ──────────────────────────────────────────────────────────────
log_info "[1/6] Зависимости…"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-venv openssl curl ca-certificates >/dev/null 2>&1 || true
if [[ $SELF_SIGNED -eq 0 ]]; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq certbot >/dev/null 2>&1 || true
fi

# ── venv + FastAPI ───────────────────────────────────────────────────────────
log_info "[2/6] venv + FastAPI/Uvicorn…"
[[ -d /root/venv ]] || python3 -m venv /root/venv
/root/venv/bin/pip install --quiet --upgrade pip >/dev/null 2>&1 || true
/root/venv/bin/pip install --quiet fastapi 'uvicorn[standard]'

# ── Сертификат ───────────────────────────────────────────────────────────────
log_info "[3/6] Сертификат…"
CERT=""; KEY=""
if [[ $SELF_SIGNED -eq 1 || -z "$DOMAIN" ]]; then
  log_warn "Самоподписанный cert (CN=${DOMAIN:-$PUBLIC_IP}). НЕ пройдёт клиентов/прокси с проверкой публичного CA."
  openssl req -x509 -newkey rsa:2048 -keyout /root/key.pem -out /root/cert.pem \
    -days 365 -nodes -subj "/CN=${DOMAIN:-$PUBLIC_IP}" 2>/dev/null
  CERT=/root/cert.pem; KEY=/root/key.pem
else
  # LE через standalone :80 — временно освобождаем :80 (если занят нашим запасным)
  systemctl stop vps-api-fb 2>/dev/null || true
  if [[ ! -d "/etc/letsencrypt/live/$DOMAIN" ]]; then
    EMAIL_ARG=(--register-unsafely-without-email); [[ -n "$EMAIL" ]] && EMAIL_ARG=(-m "$EMAIL")
    certbot certonly --standalone --non-interactive --agree-tos "${EMAIL_ARG[@]}" -d "$DOMAIN" \
      --http-01-port 80 || { log_error "certbot не смог выпустить cert для $DOMAIN. Проверьте DNS/доступ :80 снаружи."; exit 1; }
  else
    log_info "LE cert для $DOMAIN уже есть — переиспользую."
  fi
  CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"; KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
fi

# ── Приложение ───────────────────────────────────────────────────────────────
log_info "[4/6] Приложение /root/vps-api.py…"
cat > /root/vps-api.py << 'PYEOF'
from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel
import asyncio
import contextlib
import hmac
import os
from pathlib import Path
import signal
import socket

app = FastAPI()
API_TOKEN = Path(os.environ.get("API_TOKEN_FILE", "/root/api-token.txt")).read_text().strip()
EXEC_TIMEOUT = float(os.environ.get("API_EXEC_TIMEOUT", "90"))
EXEC_CONCURRENCY = max(1, int(os.environ.get("API_EXEC_CONCURRENCY", "4")))
EXEC_MAX_OUTPUT_BYTES = max(4096, int(os.environ.get("API_EXEC_MAX_OUTPUT_BYTES", "1048576")))
EXEC_KILL_GRACE = max(0.1, float(os.environ.get("API_EXEC_KILL_GRACE", "3")))
EXEC_SLOTS = asyncio.Semaphore(EXEC_CONCURRENCY)


class CommandRequest(BaseModel):
    command: str


class CommandResponse(BaseModel):
    stdout: str
    stderr: str
    exit_code: int


def _auth(authorization):
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing authorization header")
    if not hmac.compare_digest(authorization.split(" ", 1)[1], API_TOKEN):
        raise HTTPException(status_code=403, detail="Invalid token")


async def _read_limited(stream):
    kept = bytearray()
    dropped = 0
    while True:
        chunk = await stream.read(65536)
        if not chunk:
            break
        available = max(0, EXEC_MAX_OUTPUT_BYTES - len(kept))
        kept.extend(chunk[:available])
        dropped += max(0, len(chunk) - available)
    return bytes(kept), dropped


def _decode_output(data, dropped):
    text = data.decode("utf-8", errors="replace")
    if dropped:
        text += f"\n[output truncated: {dropped} bytes omitted]\n"
    return text


async def _stop_process_group(proc):
    with contextlib.suppress(ProcessLookupError):
        os.killpg(proc.pid, signal.SIGTERM)
    if proc.returncode is None:
        try:
            await asyncio.wait_for(proc.wait(), timeout=EXEC_KILL_GRACE)
        except asyncio.TimeoutError:
            pass
    with contextlib.suppress(ProcessLookupError):
        os.killpg(proc.pid, signal.SIGKILL)
    if proc.returncode is None:
        with contextlib.suppress(Exception):
            await proc.wait()


async def _collect(proc, stdout_task, stderr_task):
    await proc.wait()
    return await asyncio.gather(stdout_task, stderr_task)


@app.post("/api/exec")
async def execute_command(request: CommandRequest, authorization: str = Header(None)):
    _auth(authorization)
    async with EXEC_SLOTS:
        proc = None
        stdout_task = None
        stderr_task = None
        try:
            proc = await asyncio.create_subprocess_shell(
                request.command,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                start_new_session=True,
            )
            stdout_task = asyncio.create_task(_read_limited(proc.stdout))
            stderr_task = asyncio.create_task(_read_limited(proc.stderr))
            (stdout_data, stdout_dropped), (stderr_data, stderr_dropped) = await asyncio.wait_for(
                _collect(proc, stdout_task, stderr_task), timeout=EXEC_TIMEOUT
            )
            return CommandResponse(
                stdout=_decode_output(stdout_data, stdout_dropped),
                stderr=_decode_output(stderr_data, stderr_dropped),
                exit_code=proc.returncode,
            )
        except asyncio.TimeoutError:
            if proc is not None:
                await _stop_process_group(proc)
            for task in (stdout_task, stderr_task):
                if task is not None and not task.done():
                    task.cancel()
            raise HTTPException(status_code=408, detail=f"Command timeout after {EXEC_TIMEOUT:g}s")
        except asyncio.CancelledError:
            if proc is not None:
                await _stop_process_group(proc)
            for task in (stdout_task, stderr_task):
                if task is not None and not task.done():
                    task.cancel()
            raise
        except HTTPException:
            raise
        except Exception as exc:
            if proc is not None:
                await _stop_process_group(proc)
            raise HTTPException(status_code=500, detail=str(exc))


@app.get("/health")
async def health():
    return {
        "status": "ok",
        "host": socket.gethostname(),
        "exec_timeout": EXEC_TIMEOUT,
        "exec_concurrency": EXEC_CONCURRENCY,
        "max_output_bytes": EXEC_MAX_OUTPUT_BYTES,
    }


@app.get("/")
async def root():
    return {"message": "VPS API", "endpoints": ["/health", "/api/exec"]}
PYEOF
/root/venv/bin/python3 -m py_compile /root/vps-api.py

# ── systemd units: основной + запасной ───────────────────────────────────────
log_info "[5/6] systemd (основной :$PRIMARY_PORT + запасной :$FALLBACK_PORT)…"
make_unit(){ # $1=unit name  $2=port
  cat > "/etc/systemd/system/$1.service" << SVCEOF
[Unit]
Description=VPS REST API ($1, port $2)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
Environment=API_EXEC_TIMEOUT=$EXEC_TIMEOUT
Environment=API_EXEC_CONCURRENCY=$EXEC_CONCURRENCY
Environment=API_EXEC_MAX_OUTPUT_BYTES=$EXEC_MAX_OUTPUT_BYTES
Environment=API_EXEC_KILL_GRACE=$EXEC_KILL_GRACE
ExecStart=/root/venv/bin/uvicorn vps-api:app --host 0.0.0.0 --port $2 --ssl-keyfile $KEY --ssl-certfile $CERT
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF
}
make_unit vps-api "$PRIMARY_PORT"
systemctl daemon-reload
systemctl enable vps-api >/dev/null 2>&1 || true
systemctl restart vps-api

if [[ -n "$FALLBACK_PORT" && "$FALLBACK_PORT" != "0" && "$FALLBACK_PORT" != "$PRIMARY_PORT" ]]; then
  make_unit vps-api-fb "$FALLBACK_PORT"
  systemctl enable vps-api-fb >/dev/null 2>&1 || true
  systemctl restart vps-api-fb
fi

# ── Авто-продление cert (LE): хуки освобождают :80 и рестартят инстансы ───────
if [[ $SELF_SIGNED -eq 0 && -n "$DOMAIN" ]]; then
  mkdir -p /etc/letsencrypt/renewal-hooks/pre /etc/letsencrypt/renewal-hooks/deploy
  cat > /etc/letsencrypt/renewal-hooks/pre/stop-vps-api-fb.sh <<'H'
#!/bin/bash
systemctl stop vps-api-fb 2>/dev/null || true
H
  cat > /etc/letsencrypt/renewal-hooks/deploy/restart-vps-api.sh <<'H'
#!/bin/bash
systemctl restart vps-api 2>/dev/null || true
systemctl start vps-api-fb 2>/dev/null || true
H
  chmod +x /etc/letsencrypt/renewal-hooks/pre/stop-vps-api-fb.sh /etc/letsencrypt/renewal-hooks/deploy/restart-vps-api.sh
  systemctl enable certbot.timer >/dev/null 2>&1 || true
  systemctl start certbot.timer >/dev/null 2>&1 || true
fi

# ── Проверка ─────────────────────────────────────────────────────────────────
log_info "[6/6] Проверка…"
chmod 600 /root/api-token.txt
sleep 2
ok=1
curl -sk -m 8 "https://localhost:$PRIMARY_PORT/health" | grep -q '"ok"' || ok=0
if [[ -n "$FALLBACK_PORT" && "$FALLBACK_PORT" != "0" && "$FALLBACK_PORT" != "$PRIMARY_PORT" ]]; then
  curl -sk -m 8 "https://localhost:$FALLBACK_PORT/health" | grep -q '"ok"' || ok=0
fi
if [[ $ok -eq 1 ]]; then
  HOSTREF="${DOMAIN:-$PUBLIC_IP}"
  echo ""; echo -e "${GREEN}=== ГОТОВО ===${NC}"
  echo "Основной : https://$HOSTREF:$PRIMARY_PORT/api/exec"
  [[ -n "$FALLBACK_PORT" && "$FALLBACK_PORT" != "0" ]] && echo "Запасной : https://$HOSTREF:$FALLBACK_PORT/api/exec"
  echo "Токен    : $API_TOKEN   (сохранён в /root/api-token.txt)"
  echo ""
  echo "Пример:"
  echo "  curl -s -X POST https://$HOSTREF:$PRIMARY_PORT/api/exec \\"
  echo "    -H 'Authorization: Bearer $API_TOKEN' -H 'Content-Type: application/json' \\"
  echo "    -d '{\"command\": \"uptime\"}'"
else
  log_error "Проверка не прошла. Логи:"; journalctl -u vps-api -n 15 --no-pager || true; exit 1
fi
