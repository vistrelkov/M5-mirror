# M5-subscription — получение и обновление подписки через CDN

Подписка (список серверов и конфиг для Happ) раньше отдавалась только напрямую с `m5vpn.com`.
В белых зонах и на части мобильных сетей такой запрос режется, и клиент не может ни получить,
ни обновить подписку. Теперь подписка идёт через Yandex Cloud CDN на отдельном домене —
доступном из белых списков и изолированном от туннеля.

## Как устроено

```
Happ
  │  https://s.m5service.name/rw-sub/<shortUuid>
  ▼
Yandex Cloud CDN, ресурс s.m5service.name
  │  ОТДЕЛЬНЫЙ платёжный аккаунт Яндекса — если заблокируют ресурс туннеля или его аккаунт,
  │  подписка продолжит работать. Кеш подписки выключен (no-store), она персональная.
  ▼
origin orgn.m5service.name = сервер панели (5.101.115.254)
  ├─ /rw-sub/<uuid>  → локальный RemnaWave 127.0.0.1:3100/api/sub/
  ├─ /geo/*.dat      → гео-файлы (репозиторий M5-geo)
  └─ /               → витрина «M5 Service» (site/) — маскировка
```

Гео-файлы и подписка идут через **один и тот же** CDN-ресурс. Домен нейтральный: в SNI нет
слова «vpn» (вариант `sub.m5vpn.com` отвергнут именно поэтому). Запрос подписки из Happ по
TLS-отпечатку выглядит как Firefox — неотличим от браузера.

**Маскировка.** Корень домена открывает ту же витрину сервиса аналитики «M5 Service», что и
на туннельном CDN. Посторонний видит сайт, а не VPN; подписка — один из путей этого сайта.

**Старые пользователи** продолжают получать подписку по прежней ссылке `m5vpn.com/rw-sub/...`
напрямую. RemnaWave находит пользователя по `shortUuid` и не проверяет домен, поэтому обе ссылки
работают одновременно. Чтобы перевести старых на CDN — переустановить подписку из бота.

## Состав

| Файл | Что | Где стоит |
|---|---|---|
| `nginx/orgn.m5service.name.conf` | полный server-блок origin: `/rw-sub/`, `/geo/`, витрина, ACME | панель `/etc/nginx/sites-enabled/` |
| `nginx/rw-sub.location.conf` | только блок `/rw-sub/` с пояснениями — для переноса в другой server | — |
| `site/` | витрина «M5 Service» | панель `/var/www/m5service` |

## Развёртывание с нуля

1. DNS: `orgn.m5service.name` → A на сервер панели. Серт:
   `certbot certonly --webroot -w /var/www/html -d orgn.m5service.name`.
2. `nginx/orgn.m5service.name.conf` → `/etc/nginx/sites-enabled/`, `site/` → `/var/www/m5service`,
   `nginx -t && systemctl reload nginx`.
3. Yandex Cloud CDN (отдельный аккаунт): ресурс `s.m5service.name`, источник `orgn.m5service.name`
   по HTTPS, Host к источнику = `orgn.m5service.name`; кеш для `/rw-sub/` выключен
   (источник шлёт `no-store`), для `/geo/` — по заголовкам источника. DNS `s.m5service.name` →
   CNAME на CDN, серт на CDN — Let's Encrypt от Яндекса.
4. Панель: в `/opt/remnawave/.env` выставить `SUB_PUBLIC_DOMAIN=s.m5service.name/rw-sub`, затем
   `docker compose up -d --force-recreate remnawave`. С этого момента новые ссылки выдаются на CDN.
5. Проверка: `curl -H 'x-hwid: test' https://s.m5service.name/rw-sub/<shortUuid>` — отдаёт подписку;
   `https://s.m5service.name/` — витрина.

Секретов в репозитории нет.
