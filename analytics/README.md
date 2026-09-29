# M5-analytics — маскировка CDN-туннеля под веб-аналитику

Путь обхода белых списков идёт через Yandex Cloud CDN. Чтобы этот трафик выглядел как работа
обычного сервиса, а не VPN, за CDN стоит настоящий сервис веб-аналитики **M5 Service**:
витрина, документация, счётчик посещаемости (umami) с кабинетом. Туннель прячется в «приём
событий аналитики» — запросы вида `/collect/v2/e/<страна>/...`.

## Как устроено

```
Клиент (Happ)
  │  VLESS + XHTTP (packet-up, HTTP/2) поверх TLS, SNI/Host = media.m5service.ws
  ▼
Yandex Cloud CDN, ресурс media.m5service.ws  (TLS снимает CDN)
  │  группа источников: o2.m5service.ws (Москва) — основной, app.m5service.ws (СПб) — запасной
  ▼
nginx источника (Москва 193.124.67.94 / СПб 5.188.25.116)
  ├─ /                      витрина «M5 Service — веб-аналитика»   (site/)
  ├─ /docs.html, /assets/   документация и стили                   (site/)
  ├─ /m5s.js, остальное     счётчик и кабинет umami                (umami/, живёт на СПб)
  └─ /collect/v2/e/<cc>/    туннель → локальный xray, порт по стране (10810–10818)
                            bg de ee fi it md nl pl us
  ▼
xray (remnanode, профиль M5-CDN-ORIGIN в панели) → ноды стран
```

Для постороннего глаза это сайт аналитики, который принимает события со страниц клиентов.
Кабинет и счётчик — живые (umami), а не заглушка.

## Состав

| Папка | Что | Где стоит |
|---|---|---|
| `umami/` | docker-compose umami + Postgres 16 | СПб `/opt/m5service` |
| `site/` | витрина и документация (статика) | обе точки, `/var/www/m5service` |
| `nginx/spb/` | server-блок `app.m5service.ws` | СПб `/etc/nginx/sites-available/` |
| `nginx/moscow/` | `m5service.conf` (map страна→порт, два server-блока), `m5s-site.conf` (общие location), `00-acme.conf` | Москва `/etc/nginx/conf.d/`, `/etc/nginx/snippets/` |
| `xray/M5-CDN-ORIGIN.profile.json` | конфиг-профиль панели: 9 инбаундов XHTTP на 127.0.0.1:10810–10818, путь `/collect/v2/e/`, xPadding-маскировка | панель RemnaWave → Config Profiles |
| `node/docker-compose.yml` | remnanode (исполняет профиль) | обе точки, `/opt/remnanode` (`.env` с ключом ноды — из панели) |
| `scripts/sync-app-cert.sh` | копия серта `app.m5service.ws` с СПб на Москву, cron `17 4 * * *` | Москва `/root/` |

## Развёртывание с нуля (кратко)

1. **СПб (основной сервер аналитики):**
   `umami/` → `/opt/m5service`, заполнить `.env` по `.env.example`, `docker compose up -d`.
   `site/` → `/var/www/m5service`. `nginx/spb/app.m5service.ws.conf` → sites-available + симлинк.
   Серт: `certbot certonly --webroot -w /var/www/html -d app.m5service.ws`.
2. **Москва (основной источник CDN):** `nginx/moscow/*` → conf.d и snippets, `site/` → `/var/www/m5service`.
   Серт `o2.m5service.ws` — certbot; копия `app.m5service.ws` — `scripts/sync-app-cert.sh` + cron
   (нужен SSH-ключ `/root/.ssh/id_cert_sync`, публичная часть — в `authorized_keys` СПб).
3. **Обе точки:** нода RemnaWave (`node/docker-compose.yml`, `.env` из панели), в панели ноде
   назначить профиль `M5-CDN-ORIGIN` (`xray/`).
4. **Yandex Cloud CDN:** ресурс `media.m5service.ws`, группа источников (o2 основной, app запасной),
   протокол к источнику HTTPS, Host к источнику = `app.m5service.ws`. POST на CDN закрыт — поэтому
   в XHTTP `uplinkHTTPMethod: GET`.
5. В панели на каждую страну — скрытый хост `cdn` (адрес `media.m5service.ws:443`, TLS, XHTTP,
   путь `/collect/v2/e/<cc>/`), его подхватывает шаблон подписки M5-SMART.

## Секреты

В репозитории их нет. Пароль БД и `APP_SECRET` umami — в `umami/.env` (по `.env.example`),
ключ ноды — в `/opt/remnanode/.env` из панели, сертификаты — certbot на серверах.
