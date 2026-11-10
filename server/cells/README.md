# Ячейки платформ (вариант B: «новая платформа = новая ячейка»)

Проект: `_brain/ДЕМО-вторая-платформа-дизайн.md`. Владелец утвердил его 10.11.
Инструкция для владельца лежит в `docs/НОВАЯ-ПЛАТФОРМА.md`. Этот файл для
штаба: что внутри, как это проверено и как выкатить на стенд.

## Карта repo ↔ стенд

| repo `server/cells/` | стенд | что |
|---|---|---|
| `template/compose.yml` | `/srv/broker/cells/template/compose.yml` | шаблон ячейки: 11 сервисов, все имена `broker-*-<slug>` |
| `cell.sh` | `/srv/broker/cells/cell.sh` | обёртка `docker compose` для одной ячейки (как `site/compose.sh`) |
| `platform-new.sh` | `/srv/broker/cells/platform-new.sh` | 10 идемпотентных шагов, `--dry-run`, `--json` |
| `platform-destroy.sh` | `/srv/broker/cells/platform-destroy.sh` | удаление с подтверждением слагом и копией |
| `hub-prepare.sh` | `/srv/broker/cells/hub-prepare.sh` | **один раз**: том `proxy/sites` + `import sites/*.caddy` |
| `hub.conf` | `/srv/broker/cells/hub.conf` | имена контейнеров и сетей хаба, пути к его `.env` (секретов нет) |
| `platform.conf.example` | — | образец анкеты (тестовая «Nordex Markets», тестовый кошелёк) |
| `lib/*.sh` | `/srv/broker/cells/lib/` | общие функции, шина, прокси |
| `lib/cms-clone.py` | `/srv/broker/cells/lib/` | сайт-тенант и копия контента через REST CMS (stdlib) |
| `lib/bootstrap-operator.ts` | `/srv/broker/cells/lib/` | первый оператор: логика `apps/admin/lib/bootstrap.ts` |
| `test/*` | не на стенд | локальный хаб `cellt-*` и проверка наблюдением |

На хосте **экземпляр** ячейки лежит в `/srv/broker/cells/<slug>/`:
`platform.conf` (анкета), `.env` (600, секреты), `cell.env` (параметры),
`compose.yml` (копия шаблона), `.revision`, `.revision-terminal` (копия ревизий
хаба на момент создания), `FIRST-LOGIN.txt` (600).

## Решения, которые легко сломать правкой

1. **Имена сервисов `cell-*`, все внутренние адреса — полные имена
   контейнеров.** Compose вешает имя сервиса алиасом на каждую сеть сервиса. На
   стенде в `broker-edge` уже есть алиас `minio` (MinIO Apex), а в
   `broker-back` — алиас `gateway` (шлюз Apex). Сервис ячейки с именем `minio`
   на `edge` значил бы, что кабинет Apex по round-robin ходит в KYC-хранилище
   ячейки. Проверяет `test/verify-local.sh`, п. 3.
2. **`cell-term-web` не подключён к `back`.** nginx образа терминала зовёт
   `gateway:8080` (имя зашито в образ). Алиас `gateway` выдан шлюзу ячейки
   только во внутренней сети ячейки.
3. **У шины свой vhost `cell-<slug>`, а не своя очередь в `platform`.** Кредлы
   ячейки в `platform` не имеют прав вовсе. Проверено публикацией по AMQP:
   в свой vhost сообщение уходит, `platform` отвечает
   `NOT_ALLOWED - access to vhost 'platform' refused`.
4. **Общие ключи хаба** (`CMS_API_KEY`, `PREVIEW_SECRET`, `TRONGRID_API_KEY`)
   `cell.sh` читает поимённо из `site/.env` Apex. Подключать этот файл
   целиком через `--env-file` нельзя: недостающая переменная ячейки молча
   взялась бы у Apex.
5. **`db-init/` Apex не подключён.** Пустая база ячейки получает схему
   миграциями: `run --rm cell-consumer pnpm --filter @broker/db migrate`, ровно
   как при деплое витрины. Локально применилось 19 из 19, консюмер прошёл гейт
   `EXPECTED_MIGRATIONS`.
6. **Ревизия ячейки своя.** Выкат Apex её не меняет. Обновление ячейки:
   записать sha в `cells/<slug>/.revision`, выполнить `cell.sh <slug> pull`,
   затем миграцию, затем `up -d`.

7. **Шаг 10 сам сбрасывает кеш витрины** подписанным вебхуком ячейки (теги
   `cms:<ресурс>` без слага). Причина — расхождение кода: CMS шлёт сайту не
   по умолчанию теги `cms:<ресурс>:<slug>`, а витрина вешает на запросы теги
   без слага. Без сброса бренд и контент проявились бы только через час
   (страховочный revalidate). Починка — в site-platform или CMS, см. отчёт;
   после неё шаг лишний, но безвредный.

## Боевой прогон на стенде (штаб, с разрешения владельца)

0. DNS от владельца: пять A-записей на `199.195.197.126` (docs, раздел 1.2).
   Проверка: `dig +short A <имя> @1.1.1.1`.
1. Скопировать `server/cells/` в `/srv/broker/cells/` без `test/`; права
   `chmod 700 /srv/broker/cells`, `chmod +x *.sh`.
2. **Один раз:** `./hub-prepare.sh --dry-run`, затем `./hub-prepare.sh`.
   Прокси перезапустится, простой всех имён ≈ 2–5 с. Сделать в тихое окно.
   Сразу после — обновить зеркало `server/proxy/{Caddyfile,compose.yml}`.
3. `./platform-new.sh nordex-eu`: создаст анкету. Заполнить её.
4. `./platform-new.sh nordex-eu --dry-run`. На этом шаге скрипт уже логинится в
   CMS под `SEED_ADMIN_EMAIL` из `cms/.env`: проверьте, что пароль сида
   актуален (его могли сменить в интерфейсе — тогда впишите действующий в
   `cms/.env` или заведите отдельную учётку и укажите её там).
5. `./platform-new.sh nordex-eu`, ≈ 2–4 мин. Повтор безопасен.
6. Наблюдение по `docs/НОВАЯ-ПЛАТФОРМА.md`, раздел 3. Затем путь денег на
   втором кошельке (депозит → сделка → ручной вывод).
7. Репетиция: `./platform-destroy.sh nordex-eu`, затем `./platform-new.sh nordex-eu`.

## Локальная проверка (без стенда)

```
cd server/cells
bash test/local-hub.sh up                       # cellt-cms/mds/bus/proxy, портов наружу нет
export CELLS_HUB_CONF=$PWD/test/.hub/hub.conf
./platform-new.sh nordex-eu                     # первый раз — анкета; заполнить; повторить
bash test/verify-local.sh nordex-eu             # 41 проверка наблюдением
./platform-destroy.sh nordex-eu --confirm nordex-eu
bash test/local-hub.sh down
```

Хаб `test/` поднимает CMS legacy `485061e` и MDS `9461101`, те же, что на
стенде, плюс RabbitMQ 3.13 и Caddy 2.10 с внутренним CA (`local_certs`).
Caddyfile в нём — копия `server/proxy/Caddyfile` после `hub-prepare.sh`.
