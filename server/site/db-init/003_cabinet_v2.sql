-- Главная кабинета v2 (ADR-026): публичный номер пользователя и VIP-уровень.
-- uid — то, что пользователь видит и называет поддержке (не UUID);
-- vip_level — уровень программы лояльности (логика уровней — Ф3).

ALTER TABLE users ADD COLUMN IF NOT EXISTS uid BIGINT;
CREATE SEQUENCE IF NOT EXISTS users_uid_seq START 100001 OWNED BY users.uid;
ALTER TABLE users ALTER COLUMN uid SET DEFAULT nextval('users_uid_seq');
UPDATE users SET uid = nextval('users_uid_seq') WHERE uid IS NULL;
ALTER TABLE users ALTER COLUMN uid SET NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS users_uid_unique ON users (uid);

ALTER TABLE users ADD COLUMN IF NOT EXISTS vip_level INT NOT NULL DEFAULT 0;
