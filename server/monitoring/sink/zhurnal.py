"""Приёмник оповещений до появления адресата.

Пишет каждое оповещение в журнал контейнера И в файл на томе. Нужен он не
как заглушка: без него «оповещения настроены» проверялось бы чтением
конфигурации, а не срабатыванием. С ним путь правило → Alertmanager →
получатель пройден целиком и его можно показать.
"""
import datetime, json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

FILE = "/zhurnal/opoveshcheniya.log"


class Priyomnik(BaseHTTPRequestHandler):
    def do_POST(self):
        telo = self.rfile.read(int(self.headers.get("Content-Length", 0) or 0))
        try:
            d = json.loads(telo or b"{}")
        except Exception:
            d = {"raw": telo.decode("utf-8", "replace")[:500]}
        t = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
        for a in d.get("alerts", [{}]):
            stroka = "%s  %-9s %-28s %s" % (
                t,
                (a.get("status") or d.get("status") or "?").upper(),
                (a.get("labels") or {}).get("alertname", "?"),
                (a.get("annotations") or {}).get("summary", ""),
            )
            print(stroka, flush=True)
            try:
                with open(FILE, "a", encoding="utf-8") as f:
                    f.write(stroka + "\n")
            except OSError as e:
                # Не глушим: файл недоступен — это отказ приёмника, а не фон.
                print("ПРИЁМНИК НЕ СМОГ ЗАПИСАТЬ В ФАЙЛ: %s" % e, file=sys.stderr, flush=True)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"zhurnal alertov\n")

    def log_message(self, *a):
        pass


HTTPServer(("0.0.0.0", 8080), Priyomnik).serve_forever()
