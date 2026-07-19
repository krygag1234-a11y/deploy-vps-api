# deploy-vps-api

Разворачивание FastAPI REST exec-API на чистом VPS для удалённого управления через HTTPS.

## Возможности

- Реальный **публичный** IP (через ipify/ifconfig/metadata), а не внутренний `hostname -I`
- **Домен + Let's Encrypt** сертификат (валиден для клиентов/прокси с проверкой публичного CA); опционально самоподписанный (`--self-signed`)
- **Два инстанса**: основной на `:443` + **запасной на `:80`** (оба HTTPS, тот же cert) — резервный канал, если основной порт «упал»
- Авто-продление cert с хуками (освобождает `:80` на время renew, рестартит инстансы)
- Проверка соответствия DNS ↔ публичный IP перед выпуском cert
- Настраиваемые порты, e-mail, токен (переустановка с тем же токеном), таймаут exec
- Bearer-token авторизация, systemd автозапуск

## Требования

- Чистый Ubuntu 22.04+/24.04 или Debian 12+, root
- Порты `:443` и `:80` свободны и доступны снаружи
- **A-запись домена указывает на публичный IP сервера** (для Let's Encrypt)

## Установка

```bash
wget -O deploy-vps-api.sh https://raw.githubusercontent.com/krygag1234-a11y/deploy-vps-api/main/deploy-vps-api.sh
chmod +x deploy-vps-api.sh
sudo ./deploy-vps-api.sh --domain api.example.com
```

Опции:

| Флаг | Назначение | По умолчанию |
|------|------------|--------------|
| `--domain <fqdn>` | Домен для LE-cert (A-запись → этот сервер) | — (спросит) |
| `--email <addr>` | E-mail для Let's Encrypt | без e-mail |
| `--primary-port <n>` | Основной порт | `443` |
| `--fallback-port <n>` | Запасной порт (`0`/пусто — не ставить) | `80` |
| `--token <str>` | Задать/переиспользовать токен | из `/root/api-token.txt` или новый |
| `--exec-timeout <sec>` | Таймаут команды на сервере | `90` |
| `--self-signed` | Самоподписанный cert (без LE) | выкл |
| `-y, --yes` | Не задавать вопросов | выкл |

После установки печатается URL основного/запасного канала и Bearer-токен (также в `/root/api-token.txt`).

## Использование

```bash
# health
curl -s https://api.example.com/health
# exec
curl -s -X POST https://api.example.com/api/exec \
  -H "Authorization: Bearer <TOKEN>" -H "Content-Type: application/json" \
  -d '{"command": "uptime"}'
# запасной канал (если основной порт недоступен)
curl -s -X POST https://api.example.com:80/api/exec -H "Authorization: Bearer <TOKEN>" \
  -H "Content-Type: application/json" -d '{"command": "uptime"}'
```

Ответ: `{"stdout": "...", "stderr": "...", "exit_code": 0}`

## Endpoints

| Method | Path | Описание |
|--------|------|----------|
| GET | `/` | Информация об API |
| GET | `/health` | Проверка работоспособности |
| POST | `/api/exec` | Выполнение команды (Bearer) |

## Безопасность

Exec-API даёт удалённое выполнение команд от root — держите токен в секрете, ограничьте доступ по firewall при возможности, ротируйте токен после работ.

## Удаление

```bash
systemctl disable --now vps-api vps-api-fb 2>/dev/null || true
rm -f /etc/systemd/system/vps-api.service /etc/systemd/system/vps-api-fb.service
systemctl daemon-reload
rm -f /root/vps-api.py /root/api-token.txt /root/key.pem /root/cert.pem
# LE cert (если был): certbot delete --cert-name api.example.com
```

## Лицензия

MIT
