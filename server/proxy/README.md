# Прокси стенда · Caddy (OPS-24)

Обратный прокси платформы: единственная служба с портами наружу (80/443),
сам получает и продлевает сертификаты. Зеркало рабочей конфигурации стенда
`<адрес-стенда>`, каталог `/srv/broker/proxy`.

## Файл repo → путь на стенде

| repo | стенд | что это |
| --- | --- | --- |
| `server/proxy/Caddyfile` | `/srv/broker/proxy/Caddyfile` | vhosts и фильтры источника |
| `server/proxy/compose.yml` | `/srv/broker/proxy/compose.yml` | сервис `caddy` (`broker-proxy`) |
| `server/proxy/.env.example` | `/srv/broker/proxy/.env` (600, НЕ в git) | `DOMAIN`, `ADMIN_IP` |

## Что здесь за конфигурация (дрейф, который сводим)

За сессию прокси правили вживую; в репозитории этого не было. Зеркалировано:

- **Фильтр источника `(adminonly)`** — сниппет `@chuzhoy not remote_ip {$ADMIN_IP}`
  → `403`. Импортируется в vhosts, которые наружу не смотрят.
- **vhosts**: `{$DOMAIN}` (витрина + публичные ручки MDS: `/v1/quotes`,
  `/v1/instruments`, иконки, `socket.io`), `cabinet.`, `terminal.`,
  `cms.` (за `adminonly`), `admin.` (отдельный allowlist по IP, не `ADMIN_IP`),
  и **`files.{$DOMAIN}` → `broker-minio:9000`** (просмотр KYC оператором, за
  `adminonly`) — именно его добавляли вживую (OPS-24, ADM-12 / Р-456 B).
- **`compose.yml`**: прокси включён в ВНЕШНЮЮ сеть `broker-edge` (`edge`) — так
  он дотягивается до приложений и до MinIO по имени контейнера, а приложения
  портов не публикуют.

## Переменные — только плейсхолдеры

`DOMAIN` и `ADMIN_IP` приходят из `/srv/broker/proxy/.env` (в git только
`.env.example`). Caddyfile ссылается на них через `{$DOMAIN}` / `{$ADMIN_IP}` —
реальных значений в репозитории нет.

Allowlist центра управления `admin.{$DOMAIN}` задан ТОЧНЫМИ адресами прямо в
Caddyfile (вход через Tailscale/mgmt-vdc1). Это не секрет (IP-источник, не
ключ), и это сознательно НЕ `ADMIN_IP`: у `admin` фильтр уже, чем у CMS.

## Восстановление

1. Разложить `Caddyfile` и `compose.yml` в `/srv/broker/proxy/`.
2. Создать `/srv/broker/proxy/.env` из `.env.example`, подставить реальные
   `DOMAIN` и `ADMIN_IP`, права `chmod 600`.
3. Внешняя сеть `broker-edge` должна существовать до подъёма
   (`docker network create broker-edge`, если её нет).
4. `cd /srv/broker/proxy && docker compose up -d`.

Том `caddy-data` (сертификаты) беречь: при частых пересозданиях упрёмся в
лимит выдач CA.
