# Конфигурация стенда — источник правды (OPS-24)

Стенд — боевой хост платформы `199.195.197.126`, каталог `/srv/broker`
(НЕ прод-CRM Mica). `.git` на самой машине нет, код заливали архивами —
поэтому то, чего нет здесь, ребилд машины теряет. Этот каталог обязан
**воспроизводить стенд**: repo-файл → путь на стенде ниже.

За сессию стенд правили вживую (IP-allowlist прокси, vhost
`files.wholesalefy.com`, раздвоённый `S3_ENDPOINT`, MinIO в сети `edge`,
доставка KYC-секретов через OpenBao). OPS-24 свёл эти правки в репозиторий.

## Карта repo ↔ стенд

| repo | стенд `/srv/broker/…` | подробности |
| --- | --- | --- |
| `server/proxy/Caddyfile` | `proxy/Caddyfile` | `server/proxy/README.md` |
| `server/proxy/compose.yml` | `proxy/compose.yml` | — |
| `server/proxy/.env.example` | `proxy/.env` (600, НЕ в git) | `DOMAIN`, `ADMIN_IP` |
| `server/site/compose.yml` | `site/compose.yml` | `server/site/README.md` |
| `server/site/compose.sh` | `site/compose.sh` | обёртка, несколько `--env-file` |
| `server/site/.env.example` | `site/.env` (600, НЕ в git) | секреты стека |
| `server/backup/backup.sh` | `backup/backup.sh` | `server/backup/README.md` |
| `server/backup/restore-check.sh` | `backup/restore-check.sh` | проверка восстановлением |
| `server/backup/wait-pg.sh` | `backup/wait-pg.sh` | — |
| `proposed/vault/*` | `vault/*` | OpenBao, `proposed/vault/README.md` |

## Секретов в репозитории нет

Все значения окружения — только плейсхолдеры в `*.env.example`. Реальные
`.env` (права 600) живут на машине, `.gitignore` их не пускает (`*.key`,
`*.pem`, `authorized_keys` тоже). Unseal-материал и role_id/secret_id OpenBao
лежат ВНЕ `/srv/broker` (`/root/openbao-*`) и в бэкап/git не попадают.
Эндпоинты S3 и allowlist-адреса — конфигурация, не секрет.

## Порядок восстановления машины (обзор)

1. Внешние сети: `broker-edge`, `broker-back` (создать, если нет).
2. Секреты: `.env` каждого стека из `*.env.example`, права 600; OpenBao
   поднять и распечатать (3 из 5 ключей) — см. `proposed/vault/README.md`.
3. Прокси: `server/proxy/` → `/srv/broker/proxy`, `docker compose up -d`.
4. Стек site: `server/site/` → `/srv/broker/site`, восстановить `db-init/`
   и `.revision`, поднимать `./compose.sh up -d` (НЕ голым compose).
5. Бэкап: `server/backup/` → `/srv/broker/backup`, таймеры systemd.

Детальная процедура каждой части — в README соответствующего подкаталога.

## Чем это НЕ является

Снимок состояния на 01.11.2026. Покрыты прокси, стек site и бэкап-набор.
Ещё не зеркалированы в этом каталоге: `bus/` (кредлы и топология шины),
`glitchtip/`, `portainer/`, systemd-юниты таймеров бэкапа, схема `db-init`.
См. «что осталось» в отчёте OPS-24.
