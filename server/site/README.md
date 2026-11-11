# Витрина, кабинет и обвязка · стек site (OPS-24)

Зеркало рабочей конфигурации стенда `<адрес-стенда>`, каталог
`/srv/broker/site`. Образы — только из реестра по хешу коммита, ни одного
`build:`, портов наружу нет (наружу выходит только прокси).

## Файл repo → путь на стенде

| repo | стенд | что это |
| --- | --- | --- |
| `server/site/compose.yml` | `/srv/broker/site/compose.yml` | стек: `db`, `web`, `cabinet`, `relay`, `consumer`, `admin`, `minio` |
| `server/site/compose.sh` | `/srv/broker/site/compose.sh` | обёртка над `docker compose` (несколько `--env-file`) |
| `server/site/.env.example` | `/srv/broker/site/.env` (600, НЕ в git) | секреты стека — плейсхолдеры |

Не зеркалируется (живёт в других местах, см. «Чего здесь нет»):
`.revision`, `db-init/*`, `../proxy/.env`, `../bus/.env`,
`../vault/rendered/.env.kyc`.

## Что здесь за конфигурация (дрейф, который сводим)

Правки сессии, которых не было в репозитории:

- **Сервис `minio`** (KYC object storage, ADM-12 / Р-454 II-1): реальный MinIO,
  образ запинен по ДАЙДЖЕСТУ (не `:latest` — урок прод-CRM), S3-порт наружу не
  проброшен. Том `minio-data`.
- **`minio` в сетях `[inside, edge]`**: `inside` — для кабинета
  (`http://minio:9000`), `edge` — чтобы прокси дотянулся для `files.<DOMAIN>`.
- **Раздвоённый `S3_ENDPOINT`** — ключевая правка OPS-24:
  - `admin` → `https://files.<домен>` (через прокси, браузер оператора
    за фильтром `ADMIN_IP`);
  - `cabinet` → `http://minio:9000` (внутренний; публичный endpoint попал бы
    под фильтр `ADMIN_IP` и PUT из кабинета получил бы 403).
  Эндпоинты — в compose.yml, не в `.env`.
- **Сервис `admin`** (центр управления ADM-01): `ADMIN_SESSION_SECRET`,
  fail-closed без него.
- **`compose.sh` + Vault**: последним `--env-file` подключается
  `../vault/rendered/.env.kyc` от Vault Agent — перекрывает KYC-ключи из `.env`;
  нет файла → fallback на `.env` (OpenBao не единая точка отказа).

## Переменные — только плейсхолдеры

Реальный `.env` — на машине (600). В git `server/site/.env.example`:
`SITE_DB_PASSWORD`, `CMS_WEBHOOK_SECRET`, `PREVIEW_SECRET`, `CMS_API_KEY`,
`ADMIN_SESSION_SECRET`, `SSO_PRIVATE_KEY_B64`, `S3_BUCKET`, `S3_ACCESS_KEY_ID`,
`S3_SECRET_ACCESS_KEY`, `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD`. Домен и
пароли шины — в соседних файлах (см. выше), в `.env` стека их нет.

## Восстановление

1. Разложить `compose.yml` и `compose.sh` (сделать исполняемым) в
   `/srv/broker/site/`.
2. Создать `/srv/broker/site/.env` из `.env.example`, подставить значения,
   `chmod 600`. Параллельно должны быть `../proxy/.env` (домен) и `../bus/.env`
   (пароли кредлов шины).
3. Положить `.revision` — полный 40-символьный хеш коммита катимых образов.
4. Восстановить `db-init/` (схема из `Sait_Platform/db/init`) — нужна только на
   пустом томе `db-data` при первом `initdb`.
5. Внешние сети `broker-edge` и `broker-back` должны существовать.
6. Поднимать ТОЛЬКО обёрткой: `cd /srv/broker/site && ./compose.sh up -d`.
   Голый `docker compose` не подставит домен и соберёт адреса как `https://.`.

## Чего здесь нет (сознательно)

- **`.revision`** — выкатываемая версия, меняется деплоем, не конфигурация.
- **`db-init/*.sql`** — вторая копия схемы, источник правды в `Sait_Platform`.
- **`../bus/`** — кредлы и топология шины (зона bus, см. `local/bus-setup.sh`).
- **`../vault/`** — конфигурация OpenBao зеркалирована отдельно в
  `proposed/vault/` (ветка ops-vault).
