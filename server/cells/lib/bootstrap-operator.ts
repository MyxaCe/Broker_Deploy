/**
 * Первый оператор админки ячейки — ТА ЖЕ логика, что
 * `apps/admin/lib/bootstrap.ts` (ADM-01, Р-451), исполняемая в образе
 * chain-watcher той же ревизии: там есть `@broker/money` (журнал с
 * хеш-цепочкой — единственная реализация аппенда), `pg` и `tsx`. В рантайм-
 * образе админки `tsx` и исходников скрипта сида нет (standalone Next).
 *
 * Хеш пароля argon2id считается ОТДЕЛЬНО, в образе админки (там
 * `@node-rs/argon2` под musl) и приходит сюда готовой PHC-строкой через
 * stdin — пароль в этот процесс не попадает вовсе.
 *
 * Гарантии те же, что у сида: отказ, если в `operators` есть ЛЮБОЙ человек
 * (системные `system:*` не в счёт); вставка и запись журнала
 * `operator.bootstrap` с основанием `bootstrap` — одной транзакцией под
 * `LOCK TABLE operators`. Код выхода 10 = «уже был» (идемпотентный повтор).
 *
 * Если сид в site-platform поменяется — этот файл обязан идти за ним
 * (см. отчёт: просьба к зоне сайта вынести сид в образ админки).
 */
import { Pool } from 'pg';
import { appendJournalWithinTx } from '@broker/money';

async function readStdin(): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const c of process.stdin) chunks.push(c as Buffer);
  return Buffer.concat(chunks).toString('utf8').trim();
}

async function main(): Promise<number> {
  const login = process.env.ADMIN_BOOTSTRAP_LOGIN ?? '';
  const displayName = process.env.ADMIN_BOOTSTRAP_NAME || login;
  const url = process.env.DATABASE_URL ?? '';
  const hash = await readStdin();
  if (!login || !url) {
    console.error('нужны ADMIN_BOOTSTRAP_LOGIN и DATABASE_URL');
    return 2;
  }
  if (!hash.startsWith('$argon2id$')) {
    console.error('на stdin ожидается PHC-строка argon2id');
    return 2;
  }
  const pool = new Pool({ connectionString: url, max: 1 });
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('LOCK TABLE operators IN EXCLUSIVE MODE');
    const existing = await client.query(
      `SELECT login FROM operators WHERE login NOT LIKE 'system:%' ORDER BY created_at LIMIT 1`,
    );
    if (existing.rows.length > 0) {
      await client.query('ROLLBACK');
      console.log(`ALREADY ${existing.rows[0].login}`);
      return 10;
    }
    const inserted = await client.query(
      `INSERT INTO operators (login, display_name, role, password_hash)
       VALUES ($1, $2, 'admin', $3) RETURNING id`,
      [login, displayName, hash],
    );
    const operatorId = inserted.rows[0].id as string;
    await appendJournalWithinTx(
      {
        operatorId,
        action: 'operator.bootstrap',
        subjectKind: 'operator',
        subjectId: operatorId,
        payload: { login, role: 'admin', basis: 'bootstrap' },
      },
      client,
    );
    await client.query('COMMIT');
    console.log(`CREATED ${operatorId}`);
    return 0;
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    console.error('сид не выполнен:', (error as Error).message);
    return 3;
  } finally {
    client.release();
    await pool.end().catch(() => {});
  }
}

main().then((code) => process.exit(code));
