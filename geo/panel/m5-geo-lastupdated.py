#!/usr/bin/env python3
"""Роль panel: бамп LastUpdated в happRouting, когда на CDN появилась новая геобаза.

Токен панели живёт ТОЛЬКО на этом сервере (где крутится сама панель) и используется
только для смены метки. Серверы-раздачи (роль node) токена не видят — они лишь
отдают файлы, а свежесть файлов держит их собственный крон (m5-geo-mirror.sh).

Порядок жёсткий: сначала убеждаемся, что новый файл уже ЖИВОЙ на CDN (качаем через
CDN, сверяем sha256 с эталоном релиза), и только потом бампаем LastUpdated. Так метка
не уедет вперёд файла.

LastUpdated заставляет Happ перекачать базы, минуя недельный таймер. Бампаем по таймеру
раз в неделю — если с прошлого бампа содержимое на CDN изменилось (не на каждый релиз
upstream, иначе была бы ежедневная перекачка десятков МБ у всех клиентов).

Настройки — из окружения (systemd EnvironmentFile, root-600):
    M5VPN_API_TOKEN   — токен API панели (обязателен)
    M5VPN_API_URL     — база API панели (по умолчанию https://m5vpn.com/rw/api)
    M5_GEO_CDN        — база раздачи гео (по умолчанию https://s.m5service.name/geo)
Только стандартная библиотека.

Запуск:
    python3 m5-geo-lastupdated.py            # проверить и при изменении бампнуть
    python3 m5-geo-lastupdated.py --dry-run  # только показать, ничего не менять
"""
import argparse
import base64
import hashlib
import json
import os
import sys
import time
import urllib.request

API = os.environ.get("M5VPN_API_URL", "https://m5vpn.com/rw/api")
CDN = os.environ.get("M5_GEO_CDN", "https://s.m5service.name/geo")
RELEASE = "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
FILES = ("geoip.dat", "geosite.dat")
STATE = os.environ.get("M5_GEO_STATE", "/var/lib/m5-geo/state.json")
LOG = os.environ.get("M5_GEO_LOG", "/var/log/m5-geo-lastupdated.log")


def log(msg):
    line = f"{time.strftime('%F %T', time.gmtime())}Z {msg}"
    print(line)
    try:
        with open(LOG, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError:
        pass


def fetch(url, timeout=300):
    req = urllib.request.Request(url, headers={"User-Agent": "m5-geo-lastupdated"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def panel(method, path, body=None):
    token = os.environ.get("M5VPN_API_TOKEN")
    if not token:
        sys.exit("M5VPN_API_TOKEN не задан — метку менять нечем")
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        f"{API}{path}", data=data, method=method,
        headers={"Authorization": f"Bearer {token}",
                 "Content-Type": "application/json",
                 "User-Agent": "m5-geo-lastupdated"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)["response"]


def load_state():
    try:
        with open(STATE, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def save_state(state):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    with open(STATE, "w", encoding="utf-8") as fh:
        json.dump(state, fh)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    # 1. эталонные хеши свежего релиза + 2. что реально лежит на CDN
    live = {}
    for f in FILES:
        try:
            expected = fetch(f"{RELEASE}/{f}.sha256sum", timeout=60).split()[0].decode()
        except Exception as e:
            log(f"{f}: не получить эталонный хеш ({e}) — пропуск"); return
        got = hashlib.sha256(fetch(f"{CDN}/{f}")).hexdigest()
        if got != expected:
            # ноды ещё не подтянули свежий файл — метку не двигаем, ждём
            log(f"{f}: на CDN не свежий (CDN {got[:12]} != релиз {expected[:12]}) — ждём крон нод")
            return
        live[f] = got

    # 3. изменилось ли с прошлого бампа
    state = load_state()
    if all(state.get(f) == live[f] for f in FILES):
        log("на CDN всё то же, что при прошлом бампе — метку не трогаю")
        return

    if args.dry_run:
        log("[dry-run] бампнул бы LastUpdated, новые хеши: "
            + ", ".join(f"{f}={live[f][:12]}" for f in FILES))
        return

    # 4. файл живой и новый → бампаем LastUpdated
    settings = panel("GET", "/subscription-settings")
    hr = settings["happRouting"]
    b64 = hr.split("/onadd/")[1]
    prof = json.loads(base64.b64decode(b64 + "=" * (-len(b64) % 4)))
    now = int(time.time())
    prof["LastUpdated"] = str(now)
    new_hr = "happ://routing/onadd/" + base64.b64encode(
        json.dumps(prof, ensure_ascii=False).encode()).decode().rstrip("=")
    panel("PATCH", "/subscription-settings",
          {"uuid": settings["uuid"], "happRouting": new_hr})
    save_state(live)
    log(f"LastUpdated={now}, клиенты перекачают геобазу. Хеши: "
        + ", ".join(f"{f}={live[f][:12]}" for f in FILES))


if __name__ == "__main__":
    main()
