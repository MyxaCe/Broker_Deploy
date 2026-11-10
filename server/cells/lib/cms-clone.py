#!/usr/bin/env python3
"""
Сайт-тенант новой платформы в legacy CMS: создать карточку и скопировать
контент шаблонного сайта через REST CMS (Payload 3, /api/*). Только stdlib.

Зачем скрипт, а не кнопка CMS: новый сайт в legacy CMS получает ПУСТЫЕ
черновики разделов (`ensureSiteSkeleton`), а платформа должна открыться
готовой — с навигацией, FAQ, счетами, правовыми текстами шаблона. CMS не
меняется: скрипт ходит в её обычный REST под учёткой администратора.

Секреты — ТОЛЬКО из окружения (не из argv: argv видно в `ps`):
  CMS_ADMIN_EMAIL, CMS_ADMIN_PASSWORD — учётка администратора CMS;
  CELL_WEBHOOK_SECRET — секрет вебхука сайта ячейки (create).

Команды:
  create  — идемпотентно: сайт есть → не пересоздаётся; раздел уже
            опубликован → не перетирается (правки редактора сильнее
            шаблона), если не задан --recopy.
  delete  — удалить контент сайта и карточку (для репетиций).
  show    — напечатать карточку сайта.

Что копируется: 13 разделов `site-*` (навигация, FAQ, инструменты, счета,
акции, партнёры, обучение, эфиры, контакты, карьера, правовые, статус,
главная кабинета) и статьи блога — опубликованные версии, обе локали.
Медиа (картинки внутри разделов) НЕ копируются: ссылки ведут на те же
файлы медиатеки (медиатека общая и публичная по чтению). Логотип и
favicon бренда загружаются новым файлом, если заданы.
"""
from __future__ import annotations

import argparse
import json
import mimetypes
import os
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

CONTENT_COLLECTIONS = [
    "site-navigation", "site-faq", "site-instruments", "site-accounts",
    "site-promotions", "site-partners", "site-academy", "site-streams",
    "site-contacts", "site-careers", "site-legal", "site-system-status",
    "site-cabinet-home",
]
LOCALES = ["ru", "en"]  # payload.config.ts: ru — основная, en — fallback на ru
META_KEYS = {"id", "createdAt", "updatedAt", "site", "_status", "sizes"}


def log(msg: str) -> None:
    print(f"      {msg}", flush=True)


class Cms:
    def __init__(self, base: str, dry: bool) -> None:
        self.base = base.rstrip("/")
        self.token: str | None = None
        self.dry = dry

    def _req(self, method: str, path: str, body=None, query=None, raw: bytes | None = None,
             ctype: str | None = None, ok404: bool = False):
        url = self.base + path
        if query:
            url += "?" + urllib.parse.urlencode(query, doseq=True)
        data = raw
        headers = {"Accept": "application/json"}
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        if ctype:
            headers["Content-Type"] = ctype
        if self.token:
            headers["Authorization"] = f"JWT {self.token}"
        req = urllib.request.Request(url, data=data, method=method, headers=headers)
        for attempt in range(3):
            try:
                with urllib.request.urlopen(req, timeout=60) as r:
                    txt = r.read().decode() or "{}"
                    return json.loads(txt)
            except urllib.error.HTTPError as e:
                if e.code == 404 and ok404:
                    return None
                detail = e.read().decode(errors="replace")[:800]
                if e.code >= 500 and attempt < 2:
                    time.sleep(2 * (attempt + 1))
                    continue
                raise SystemExit(f"CMS {method} {path} → HTTP {e.code}: {detail}")
            except urllib.error.URLError as e:
                if attempt < 2:
                    time.sleep(2 * (attempt + 1))
                    continue
                raise SystemExit(f"CMS недоступна ({url}): {e.reason}")
        raise SystemExit("unreachable")

    def write(self, method: str, path: str, body=None, query=None, **kw):
        if self.dry:
            log(f"[dry-run] {method} {path} {json.dumps(query or {}, ensure_ascii=False)}")
            return {"doc": {"id": "dry-run"}}
        return self._req(method, path, body=body, query=query, **kw)

    def login(self, email: str, password: str) -> None:
        r = self._req("POST", "/api/users/login", body={"email": email, "password": password})
        self.token = r.get("token")
        if not self.token:
            raise SystemExit("CMS: вход администратора не удался (нет токена)")
        if (r.get("user") or {}).get("role") != "admin":
            raise SystemExit("CMS: учётка не администратор — создавать сайты нельзя")

    def find(self, coll: str, where: dict, locale="ru", limit=1, page=1, draft=False):
        q = {"depth": "0", "limit": str(limit), "page": str(page), "locale": locale,
             "fallback-locale": "none", "draft": "true" if draft else "false"}
        for k, v in flatten_where(where):
            q[k] = v
        return self._req("GET", f"/api/{coll}", query=q)

    def get(self, coll: str, doc_id, locale="ru", draft=False):
        q = {"depth": "0", "locale": locale, "fallback-locale": "none",
             "draft": "true" if draft else "false"}
        return self._req("GET", f"/api/{coll}/{doc_id}", query=q, ok404=True)


def flatten_where(where: dict, prefix="where"):
    for k, v in where.items():
        key = f"{prefix}[{k}]"
        if isinstance(v, dict):
            yield from flatten_where(v, key)
        else:
            yield key, str(v)


# --- Преобразования документа ------------------------------------------------

def strip_meta(doc: dict) -> dict:
    return {k: v for k, v in doc.items() if k not in META_KEYS}


def strip_row_ids(v):
    """Убрать `id` строк массивов/блоков: id строки — первичный ключ таблицы
    массива, переиспользовать id шаблона нельзя (конфликт с его строками)."""
    if isinstance(v, list):
        return [strip_row_ids(x) for x in v]
    if isinstance(v, dict):
        return {k: strip_row_ids(x) for k, x in v.items() if k != "id"}
    return v


def adopt_row_ids(tmpl_other, tmpl_main, new_main):
    """Строки массива с ЛОКАЛИЗОВАННЫМИ ПОЛЯМИ внутри нелокализованного
    массива общие для обеих локалей: вторая локаль должна писать в те же
    строки, иначе перезапишет массив и потеряет первую. Признак без схемы:
    в шаблоне у строки один и тот же id в ru и en → строки общие → берём id
    новых строк из уже записанной основной локали. Разные id → массив
    локализован целиком → id просто убираем."""
    if isinstance(tmpl_other, list):
        out = []
        for i, row in enumerate(tmpl_other):
            m = tmpl_main[i] if isinstance(tmpl_main, list) and i < len(tmpl_main) else None
            n = new_main[i] if isinstance(new_main, list) and i < len(new_main) else None
            out.append(adopt_row_ids(row, m, n))
        return out
    if isinstance(tmpl_other, dict):
        shared = (isinstance(tmpl_main, dict) and isinstance(new_main, dict)
                  and "id" in tmpl_other and tmpl_other.get("id") == tmpl_main.get("id")
                  and "id" in new_main)
        out = {}
        for k, v in tmpl_other.items():
            if k == "id":
                continue
            m = tmpl_main.get(k) if isinstance(tmpl_main, dict) else None
            n = new_main.get(k) if isinstance(new_main, dict) else None
            out[k] = adopt_row_ids(v, m, n)
        if shared:
            out["id"] = new_main["id"]
        return out
    return tmpl_other


def drop_nulls(v):
    """Не писать пустые значения второй локали: пусто → читатель получит
    fallback на ru, а запись null в обязательное поле дала бы отказ."""
    if isinstance(v, list):
        return [drop_nulls(x) for x in v]
    if isinstance(v, dict):
        return {k: drop_nulls(x) for k, x in v.items() if x is not None}
    return v


def replace_text(v, pairs):
    if isinstance(v, str):
        for a, b in pairs:
            v = v.replace(a, b)
        return v
    if isinstance(v, list):
        return [replace_text(x, pairs) for x in v]
    if isinstance(v, dict):
        return {k: replace_text(x, pairs) for k, x in v.items()}
    return v


def drop_promotions(coll: str, data: dict) -> dict:
    """PROMOTIONS=off: раздел акций пуст, ссылки на /promotions убраны из
    навигации, модуль «Акции» убран с главной кабинета."""
    if coll == "site-promotions":
        return {**data, "items": []}

    def walk(v):
        if isinstance(v, list):
            return [walk(x) for x in v if not (isinstance(x, dict) and (
                str(x.get("href", "")).startswith("/promotions")
                or (coll == "site-cabinet-home" and x.get("type") == "promotions")))]
        if isinstance(v, dict):
            return {k: walk(x) for k, x in v.items()}
        return v
    return walk(data)


# --- Медиа -------------------------------------------------------------------

def upload_media(cms: Cms, path: str, alt: str):
    if cms.dry:
        log(f"[dry-run] POST /api/media ← {os.path.basename(path)} (alt «{alt}»)")
        return "dry-run"
    found = cms.find("media", {"alt": {"equals": alt}})
    if found["docs"]:
        return found["docs"][0]["id"]
    boundary = uuid.uuid4().hex
    fname = os.path.basename(path)
    mime = mimetypes.guess_type(fname)[0] or "application/octet-stream"
    with open(path, "rb") as fh:
        content = fh.read()
    parts = [
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"_payload\"\r\n\r\n".encode()
        + json.dumps({"alt": alt}).encode() + b"\r\n",
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{fname}\"\r\n"
        f"Content-Type: {mime}\r\n\r\n".encode() + content + b"\r\n",
        f"--{boundary}--\r\n".encode(),
    ]
    r = cms._req("POST", "/api/media", raw=b"".join(parts),
                 ctype=f"multipart/form-data; boundary={boundary}")
    return r["doc"]["id"]


# --- Инструменты ---------------------------------------------------------------

def filter_instruments(symbols, exclude, mds_url):
    if not exclude:
        return list(symbols)
    try:
        with urllib.request.urlopen(mds_url.rstrip("/") + "/v1/instruments", timeout=30) as r:
            items = json.loads(r.read().decode())["items"]
    except Exception as e:  # noqa: BLE001 — любой отказ MDS = отказ шага
        raise SystemExit(f"MDS недоступен, а классы для выключения заданы ({exclude}): {e}. "
                         "Без каталога нельзя понять, что выключать — отказ, а не догадка.")
    cat = {i["symbol"]: i.get("category") for i in items}
    kept = [s for s in symbols if cat.get(s) not in exclude]
    dropped = [s for s in symbols if cat.get(s) in exclude]
    log(f"инструменты: {len(kept)} оставлено, выключено {len(dropped)} ({', '.join(exclude)})")
    return kept


# --- Команды -----------------------------------------------------------------

def site_by_slug(cms: Cms, slug: str):
    r = cms.find("sites", {"slug": {"equals": slug}})
    return r["docs"][0] if r["docs"] else None


def copy_collection(cms: Cms, coll: str, tmpl_id, new_id, pairs, promotions: bool, recopy: bool):
    tm = cms.find(coll, {"site": {"equals": tmpl_id}}, locale=LOCALES[0])
    if not tm["docs"]:
        log(f"{coll}: у шаблона нет документа — пропуск")
        return "absent"
    tmpl_main = tm["docs"][0]
    if tmpl_main.get("_status") not in (None, "published"):
        log(f"{coll}: у шаблона только черновик — пропуск")
        return "absent"

    target = cms.find(coll, {"site": {"equals": new_id}}, locale=LOCALES[0], draft=True)
    tdoc = target["docs"][0] if target["docs"] else None
    if tdoc and not recopy:
        pub = cms.find(coll, {"site": {"equals": new_id}}, locale=LOCALES[0])
        if pub["docs"] and pub["docs"][0].get("_status") == "published":
            return "kept"

    def prep(doc):
        d = replace_text(strip_meta(doc), pairs)
        if not promotions:
            d = drop_promotions(coll, d)
        return d

    main = strip_row_ids(prep(tmpl_main))
    main.update({"site": new_id, "_status": "published"})
    if tdoc:
        r = cms.write("PATCH", f"/api/{coll}/{tdoc['id']}", body=main, query={"locale": LOCALES[0]})
        doc_id = tdoc["id"]
    else:
        r = cms.write("POST", f"/api/{coll}", body=main, query={"locale": LOCALES[0]})
        doc_id = r["doc"]["id"]
    if cms.dry:
        return "copied"

    new_main = cms.get(coll, doc_id, locale=LOCALES[0])
    for loc in LOCALES[1:]:
        to = cms.get(coll, tmpl_main["id"], locale=loc)
        if not to:
            continue
        other = adopt_row_ids(prep(to), prep(tmpl_main), strip_meta(new_main))
        other = drop_nulls(other)
        other.update({"site": new_id, "_status": "published"})
        cms.write("PATCH", f"/api/{coll}/{doc_id}", body=other, query={"locale": loc})
    return "copied"


def copy_articles(cms: Cms, tmpl_id, new_id, pairs, recopy: bool):
    page, n_new, n_kept = 1, 0, 0
    while True:
        r = cms.find("articles", {"site": {"equals": tmpl_id}}, locale=LOCALES[0], limit=50, page=page)
        for art in r["docs"]:
            if art.get("_status") not in (None, "published"):
                continue
            ex = cms.find("articles", {"and": {"0": {"site": {"equals": new_id}},
                                               "1": {"slug": {"equals": art["slug"]}}}},
                          locale=LOCALES[0], draft=True)
            if ex["docs"] and not recopy:
                n_kept += 1
                continue
            main = strip_row_ids(replace_text(strip_meta(art), pairs))
            main.update({"site": new_id, "_status": "published"})
            if ex["docs"]:
                doc_id = ex["docs"][0]["id"]
                cms.write("PATCH", f"/api/articles/{doc_id}", body=main, query={"locale": LOCALES[0]})
            else:
                w = cms.write("POST", "/api/articles", body=main, query={"locale": LOCALES[0]})
                doc_id = w["doc"]["id"]
            if not cms.dry:
                for loc in LOCALES[1:]:
                    to = cms.get("articles", art["id"], locale=loc)
                    if to:
                        other = drop_nulls(strip_row_ids(replace_text(strip_meta(to), pairs)))
                        other.update({"site": new_id, "_status": "published"})
                        cms.write("PATCH", f"/api/articles/{doc_id}", body=other, query={"locale": loc})
            n_new += 1
        if not r.get("hasNextPage"):
            break
        page += 1
    log(f"статьи: скопировано {n_new}, уже были {n_kept}")


def cmd_create(cms: Cms, a) -> dict:
    tmpl = site_by_slug(cms, a.template)
    if not tmpl:
        raise SystemExit(f"шаблонного сайта «{a.template}» в CMS нет")
    pairs = []
    if tmpl.get("name") and tmpl["name"] != a.name:
        pairs.append((tmpl["name"], a.name))
    for item in filter(None, (a.replace or "").split(";")):
        if "=>" not in item:
            raise SystemExit(f"--replace: «{item}» без «=>»")
        x, y = item.split("=>", 1)
        if x:
            pairs.append((x, y))
    secret = os.environ.get("CELL_WEBHOOK_SECRET", "")
    if not secret:
        raise SystemExit("нет CELL_WEBHOOK_SECRET в окружении")
    exclude = [c for c in (a.exclude_categories or "").split() if c]

    site = site_by_slug(cms, a.slug)
    created = False
    if site is None:
        data = {
            "slug": a.slug, "name": a.name, "primaryColor": a.color,
            "socials": strip_row_ids(tmpl.get("socials") or []),
            "instruments": filter_instruments(tmpl.get("instruments") or [], exclude, a.mds_url),
            "demoStartBalanceCents": a.demo_balance,
            "webhookUrl": a.webhook_url, "webhookSecret": secret,
        }
        r = cms.write("POST", "/api/sites", body=data)
        site = r["doc"]
        created = True
        log(f"сайт {a.slug} {'создал бы' if cms.dry else 'создан'} в CMS (id={site['id']}); каркас разделов — хуком CMS")
    else:
        log(f"сайт {a.slug} уже есть в CMS (id={site['id']}) — карточку не пересоздаю")
        patch = {"webhookUrl": a.webhook_url, "webhookSecret": secret}
        if a.rebrand:
            patch.update({"name": a.name, "primaryColor": a.color,
                          "demoStartBalanceCents": a.demo_balance,
                          "instruments": filter_instruments(tmpl.get("instruments") or [], exclude, a.mds_url)})
        cms.write("PATCH", f"/api/sites/{site['id']}", body=patch)
        log("вебхук сайта сверен с секретом ячейки" + (", бренд обновлён (--rebrand)" if a.rebrand else ""))

    media_patch = {}
    if a.logo and (created or a.rebrand or not site.get("logo")):
        media_patch["logo"] = upload_media(cms, a.logo, f"brand:{a.slug}:logo")
    if a.favicon and (created or a.rebrand or not site.get("favicon")):
        media_patch["favicon"] = upload_media(cms, a.favicon, f"brand:{a.slug}:favicon")
    if media_patch and not cms.dry:
        cms.write("PATCH", f"/api/sites/{site['id']}", body=media_patch)
        log("логотип/иконка загружены: " + ", ".join(media_patch))

    if cms.dry and created:
        log(f"[dry-run] скопировал бы из «{a.template}»: {', '.join(CONTENT_COLLECTIONS)} и статьи; "
            f"акции: {a.promotions}; замены: {pairs}")
        return {"siteId": None, "created": True}

    stats = {"copied": 0, "kept": 0, "absent": 0}
    for coll in CONTENT_COLLECTIONS:
        res = copy_collection(cms, coll, tmpl["id"], site["id"], pairs, a.promotions == "on", a.recopy)
        stats[res] += 1
    log(f"разделы: скопировано {stats['copied']}, уже опубликованы (не трогал) {stats['kept']}, "
        f"нет у шаблона {stats['absent']}")
    copy_articles(cms, tmpl["id"], site["id"], pairs, a.recopy)
    if pairs:
        log("замены текста: " + "; ".join(f"«{x}» → «{y}»" for x, y in pairs))
    return {"siteId": site["id"], "created": created}


def cmd_delete(cms: Cms, a) -> dict:
    site = site_by_slug(cms, a.slug)
    if not site:
        log(f"сайта {a.slug} в CMS нет — удалять нечего")
        return {"deleted": False}
    for coll in CONTENT_COLLECTIONS + ["articles"]:
        q = {"where[site][equals]": str(site["id"]), "limit": "1000"}
        cms.write("DELETE", f"/api/{coll}", query=q)
    for kind in ("logo", "favicon"):
        found = cms.find("media", {"alt": {"equals": f"brand:{a.slug}:{kind}"}})
        for d in found["docs"]:
            cms.write("DELETE", f"/api/media/{d['id']}")
    cms.write("DELETE", f"/api/sites/{site['id']}")
    log(f"сайт {a.slug} и его контент {'удалил бы' if cms.dry else 'удалены'} из CMS")
    return {"deleted": True}


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--base", required=True, help="адрес CMS изнутри сети, напр. http://broker-cms:3001")
    p.add_argument("--dry-run", action="store_true")
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("create")
    c.add_argument("--slug", required=True)
    c.add_argument("--name", required=True)
    c.add_argument("--color", required=True)
    c.add_argument("--template", required=True)
    c.add_argument("--webhook-url", required=True)
    c.add_argument("--demo-balance", type=int, default=1000000)
    c.add_argument("--exclude-categories", default="")
    c.add_argument("--mds-url", default="http://broker-mds:3003")
    c.add_argument("--promotions", choices=["on", "off"], default="on")
    c.add_argument("--replace", default="")
    c.add_argument("--logo", default="")
    c.add_argument("--favicon", default="")
    c.add_argument("--recopy", action="store_true", help="перезаписать уже опубликованные разделы")
    c.add_argument("--rebrand", action="store_true", help="перезаписать название/цвет/лого карточки")
    d = sub.add_parser("delete")
    d.add_argument("--slug", required=True)
    s = sub.add_parser("show")
    s.add_argument("--slug", required=True)
    a = p.parse_args()

    email = os.environ.get("CMS_ADMIN_EMAIL", "")
    password = os.environ.get("CMS_ADMIN_PASSWORD", "")
    if not email or not password:
        raise SystemExit("нет CMS_ADMIN_EMAIL / CMS_ADMIN_PASSWORD в окружении")
    cms = Cms(a.base, a.dry_run)
    cms.login(email, password)

    if a.cmd == "create":
        out = cmd_create(cms, a)
    elif a.cmd == "delete":
        out = cmd_delete(cms, a)
    else:
        out = site_by_slug(cms, a.slug) or {}
        out.pop("webhookSecret", None)
    print("RESULT " + json.dumps(out, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
