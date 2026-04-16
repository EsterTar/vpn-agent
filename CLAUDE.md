# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Обзор

Server-agent — тонкий FastAPI-агент, который ставится на каждый VPS. Принимает готовый xray конфиг по API, валидирует, записывает на диск, перезапускает/релоудит сервис. Агент ничего не знает о протоколах — вся логика в вызывающем бэкенде.

## Структура

```
main.py          — FastAPI app + все роуты
app/
  settings.py    — Settings (pydantic-settings, читает server-agent.env)
  xray.py        — контроль xray: validate / reload / restart / stats
deploy/
  install-xray.sh   — установка xray + firewall
  install-agent.sh  — агент как systemd-сервис → /data/docker/agent
  helpers/          — утилиты для VPS (scan-sni, find-sni)
```

## Запуск

```bash
python3 -m venv venv && source venv/bin/activate
pip install -r requirements.txt
# Скопировать .env.example → server-agent.env, заполнить AGENT_TOKEN
uvicorn main:app --host 0.0.0.0 --port 8080
```

Конфиг читается из `server-agent.env`. Обязательная переменная: `AGENT_TOKEN`.

## Деплой на сервере

Из корня репо, от root:

```bash
sudo bash deploy/install-xray.sh <port> [port...]   # xray + firewall
sudo bash deploy/install-agent.sh [port] [host]      # агент как systemd-сервис → /data/docker/agent
```

Оба скрипта идемпотентны. Токен генерируется автоматически при первой установке.

## API

| Метод | Путь | Auth | Описание |
|-------|------|------|----------|
| `PUT` | `/config` | Bearer | Полная замена xray конфига (валидация + SIGHUP reload, откат при ошибке) |
| `GET` | `/config` | Bearer | Текущий конфиг |
| `POST` | `/clients/{inbound_tag}` | Bearer | Добавить клиента в inbound (без рестарта) |
| `DELETE` | `/clients/{inbound_tag}/{email}` | Bearer | Удалить клиента (без рестарта) |
| `GET` | `/stats?pattern=` | Bearer | Трафик по пользователям через xray Stats API |
| `GET` | `/health` | — | Статус xray через systemd |
| `POST` | `/restart` | Bearer | Полный рестарт xray (аварийный) |

Запись конфига создаёт `.bak` бэкап. Ошибка валидации или reload → автоматический откат.

"Без рестарта" = `systemctl reload xray` (SIGHUP) — xray перечитывает конфиг, активные соединения не рвутся.

## Требуемые секции в xray конфиге

Для работы stats и логов xray конфиг должен содержать:
- `"stats": {}` + `"api"` с `StatsService` + API inbound на `127.0.0.1:10085`
- `"policy"` с `statsUserUplink/Downlink`
- `"log"` с `access: /var/log/xray/access.log` (для парсера устройств)

## Deploy helpers

`deploy/helpers/` — скрипты для запуска на VPS:
- `scan-sni.sh` — сканирует подсеть VPS на домены с TLS 1.3 (RealiTLScanner)
- `find-sni.sh` — проверяет домен-кандидат на совместимость с Reality (ASN, TLS 1.3, H2)

## Git

Главная ветка — `dev`.

## Язык

Пользователь общается на русском. Документация на русском.
