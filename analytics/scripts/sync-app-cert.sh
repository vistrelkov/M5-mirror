#!/bin/bash
# Синхрон копии серта app.m5service.ws с СПб (источник LE) на Москву.
# Ставит cron: при продлении на СПб (~раз в 60 дн) Москва подхватит и перезагрузит nginx.
set -e
SRC=root@5.188.25.116:/etc/letsencrypt/live/app.m5service.ws
DST=/etc/nginx/certs/app
KEY=/root/.ssh/id_cert_sync
TMP=$(mktemp -d)
for f in fullchain.pem privkey.pem chain.pem cert.pem; do
  scp -q -i $KEY -o StrictHostKeyChecking=accept-new $SRC/$f $TMP/$f
done
if ! cmp -s $TMP/fullchain.pem $DST/fullchain.pem; then
  cp $TMP/*.pem $DST/
  chmod 600 $DST/privkey.pem
  nginx -t && systemctl reload nginx
  echo "$(date -u +%FT%TZ) cert updated + nginx reloaded" >> /var/log/cert-sync.log
else
  echo "$(date -u +%FT%TZ) no change" >> /var/log/cert-sync.log
fi
rm -rf $TMP
