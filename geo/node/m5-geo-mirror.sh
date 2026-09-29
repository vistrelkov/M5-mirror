#!/bin/bash
# Роль node: зеркало geoip.dat / geosite.dat от Loyalsoldier для раздачи через CDN.
# Раздаём файлы БАЙТ В БАЙТ, ничего не пересобираем. Раз в 6 ч сверяем хеш
# опубликованного релиза (.dat.sha256sum), при расхождении качаем новый,
# проверяем sha256 и только при совпадении атомарно подменяем. Битый/недокачанный
# файл клиентам не уходит. Секретов не держит — ставится на каждый origin отдельно.
set -euo pipefail

GEO_DIR=/var/www/geo
BASE=https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download
LOG=/var/log/m5-geo-mirror.log
FILES="geoip.dat geosite.dat"

log() { echo "$(date -u '+%F %T')Z $*" >>"$LOG"; }

mkdir -p "$GEO_DIR"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

changed=0
for f in $FILES; do
    exp=$(curl -fsSL --retry 2 --max-time 60 "$BASE/$f.sha256sum" | awk '{print $1}') || {
        log "$f: не удалось получить .sha256sum, пропуск"; continue; }
    if [ -z "$exp" ]; then log "$f: пустой .sha256sum, пропуск"; continue; fi

    cur=""
    [ -f "$GEO_DIR/$f" ] && cur=$(sha256sum "$GEO_DIR/$f" | awk '{print $1}')
    if [ "$exp" = "$cur" ]; then continue; fi   # уже свежий

    curl -fsSL --retry 2 --max-time 300 -o "$TMP/$f" "$BASE/$f" || {
        log "$f: скачивание не удалось, пропуск"; continue; }
    got=$(sha256sum "$TMP/$f" | awk '{print $1}')
    if [ "$got" != "$exp" ]; then
        log "$f: хеш не сошёлся (ждали $exp, получили $got) — не публикуем"; continue
    fi

    chmod 644 "$TMP/$f"
    mv -f "$TMP/$f" "$GEO_DIR/$f"   # атомарная замена в пределах одной ФС
    log "$f: обновлён -> $got ($(stat -c%s "$GEO_DIR/$f") байт)"
    changed=1
done

[ "$changed" = 1 ] && log "готово, файлы обновлены" || true
exit 0
