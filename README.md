# deploy-vps-api

Автоматическое разворачивание FastAPI REST API на чистом VPS для удалённого управления через HTTPS.

## Возможности

- Запускается прямо на VPS без внешнего SSH
- Автоматическая установка Python 3.12, venv, FastAPI, Uvicorn
- Генерация самоподписанного SSL сертификата
- Systemd сервис с автозапуском
- Bearer token авторизация
- Выполнение команд через REST API

## Требования

- Чистый VPS на Ubuntu 22.04+ / Debian 12+
- Root доступ
- Открытый порт 443

## Установка

```bash
wget -O deploy-vps-api.sh https://raw.githubusercontent.com/krygag1234-a11y/deploy-vps-api/main/deploy-vps-api.sh
chmod +x deploy-vps-api.sh
sudo ./deploy-vps-api.sh
```

Скрипт автоматически:
1. Установит зависимости
2. Создаст виртуальное окружение
3. Настроит FastAPI + Uvicorn
4. Сгенерирует SSL сертификат
5. Запустит API на порту 443

После установки вы получите URL и Bearer токен.

## Использование API

### Health check

```bash
curl -k https://<VPS_IP>/health
```

### Выполнение команды

```bash
curl -k -X POST https://<VPS_IP>/api/exec \
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

## Endpoints

| Method | Path | Описание |
|--------|------|----------|
| GET | `/` | Информация об API |
| GET | `/health` | Проверка работоспособности |
| POST | `/api/exec` | Выполнение команды |

## Удаление

```bash
systemctl stop vps-api.service
systemctl disable vps-api.service
rm /root/vps-api.py /root/key.pem /root/cert.pem /root/api-token.txt
rm /etc/systemd/system/vps-api.service
systemctl daemon-reload
rm -rf /root/venv
```

## Лицензия

MIT