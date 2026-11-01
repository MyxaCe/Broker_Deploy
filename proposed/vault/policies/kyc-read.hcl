# Политика least-privilege: только ЧТЕНИЕ секретов KYC.
# KV v2 кладёт данные под secret/data/<путь>, метаданные — под secret/metadata/<путь>.
# Выдаётся AppRole `site` (агент витрины/кабинета) — см. README.

path "secret/data/kyc/*" {
  capabilities = ["read"]
}

path "secret/metadata/kyc/*" {
  capabilities = ["read", "list"]
}
