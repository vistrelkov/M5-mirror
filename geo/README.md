# M5-geo — гео-файлы через свой CDN с автообновлением

Happ по правилам маршрутизации использует `geoip.dat` и `geosite.dat` (что пускать мимо VPN).
По умолчанию он качает их с GitHub — из РФ, особенно с мобильного, это часто не проходит.
Здесь гео-файлы раздаются со своего сервера через Yandex Cloud CDN и обновляются сами.

## Как устроено

```
Happ  → https://s.m5service.name/geo/{geoip,geosite}.dat   (ссылки — в happRouting подписки)
      → Yandex Cloud CDN (тот же изолированный ресурс, что и подписка — см. M5-subscription)
      → origin orgn.m5service.name = сервер панели, /var/www/geo
```

Две части:

1. **Зеркало** (`node/`): cron раз в 6 ч сверяет `.sha256sum` релиза
   [Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat); если вышел
   новый — качает, проверяет sha256 и **атомарно** подменяет файл. Битый файл не публикуется.
   Файлы байт-в-байт как у Loyalsoldier.
2. **Обновление у клиентов** (`panel/`): Happ сам перекачивает гео не чаще раза в неделю.
   Служба раз в неделю (пн 04:00 UTC) скачивает файлы **через CDN**, сверяет хеш и, если он
   изменился, меняет поле `LastUpdated` в `happRouting` подписки — Happ видит новую метку и
   перекачивает. Порядок жёсткий: сначала убедились, что свежий файл отдаётся, потом метка.

**Маскировка.** Гео лежит по пути `/geo/` на домене, корень которого — витрина сервиса
аналитики «M5 Service». Для постороннего это статические файлы сайта. Запрос Happ за гео по
TLS-отпечатку — как у Firefox.

## Установка

В M5 обе роли стоят на сервере панели (он же origin CDN).

```bash
sudo ./install.sh node    # зеркало + cron, первый прогон; затем вставить node/nginx-geo.conf в server{} origin
sudo ./install.sh panel   # служба LastUpdated + таймер; вписать токен API панели в /etc/m5-geo/panel.env
```

Проверка:
```bash
curl -I https://s.m5service.name/geo/geoip.dat              # 200
python3 /usr/local/sbin/m5-geo-lastupdated.py --dry-run      # логика без изменений
systemctl list-timers m5-geo-lastupdated.timer
tail /var/log/m5-geo-mirror.log
```

## Файлы

```
node/   m5-geo-mirror.sh · m5-geo-mirror.cron · nginx-geo.conf
panel/  m5-geo-lastupdated.py · .service · .timer · panel.env.example
install.sh
```

Токен панели — только в `/etc/m5-geo/panel.env` на сервере (в git не попадает, см. `.gitignore`).
