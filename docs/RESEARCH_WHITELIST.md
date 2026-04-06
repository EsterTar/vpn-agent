# Исследование: белые списки и стабильность VPN (РФ, март 2026)

> Дата исследования: 22 марта 2026
> Статус: ситуация меняется еженедельно, требуется регулярная ревалидация

---

## TL;DR

- **Белые списки** — режим, при котором мобильный интернет работает только с одобренными доменами/IP (Яндекс, ВК, Госуслуги, Сбер и т.д.)
- **Текущая архитектура проекта** (прямой коннект на зарубежный VPS) **не работает при белых списках** — ни тюнинг протокола, ни смена транспорта не помогут
- **Отвалы VPN без белых списков** — вызваны заморозкой TCP-соединений после ~16-20 КБ данных на подозрительные IP + ASN хостера может быть в чёрном списке ТСПУ
- **Реверс-инжиниринг VPNUS** (март 2026) показал рабочий метод обхода белых списков: relay через Yandex Cloud / VK Cloud с SNI whitelisted российских сервисов

---

## 1. Проблема: отвалы VPN без белых списков

### Симптомы

- Speedtest обрывает соединение через ~10 секунд
- Периодические отвалы при загрузке сайтов
- Региональные различия: СПБ работает лучше, Краснодар хуже
- YouTube/Instagram работают, speedtest — нет

### Причина

ТСПУ "замораживает" TCP-соединение после **~16-20 КБ** переданных данных на подозрительные IP. Не RST, просто пакеты перестают доставляться. Speedtest моментально набирает этот порог. YouTube/Instagram используют свои CDN с другими паттернами трафика.

Дополнительный фактор: ASN хостера может быть в чёрном списке ТСПУ. Hetzner (AS24940), Vultr (AS20473), DigitalOcean (AS14061) — все в чёрном списке. Малоизвестные хостеры (например GHOSTnet, AS202147) пока нет.

**Источники:**
- [net4people/bbs#490](https://github.com/net4people/bbs/issues/490) — описание механизма заморозки
- [Habr: Белые списки добрались до Москвы — механика отсечки в 16 КБ](https://habr.com/ru/articles/1008164/)

### Возможные улучшения (не гарантированы)

Тюнинг `xhttpSettings` на основе документации Xray-core ([Discussion #4113](https://github.com/XTLS/Xray-core/discussions/4113), [#4118](https://github.com/XTLS/Xray-core/discussions/4118)):

**Серверная сторона:**
```json
"xhttpSettings": {
  "path": "/",
  "mode": "auto",
  "extra": {
    "scMaxEachPostBytes": 1000000,
    "scMaxBufferedPosts": 30,
    "xPaddingBytes": "100-1000"
  }
}
```

**Клиентская сторона:**
```json
"extra": {
  "xPaddingBytes": "100-1000",
  "scMaxEachPostBytes": "500000-1000000",
  "scMinPostsIntervalMs": "10-50",
  "xmux": {
    "maxConcurrency": "16-32",
    "maxConnections": 0,
    "cMaxReuseTimes": "64-128",
    "hMaxRequestTimes": "600-900",
    "hMaxReusableSecs": "1800-3000",
    "hKeepAlivePeriod": 0
  }
}
```

**Важно:** эти параметры делают трафик менее узнаваемым, но **не решают проблему**, если ТСПУ блокирует по IP/CIDR-подсети хостера. Fragment settings помогают против SNI-детекции, но не против порога в 16 КБ.

**Альтернатива:** сменить хостер на малоизвестный, чей ASN не в чёрном списке (см. раздел 3).

### Hysteria2 (UDP) — опасен

При попытке использовать UDP вызывает **полную блокировку доступа к серверу на ~10 минут**.

**Источник:** [net4people/bbs#490](https://github.com/net4people/bbs/issues/490)

---

## 2. Проблема: белые списки

### Как работают белые списки

Два уровня фильтрации одновременно:

1. **SNI-уровень (DPI)** — ТСПУ читает SNI из TLS ClientHello, сверяет со списком разрешённых доменов
2. **IP-уровень (CIDR)** — блокировка по IP-подсетям. Зарубежные ASN (Hetzner, Vultr, DO, OVH, Cloudflare) блокируются целиком

Оба условия должны совпасть: SNI из белого списка **И** IP из белого списка. Подмена только SNI не работает.

**Белый список содержит ~75 000 записей** (формат: конкретные IP с маской /32). Включает исключительно российские сервисы.

**Источники:**
- [Habr: РКН создали белый список для 72 AS, но пострадали 391 AS](https://habr.com/ru/articles/997088/)
- [Habr: Эпоха белых списков](https://habr.com/ru/articles/979128/)
- [GitHub: hxehex/russia-mobile-internet-whitelist](https://github.com/hxehex/russia-mobile-internet-whitelist) — краудсорс актуальных белых IP/CIDR/доменов
- [net4people/bbs#516](https://github.com/net4people/bbs/issues/516) — механика белых списков на мобильных сетях

### Проверенные НЕрабочие методы

| Метод | Почему не работает | Источник |
|-------|-------------------|----------|
| **VLESS+Reality напрямую на зарубежный VPS** | IP зарубежного хостера не в белом списке — блокировка по IP | bbs#490 |
| **Cloudflare CDN** | 1) CF активно блокирует VPN-трафик с ноября 2024; 2) IP Cloudflare НЕТ в белом списке (проверено по hxehex repo — ноль совпадений) | [bbs#429](https://github.com/net4people/bbs/issues/429), hxehex repo |
| **ECH (Encrypted Client Hello)** | ТСПУ блокирует соединения, где не может прочитать SNI — ECH становится маркером для блокировки | [Habr: 5 поколений протоколов](https://habr.com/ru/articles/1009542/) |
| **Domain fronting через Google/Amazon** | Отключено провайдерами ещё в 2018 | — |
| **Hysteria2 (UDP)** | UDP вызывает полную блокировку IP на ~10 минут | bbs#490 |

### Подтверждённый рабочий метод: relay через российские облака

**Подтверждено реверс-инжинирингом VPNUS (22 марта 2026).**

Схема:
```
Клиент → Российский cloud VPS (Yandex Cloud / VK Cloud)
  SNI: ads.x5.ru / io.ozone.ru / sun6-21.userapi.com
  Протокол: VLESS + TCP + Reality + Vision
  → [relay] → Зарубежный exit-сервер → Интернет
```

Российские relay-серверы VPNUS на март 2026:

| IP | Провайдер | ASN |
|----|----------|-----|
| 158.160.118.113 | **Yandex Cloud** | RIPE-allocated |
| 158.160.121.209 | **Yandex Cloud** | RIPE-allocated |
| 89.208.230.49 | **VK Cloud Solutions** | AS47764 |
| 212.233.91.114 | **VK Cloud Solutions** | AS47764 |
| 212.233.90.189 | **VK Cloud Solutions** | AS47764 |
| 66.90.90.106 | FDCservers.net (US) | — (запасной) |

SNI для LTE-серверов — **whitelisted российские домены**:
- **ads.x5.ru** — X5 Group (Пятёрочка, Перекрёсток)
- **io.ozone.ru** — Ozone (маркетплейс)
- **sun6-21.userapi.com** — CDN ВКонтакте

**Вывод:** несмотря на январское (2026) разделение IP-пулов, IP Yandex Cloud и VK Cloud **всё ещё работают** для relay при белых списках. Возможно, провайдеры не полностью разделили пулы, или ТСПУ не блокирует весь трафик к российским облачным IP.

---

## 3. Реверс-инжиниринг VPNUS: полная архитектура

### Обычный режим (серверы 🇩🇪 Германия)

```
Клиент → GHOSTnet GmbH (85.118.165.x, AS202147, Германия)
  Протокол: VLESS
  3 транспорта с автопереключением (observatory):
    1. TCP + Reality + Vision, порт 443, SNI: tradingview.com, fp: qq  (приоритет)
    2. gRPC + Reality, порт 1443, SNI: de.eu-ffast.com                (fallback)
    3. WebSocket, порт 448, постквантовое шифрование mlkem768x25519plus (fallback)
```

Ключевые решения:
- **GHOSTnet (AS202147)** — малоизвестный немецкий хостер, **не в чёрном списке ТСПУ** (в отличие от Hetzner, Vultr, DO)
- **Fingerprint: qq** — не chrome; возможно менее изученный ТСПУ
- **SNI: tradingview.com** — популярный сервис, блокировка вызовет коллатеральный ущерб
- **4 IP на один домен** (DNS round-robin) — устойчивость к блокировке отдельных IP
- **Observatory** — health-check каждую минуту, автоматическое отключение мёртвых outbound'ов

### LTE режим (серверы 🇫🇮 — relay через Россию)

```
Клиент → Yandex Cloud / VK Cloud (российские IP)
  Протокол: VLESS + TCP + Reality + Vision
  SNI: ads.x5.ru / io.ozone.ru / sun6-21.userapi.com
  6 серверов с балансировкой (leastLoad, baseline 4s, maxRTT 6s)
  → [relay] → Зарубежный exit-сервер → Интернет
```

Ключевые решения:
- **Только TCP + Reality + Vision** — без gRPC/WS fallback (видимо, для LTE важнее стабильность одного транспорта)
- **SNI — whitelisted российские домены** (X5, Ozone, VK)
- **Более мягкие таймауты** — baseline 4s, maxRTT 6s (vs 2s у DE) — потому что relay добавляет задержку
- **6 серверов** с разными IP для ротации при блокировках

### Общие элементы

- Протокол: VLESS (не Shadowsocks, не Trojan)
- Транспорт: TCP + Reality + Vision (основной для обоих режимов — не XHTTP!)
- UUID одинаковый на всех серверах
- Apple Push и Google MTalk идут direct (не через VPN)
- BitTorrent заблокирован
- DNS: 8.8.4.4, 8.8.8.8

---

## 4. Открытые вопросы

- **Как VPNUS получает рабочие IP в Yandex Cloud / VK Cloud после разделения пулов?** Массовая аренда VPS? Связи с провайдерами? Ротация?
- **Как устроен relay?** Xray dokodemo-door → freedom? iptables DNAT? Отдельный Xray с chain?
- **Почему TCP+Vision, а не XHTTP?** XHTTP рекомендуют все форумы, но коммерческий сервис выбрал TCP. Возможно XHTTP менее стабилен или хуже работает с Reality.
- **Домен test-cdn-kkk.com** — чей, как управляется DNS? Разные поддомены резолвятся на разные пулы IP.

---

## 5. Практические выводы для проекта

### Для проблемы 1 (отвалы без белых списков)

1. **Проверить ASN текущего хостера** — если это Hetzner/Vultr/DO, переезд на малоизвестного провайдера (GHOSTnet, или аналог) может решить проблему
2. **Рассмотреть TCP + Reality + Vision** вместо XHTTP — VPNUS использует именно это
3. **Сменить fingerprint на qq** вместо chrome
4. **Выбрать SNI популярного сервиса** (tradingview.com или аналог) — коллатеральный ущерб от блокировки
5. **Добавить несколько IP** через DNS round-robin
6. **Добавить observatory** с несколькими outbound'ами и автопереключением

### Для проблемы 2 (белые списки)

1. **Арендовать VPS в Yandex Cloud / VK Cloud** (~200-500₽/мес)
2. **Настроить relay** на российском VPS (пробрасывает трафик на зарубежный exit-сервер)
3. **Использовать SNI whitelisted сервисов**: ads.x5.ru, io.ozone.ru, sun6-21.userapi.com
4. **VLESS + TCP + Reality + Vision** — тот же протокол что и без белых списков
5. **Несколько relay-серверов** для устойчивости к блокировкам отдельных IP

---

## 6. Ключевые источники

- [net4people/bbs#490: Russia new blocking method (16-20KB freeze)](https://github.com/net4people/bbs/issues/490)
- [net4people/bbs#429: Cloudflare blocking proxy traffic](https://github.com/net4people/bbs/issues/429)
- [net4people/bbs#516: Russia mobile network whitelist](https://github.com/net4people/bbs/issues/516)
- [GitHub: hxehex/russia-mobile-internet-whitelist](https://github.com/hxehex/russia-mobile-internet-whitelist)
- [GitHub: XTLS/Xray-core Discussion #4113 — XHTTP docs](https://github.com/XTLS/Xray-core/discussions/4113)
- [GitHub: XTLS/Xray-core Discussion #4118 — XHTTP 5-in-1 config](https://github.com/XTLS/Xray-core/discussions/4118)
- [Habr: Как ТСПУ ловит VLESS в 2026](https://habr.com/ru/articles/1009542/)
- [Habr: Белые списки добрались до Москвы](https://habr.com/ru/articles/1008164/)
- [Habr: Конец эпохи белых списков](https://habr.com/ru/articles/988862/)
- [Habr: РКН создали белый список для 72 AS](https://habr.com/ru/articles/997088/)
- [Habr: Эпоха белых списков](https://habr.com/ru/articles/979128/)
- [Habr: Гайд по обходу белых списков и настройке цепочки](https://habr.com/ru/articles/985674/)
