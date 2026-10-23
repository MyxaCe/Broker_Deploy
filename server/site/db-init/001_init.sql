-- Схема БД сайта (ADR-018): лиды — локальный source of truth,
-- события наружу — только через transactional outbox.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS leads (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    kind        text NOT NULL CHECK (kind IN ('account-opening', 'contact')),
    email       text NOT NULL,
    locale      text NOT NULL DEFAULT 'ru' CHECK (locale IN ('ru', 'en')),
    payload     jsonb NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- Дубликаты email: уникальность только для заявок на счёт
-- (обращения в поддержку с одного email — нормальны).
CREATE UNIQUE INDEX IF NOT EXISTS leads_account_email_uniq
    ON leads (lower(email))
    WHERE kind = 'account-opening';

CREATE INDEX IF NOT EXISTS leads_created_at_idx ON leads (created_at);

-- Outbox: событие пишется В ТОЙ ЖЕ транзакции, что и бизнес-запись.
-- payload = полный envelope события (см. contract: eventEnvelopeSchema).
CREATE TABLE IF NOT EXISTS outbox (
    id              bigserial PRIMARY KEY,
    event_id        uuid NOT NULL UNIQUE,
    routing_key     text NOT NULL,
    payload         jsonb NOT NULL,
    occurred_at     timestamptz NOT NULL DEFAULT now(),
    published_at    timestamptz,
    attempts        int NOT NULL DEFAULT 0,
    next_attempt_at timestamptz NOT NULL DEFAULT now(),
    last_error      text
);

CREATE INDEX IF NOT EXISTS outbox_unpublished_idx
    ON outbox (next_attempt_at)
    WHERE published_at IS NULL;
