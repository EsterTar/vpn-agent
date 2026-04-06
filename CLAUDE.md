# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Обзор

Server-agent — тонкий FastAPI-агент, который ставится на каждый VPS. Принимает готовый sing-box конфиг по API, валидирует, записывает на диск, перезапускает сервис. Агент ничего не знает о протоколах — вся логика в вызывающем бэкенде.

## Запуск

```bash
python3 -m venv venv && source venv/bin/activate
pip install -r requirements.txt
# Скопировать .env.example → server-agent.env, заполнить AGENT_TOKEN
uvicorn main:app --host 0.0.0.0 --port 8080
```

Конфиг читается из `server-agent.env` (не `.env`). Обязательная переменная: `AGENT_TOKEN`.

## Деплой на сервере

Из корня репо, от root:

```bash
sudo bash deploy/install-singbox.sh <port> [port...]   # sing-box + firewall
sudo bash deploy/install-agent.sh [port] [host]         # агент как systemd-сервис → /opt/vpn-agent
```

Оба скрипта идемпотентны. Токен генерируется автоматически при первой установке.

## API

| Метод | Путь | Auth | Описание |
|-------|------|------|----------|
| `PUT` | `/config` | Bearer | Пуш sing-box конфига (валидация `sing-box check`, откат при ошибке) |
| `GET` | `/config` | Bearer | Текущий конфиг |
| `POST` | `/restart` | Bearer | Рестарт sing-box |
| `GET` | `/health` | — | Статус sing-box через systemd |

Запись конфига создаёт `.bak` бэкап. Ошибка валидации → автоматический откат.

## Deploy helpers

`deploy/helpers/` — скрипты для запуска на VPS:
- `scan-sni.sh` — сканирует подсеть VPS на домены с TLS 1.3 (RealiTLScanner)
- `find-sni.sh` — проверяет домен-кандидат на совместимость с Reality (ASN, TLS 1.3, H2)

## Git

Главная ветка — `dev`.

## Язык

Пользователь общается на русском. Документация на русском.
