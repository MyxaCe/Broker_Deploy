-- Проекция демо-торговли (ADR-023 фаза Т3, обратный контур).
-- Кабинет ведёт demo_accounts + позиции/сделки как ПРОЕКЦИЮ событий
-- терминала (terminal.balance.changed / trade.executed / account.opened).
-- Источник истины торгового состояния — терминал; здесь только отражение.

-- Идемпотентность консюмера: событие обрабатывается ровно один раз
-- (доставка шины at-least-once, дедуп по event_id — ADR-019).
CREATE TABLE IF NOT EXISTS processed_events (
  event_id TEXT PRIMARY KEY,
  event TEXT NOT NULL,
  processed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Открытые позиции: снапшот на пользователя (заменяется целиком при
-- terminal.balance.changed.positions — так проекция идемпотентна).
CREATE TABLE IF NOT EXISTS demo_positions (
  id UUID PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  symbol TEXT NOT NULL,
  side TEXT NOT NULL CHECK (side IN ('buy', 'sell')),
  volume NUMERIC NOT NULL,
  entry_price NUMERIC NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS demo_positions_user_idx ON demo_positions (user_id);

-- Лента сделок (для истории/«time & sales» кабинета). event_id — уникальный
-- ключ идемпотентности на уровне строки (второй эшелон к processed_events).
CREATE TABLE IF NOT EXISTS demo_trades (
  id UUID PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  event_id TEXT UNIQUE,
  trade_id TEXT NOT NULL,
  symbol TEXT NOT NULL,
  side TEXT NOT NULL CHECK (side IN ('buy', 'sell')),
  volume NUMERIC NOT NULL,
  price NUMERIC NOT NULL,
  realized_pnl_cents BIGINT,
  executed_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS demo_trades_user_idx ON demo_trades (user_id, executed_at DESC);
