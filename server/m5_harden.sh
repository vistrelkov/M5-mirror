#!/bin/bash
# Регламент M5 VPN для серверов, поднятых подрядчиком (аудит 25.09.2026).
# Параметры (env): COMPOSE_DIR CRON_MIN CRON_HOUR UPD_AT REBOOT_AT(пусто=без авторебута) RELAY_PORTS RELAY_ALLOW SKIP_F2B
export DEBIAN_FRONTEND=noninteractive
echo "[1] пакеты"
echo iptables-persistent iptables-persistent/autosave_v4 boolean false | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean false | debconf-set-selections
PK="iptables-persistent unattended-upgrades"; [ -z "$SKIP_F2B" ] && PK="$PK fail2ban"
[ -n "$REBOOT_AT" ] && ! dpkg -s linux-image-generic >/dev/null 2>&1 && PK="$PK linux-image-generic"
apt-get -o DPkg::Lock::Timeout=300 install -y -q $PK > /tmp/m5_harden_apt.log 2>&1 && echo "apt ok: $PK" || { echo "APT FAIL"; tail -5 /tmp/m5_harden_apt.log; }

echo "[2] файрвол"
add(){ iptables -C "$@" 2>/dev/null || iptables -A "$@"; }
add6(){ ip6tables -C "$@" 2>/dev/null || ip6tables -A "$@"; }
add INPUT -s 5.101.115.254/32 -p tcp --dport 62050 -j ACCEPT
add INPUT -p tcp --dport 62050 -j DROP
add6 INPUT -p tcp --dport 62050 -j DROP
for rp in $RELAY_PORTS; do
  for ip in $RELAY_ALLOW; do add INPUT -s $ip/32 -p tcp --dport $rp -j ACCEPT; done
  add INPUT -p tcp --dport $rp -j DROP
done
for p in 25 465 587 2525; do add OUTPUT -p tcp --dport $p -j DROP; add6 OUTPUT -p tcp --dport $p -j DROP; done
netfilter-persistent save >/dev/null 2>&1 && echo "saved"
iptables -S | grep -E '^-A (INPUT|OUTPUT)' | grep -v -E 'DOCKER|f2b'

if [ -z "$SKIP_F2B" ]; then
echo "[3] fail2ban"
cat > /etc/fail2ban/jail.d/m5vpn.local <<'J'
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 5.101.115.254 88.210.52.208
[sshd]
enabled = true
J
systemctl enable fail2ban >/dev/null 2>&1; systemctl restart fail2ban; sleep 3
echo "f2b=$(systemctl is-active fail2ban) $(fail2ban-client status sshd 2>&1 | grep -m1 'Currently banned')"
fi

echo "[4] часовой пояс"
[ "$(date +%Z)" != "UTC" ] && { timedatectl set-timezone Etc/UTC; systemctl restart cron; }
echo "tz=$(date +%Z)"

echo "[5] еженедельный рестарт ноды"
LINE="${CRON_MIN} ${CRON_HOUR} * * 0 cd ${COMPOSE_DIR} && docker compose restart >> /var/log/weekly-restart.log 2>&1"
( crontab -l 2>/dev/null | grep -vF '&& docker compose restart' ; echo "$LINE" ) | crontab -
crontab -l | grep -v '^#'

echo "[6] автообновления"
printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' > /etc/apt/apt.conf.d/20auto-upgrades
if [ -n "$REBOOT_AT" ]; then
cat > /etc/apt/apt.conf.d/52-m5vpn-kernel-autoupdate <<C
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "${REBOOT_AT}";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
C
mkdir -p /etc/systemd/system/apt-daily-upgrade.timer.d
printf '[Timer]\nOnCalendar=\nOnCalendar=*-*-* %s:00\nRandomizedDelaySec=0\nPersistent=true\n' "$UPD_AT" > /etc/systemd/system/apt-daily-upgrade.timer.d/99-m5vpn-slot.conf
else
printf 'Unattended-Upgrade::Automatic-Reboot "false";\n' > /etc/apt/apt.conf.d/52-m5vpn-no-reboot
fi
systemctl unmask apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1
systemctl daemon-reload
systemctl enable --now unattended-upgrades apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1
apt-config dump >/dev/null && echo "apt-config ok" || echo "BROKEN APT CONFIG"
echo "timers: $(systemctl is-enabled apt-daily-upgrade.timer) next=$(systemctl list-timers apt-daily-upgrade.timer --no-legend | awk '{print $1,$2,$3}') reboot=$(apt-config dump | grep -oE 'Automatic-Reboot "[a-z]+"|Reboot-Time "[^"]+"' | tr '\n' ' ')"
echo "DONE"
