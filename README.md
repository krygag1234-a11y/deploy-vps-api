# deploy-vps-api

Автоматический скрипт разворачивания FastAPI REST API на чистом VPS для удалённого управления через HTTPS.

## Возможности

- Автоматическая установка Python 3.12, venv, FastAPI, Uvicorn
- Генерация самоподписанного SSL сертификата
- Systemd сервис с автозапуском
- Bearer token авторизация
- Выполнение команд через REST API

## Требования

- Чистый VPS на Ubuntu 22.04+ / Debian 12+
- SSH доступ с ключом
- Открытый порт 443 в firewall

## Быстрый старт

1. Скачайте скрипт на локальную машину:
```bash
curl -O https://raw.githubusercontent.com/krygag1234-a11y/deploy-vps-api/main/deploy-vps-api.sh
chmod +x deploy-vps-api.sh
```

2. Запустите:
```bash
./deploy-vps-api.sh
```

3. Введите:
   - IP адрес VPS
   - SSH пользователь (обычно root)
   - Путь к SSH ключу

## Использование API

После установки получите:
- URL: `https://<VPS_IP>/api/exec`
- Bearer Token: выводится после установки

### Пример запроса

```bash
curl -k -X POST https://84.201.152.242/api/exec \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"command": "uptime"}'
```

### Ответ

```json
{
  "stdout": " 23:44:31 up 1 day,  2 users,  load average: 0.12, 0.08, 0.07\n",
  "stderr": "",
  "exit_code": 0
}
```

### Доступные endpoints

- `GET /health` — проверка работоспособности
- `POST /api/exec` — выполнение команды

## Безопасность

- API токен генерируется случайный при каждой установке
- Рекомендуется сменить токен после установки
- Используйте firewall для ограничения доступа к порту 443

## Удаление

На VPS:
```bash
systemctl stop vps-api.service
systemctl disable vps-api.service
rm /root/vps-api.py /root/key.pem /root/cert.pem
rm /etc/systemd/system/vps-api.service
systemctl daemon-reload
rm -rf /root/venv
```

## Лицензия

MIT