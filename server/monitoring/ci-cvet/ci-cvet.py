import json
import os
import threading
import time
import traceback
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

REPO = os.environ.get("CI_REPO", "").strip()
VETKA = os.environ.get("CI_VETKA", "").strip()
PROCESS = os.environ.get("CI_PROCESS", "ci.yml").strip()
INTERVAL = int(os.environ.get("CI_INTERVAL_SEK", "600"))
TOKEN = os.environ.get("CI_TOKEN", "").strip()

if not REPO or not VETKA:
    raise SystemExit(
        "CI_REPO и CI_VETKA обязательны: без них неизвестно, чей прогон сторожить"
    )

URL = "https://api.github.com/repos/%s/actions/workflows/%s/runs?branch=%s&per_page=5" % (
    REPO,
    PROCESS,
    VETKA,
)

_zamok = threading.Lock()
_otvet = {"stroki": ["ci_zony_oshibka 1"], "kogda": 0.0}


def sprosit() -> list:
    stroki = []
    zapros = urllib.request.Request(
        URL,
        headers={
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "broker-ci-cvet",
            **({"Authorization": "Bearer " + TOKEN} if TOKEN else {}),
        },
    )
    try:
        with urllib.request.urlopen(zapros, timeout=20) as r:
            kod = r.getcode()
            telo = r.read()
            ostatok = r.headers.get("x-ratelimit-remaining")
    except urllib.error.HTTPError as e:
        ostatok = e.headers.get("x-ratelimit-remaining") if e.headers else None
        print("реестр ответил %s" % e.code)
        traceback.print_exc()
        if ostatok is not None:
            stroki.append("github_limit_ostatok %s" % ostatok)
        return stroki + ["ci_zony_oshibka 1"]
    except Exception:
        traceback.print_exc()
        return ["ci_zony_oshibka 1"]

    if ostatok is not None:
        stroki.append("github_limit_ostatok %s" % ostatok)

    if kod != 200:
        print("реестр ответил %s — состояние прогона НЕИЗВЕСТНО" % kod)
        return stroki + ["ci_zony_oshibka 1"]

    try:
        d = json.loads(telo)
    except ValueError:
        print("тело ответа не разобралось: %s" % telo[:200])
        return stroki + ["ci_zony_oshibka 1"]

    progony = d.get("workflow_runs")
    if not isinstance(progony, list):
        print("в ответе нет списка прогонов: %s" % str(d)[:200])
        return stroki + ["ci_zony_oshibka 1"]

    zavershjonnye = [p for p in progony if p.get("status") == "completed"]
    stroki.append("ci_zony_osmotreno %d" % len(zavershjonnye))

    if not zavershjonnye:
        print("по ветке %s нет ни одного завершённого прогона %s" % (VETKA, PROCESS))
        return stroki + ["ci_zony_oshibka 1"]

    posledniy = zavershjonnye[0]
    zelen = 1 if posledniy.get("conclusion") == "success" else 0
    print(
        "прогон #%s %s: %s"
        % (posledniy.get("run_number"), posledniy.get("head_sha", "")[:7],
           posledniy.get("conclusion"))
    )
    stroki.append("ci_zony_zelen %d" % zelen)
    stroki.append("ci_zony_oshibka 0")
    return stroki


def opros():
    while True:
        try:
            stroki = sprosit()
        except Exception:
            traceback.print_exc()
            stroki = ["ci_zony_oshibka 1"]
        with _zamok:
            _otvet["stroki"] = stroki
            _otvet["kogda"] = time.time()
        time.sleep(INTERVAL)


class Otvetchik(BaseHTTPRequestHandler):
    def do_GET(self):
        with _zamok:
            stroki = list(_otvet["stroki"])
            kogda = _otvet["kogda"]
        vozrast = int(time.time() - kogda) if kogda else 10 ** 6
        stroki.append("ci_zony_vozrast_sek %d" % vozrast)
        telo = ("\n".join(stroki) + "\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(telo)))
        self.end_headers()
        self.wfile.write(telo)

    def log_message(self, *a):
        pass


print("сторож цвета прогона: %s / %s / %s, опрос раз в %d с" % (REPO, VETKA, PROCESS, INTERVAL))
threading.Thread(target=opros, daemon=True).start()
HTTPServer(("0.0.0.0", 8000), Otvetchik).serve_forever()
