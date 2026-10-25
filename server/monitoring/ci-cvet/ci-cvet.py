"""Цвет собственного прогона зоны — метрикой. B-OPS-038.

ЗАЧЕМ. CI зоны `deploy` простоял красным восемь прогонов, и не заметил
этого я сам. Причина не в лени: из зоны `deploy` образы не собираются,
значит прогон ничего не задерживал, а **проверка, которая никого не
блокирует, не напоминает о себе ничем**. Смотреть чужие прогоны меня
заставляли образы; смотреть свой — ничто.

Запрет был бы сильнее звонка, но болезнь была про ТИШИНУ, а не про
отсутствие запрета, и лекарство от тишины — напоминание. Запрет придёт
отдельно и позже: сперва скрипты зоны должны уметь называть свою
ревизию, иначе гейт на их выкатку будет отвечать про чужой коммит.

ЧТО ЗДЕСЬ СДЕЛАНО ПРОТИВ ВЧЕРАШНИХ ОШИБОК

* **Охват объявлен числом.** `ci_zony_osmotreno` — сколько прогонов
  увидели. Ноль прогонов это не зелень: при нуле отдаётся ошибка, а не
  спокойствие.
* **«Не ответили» отделено от «ничего нет».** Превышение предела
  возвращает ОБЪЕКТ вместо списка, и разбор, написанный под список,
  получает пустоту — отказ становится неотличим от чистоты
  (B-OPS-039). Поэтому сначала код ответа, потом тело, и тело обязано
  оказаться списком.
* **При любой неясности `ci_zony_zelen` НЕ ОТДАЁТСЯ ВОВСЕ.** Отдать
  ноль значило бы соврать «прогон красный»; отдать единицу — соврать
  сильнее. Молчание о значении плюс `ci_zony_oshibka 1` — честный
  ответ, и на него заведена своя тревога.
* **Возраст ответа виден.** `ci_zony_vozrast_sek` растёт, если опрос
  перестал обновляться: застывший сторож иначе неотличим от
  спокойного.

ЦЕНА ОПРОСА НАЗВАНА. Анонимный предел GitHub — 60 запросов в час НА
АДРЕС, а адрес у зон общий: выход один на всех. Поэтому опрашиваем раз
в десять минут (6 в час), а не на каждый сбор Prometheus, и остаток
предела отдаём метрикой `github_limit_ostatok` — он приходит в
заголовках того же ответа и не стоит отдельного запроса.
"""

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

# Незаданное — это отказ на старте, а не работа по умолчанию. Служба,
# опрашивающая пустой адрес, отдавала бы ошибку вечно и выглядела бы
# сломанной, а не ненастроенной.
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
        # 403 превышения приходит именно сюда и несёт ТЕЛО ДРУГОЙ ФОРМЫ.
        # Остаток предела в заголовках есть и у отказа — он тут важнее
        # всего, потому что объясняет отказ.
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
    # Не `or []`: отсутствие списка — это «ответили не тем», а не
    # «прогонов нет». Склейка этих двух и есть способ, которым сторож
    # перестаёт сторожить.
    if not isinstance(progony, list):
        print("в ответе нет списка прогонов: %s" % str(d)[:200])
        return stroki + ["ci_zony_oshibka 1"]

    zavershjonnye = [p for p in progony if p.get("status") == "completed"]
    stroki.append("ci_zony_osmotreno %d" % len(zavershjonnye))

    # ОХВАТ: ноль завершённых прогонов — не зелень. Ветка могла быть
    # переименована, процесс выключен, фильтр промахнуться. Любая из
    # этих причин означает «не знаю», а не «всё хорошо».
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
        # Возраст ответа — отдельная величина. Застывший опрос иначе
        # неотличим от спокойного: строки те же, просто старые.
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
