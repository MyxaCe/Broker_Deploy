# Vault Agent (OpenBao Agent) витрины/кабинета — доставка секретов KYC.
#
# Логинится по AppRole `site` (политика kyc-read, только чтение secret/kyc/*),
# рендерит файл-фрагмент /render/.env.kyc, который compose.sh витрины читает
# ДОПОЛНИТЕЛЬНЫМ --env-file. Значения приходят из OpenBao, а не правятся
# руками в .env — это и есть «sidecar-абстракция» доставки. Приложения и их
# образы НЕ меняются.
#
# role_id/secret_id лежат на стенде файлами с правами 600 и смонтированы сюда
# только на чтение. В репозиторий они не попадают (.gitignore).

pid_file = "/tmp/agent.pid"

vault {
  address = "http://broker-vault:8200"
}

# KV v2 — статические секреты (без lease). Перечитываются этим интервалом:
# 30s, чтобы ротация ключа в OpenBao доезжала до .env.kyc за полминуты, а не
# за дефолтные 5 минут. Это НЕ рестарт — агент перерендеривает файл на месте.
template_config {
  static_secret_render_interval = "30s"
}

auto_auth {
  method "approle" {
    config = {
      role_id_file_path                   = "/agent/roleid"
      secret_id_file_path                 = "/agent/secretid"
      remove_secret_id_file_after_reading = false
    }
  }

  sink "file" {
    config = {
      path = "/tmp/agent-token"
    }
  }
}

# API-прокси агента не нужен наружу — только шаблоны.
template {
  destination = "/render/.env.kyc"
  perms       = "0600"
  # Если OpenBao недоступен/запечатан, агент НЕ затирает последний
  # отрендеренный файл (error_on_missing_key=false, существующий файл
  # сохраняется). compose.sh витрины держит базовый .env как fallback.
  error_on_missing_key = false
  # Строки БЕЗ отступа: это env-file, ведущие пробелы испортили бы имя ключа.
  contents = <<EOT
# СГЕНЕРИРОВАНО Vault Agent из OpenBao (secret/kyc/*). Руками не править.
S3_BUCKET={{ with secret "secret/data/kyc/s3" }}{{ .Data.data.S3_BUCKET }}{{ end }}
S3_ACCESS_KEY_ID={{ with secret "secret/data/kyc/s3" }}{{ .Data.data.S3_ACCESS_KEY_ID }}{{ end }}
S3_SECRET_ACCESS_KEY={{ with secret "secret/data/kyc/s3" }}{{ .Data.data.S3_SECRET_ACCESS_KEY }}{{ end }}
MINIO_ROOT_USER={{ with secret "secret/data/kyc/minio" }}{{ .Data.data.MINIO_ROOT_USER }}{{ end }}
MINIO_ROOT_PASSWORD={{ with secret "secret/data/kyc/minio" }}{{ .Data.data.MINIO_ROOT_PASSWORD }}{{ end }}
EOT
}
