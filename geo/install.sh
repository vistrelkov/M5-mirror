#!/bin/bash
# Установщик гео-подсистемы M5. Один репозиторий, две роли.
#   ./install.sh node   — сервер-раздача (origin CDN): зеркало файлов + крон
#   ./install.sh panel  — сервер панели: контроллер LastUpdated + systemd-таймер
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROLE="${1:-}"

[ "$(id -u)" = 0 ] || { echo "нужен root"; exit 1; }

case "$ROLE" in
node)
    install -m 755 "$HERE/node/m5-geo-mirror.sh" /usr/local/sbin/m5-geo-mirror.sh
    install -m 644 "$HERE/node/m5-geo-mirror.cron" /etc/cron.d/m5-geo-mirror
    mkdir -p /var/www/geo
    echo "== первый прогон зеркала =="
    /usr/local/sbin/m5-geo-mirror.sh
    ls -l /var/www/geo
    echo
    echo ">> Осталось РУЧНОЕ: добавить в nginx (в server{}-блок, обслуживающий origin CDN)"
    echo ">> содержимое node/nginx-geo.conf (и node/nginx-rw-sub.conf, если origin=сервер панели),"
    echo ">> затем: nginx -t && systemctl reload nginx"
    echo ">> Проверка: curl -I https://<cdn-домен>/geo/geoip.dat"
    ;;
panel)
    install -m 755 "$HERE/panel/m5-geo-lastupdated.py" /usr/local/sbin/m5-geo-lastupdated.py
    install -m 644 "$HERE/panel/m5-geo-lastupdated.service" /etc/systemd/system/m5-geo-lastupdated.service
    install -m 644 "$HERE/panel/m5-geo-lastupdated.timer"   /etc/systemd/system/m5-geo-lastupdated.timer
    mkdir -p /etc/m5-geo /var/lib/m5-geo
    if [ ! -f /etc/m5-geo/panel.env ]; then
        install -m 600 "$HERE/panel/panel.env.example" /etc/m5-geo/panel.env
        echo ">> Впиши токен в /etc/m5-geo/panel.env (сейчас там заглушка)."
    fi
    systemctl daemon-reload
    systemctl enable --now m5-geo-lastupdated.timer
    echo "== таймер =="
    systemctl list-timers m5-geo-lastupdated.timer --no-pager || true
    echo
    echo ">> После ввода токена — засеять состояние текущими хешами, чтобы не бампнуть зря:"
    echo ">>   python3 -c \"import hashlib,json,os,urllib.request as u;\\"
    echo ">>   c=os.environ.get('M5_GEO_CDN','https://s.m5service.name/geo');\\"
    echo ">>   s={f:hashlib.sha256(u.urlopen(f'{c}/{f}',timeout=180).read()).hexdigest() for f in ('geoip.dat','geosite.dat')};\\"
    echo ">>   os.makedirs('/var/lib/m5-geo',exist_ok=True);open('/var/lib/m5-geo/state.json','w').write(json.dumps(s));print(s)\""
    echo ">> Проверка логики без изменений: python3 /usr/local/sbin/m5-geo-lastupdated.py --dry-run"
    ;;
*)
    echo "Использование: $0 {node|panel}"; exit 1;;
esac
