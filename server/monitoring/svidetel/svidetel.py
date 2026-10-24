"""Независимый свидетель: сохранённое против пересчитанного (OPS-41).

ЗАЧЕМ. Все остальные метрики мерят ПУТЬ: дошло ли сообщение, пуста ли
очередь, жив ли потребитель. Потерянное событие о деньгах по всем ним
выглядит успешно обработанным — потребитель подтвердил, очередь пуста,
отбойник пуст. Ровно так `WEB-29` и прожил бы незамеченным.

Счётчик внутри потребителя тут не помощник: это тот же свидетель,
который уже соврал строкой «applied». Поэтому свидетель — ТРЕТИЙ, и
читает он обе стороны напрямую:

    остаток счёта у ТЕРМИНАЛА   против   остатка в проекции КАБИНЕТА

Связь — `identities.sub` терминала равен `users.id` кабинета.

ЧТО СЧИТАЕТСЯ РАСХОЖДЕНИЕМ, А ЧТО НЕТ. Сравниваются только пары, где
счёт есть у ОБОИХ. Человек, который зарегистрировался и ни разу не
открывал терминал, имеет счёт в кабинете и не имеет в терминале — это
норма, а не потеря, и она считается отдельным числом.

ОХВАТ ОБЪЯВЛЯЕТСЯ ЧИСЛОМ. «Расхождений нет» без числа сопоставленных —
это «проверять было нечего», выданное за «всё сошлось».

ОТКАЗ САМОГО СВИДЕТЕЛЯ ВИДЕН. Если он не смог прочитать любую из сторон,
он отдаёт `svidetel_oshibka 1` и НЕ отдаёт нулевых расхождений: молчащая
проверка не должна выглядеть пройденной.
"""

import os
import traceback
from http.server import BaseHTTPRequestHandler, HTTPServer

import psycopg2


def sobrat() -> str:
    stroki = []
    try:
        with psycopg2.connect(os.environ["TERMINAL_DSN"]) as tc, tc.cursor() as t:
            t.execute(
                "select i.sub, a.balance from identities i "
                "join accounts a on a.user_id = i.user_id"
            )
            terminal = {str(sub): int(bal) for sub, bal in t.fetchall()}

        with psycopg2.connect(os.environ["SITE_DSN"]) as sc, sc.cursor() as c:
            c.execute(
                "select u.id::text, u.email, d.balance_cents "
                "from users u join demo_accounts d on d.user_id = u.id"
            )
            kabinet = {sub: (email, int(bal)) for sub, email, bal in c.fetchall()}
    except Exception:
        # Отказ проверки — не ноль расхождений. Печатаем причину в журнал
        # контейнера: подавленная диагностика дороже шумной.
        traceback.print_exc()
        return "svidetel_oshibka 1\n"

    sopostavleno = 0
    bez_pary = 0
    for sub, (email, ostatok_kabineta) in kabinet.items():
        if sub not in terminal:
            bez_pary += 1
            continue
        sopostavleno += 1
        raznica = terminal[sub] - ostatok_kabineta
        stroki.append(
            'rashozhdenie_balansa_cents{email="%s"} %d' % (email.replace('"', ""), raznica)
        )

    stroki.append("svidetel_sopostavleno %d" % sopostavleno)
    stroki.append("svidetel_bez_pary %d" % bez_pary)
    stroki.append("svidetel_oshibka 0")
    return "\n".join(stroki) + "\n"


class Otvetchik(BaseHTTPRequestHandler):
    def do_GET(self):
        telo = sobrat().encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(telo)))
        self.end_headers()
        self.wfile.write(telo)

    def log_message(self, *a):
        pass


HTTPServer(("0.0.0.0", 8000), Otvetchik).serve_forever()
