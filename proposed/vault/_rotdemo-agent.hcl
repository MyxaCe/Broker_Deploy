# ВРЕМЕННЫЙ агент для доказательства ротации без рестарта (Р-456 B).
# Не часть постоянного контура — поднимается и сносится в рамках проверки.
# Та же роль AppRole `site` (kyc-read покрывает secret/data/kyc/*), поэтому
# читает и демо-путь secret/kyc/_rotdemo.
pid_file = "/tmp/agent.pid"

vault { address = "http://broker-vault:8200" }

# Статический KV перечитывается этим интервалом — ставим коротким, чтобы
# ротация была наблюдаема за секунды, а не за дефолтные 5 минут.
template_config { static_secret_render_interval = "5s" }

auto_auth {
  method "approle" {
    config = {
      role_id_file_path                   = "/agent/roleid"
      secret_id_file_path                 = "/agent/secretid"
      remove_secret_id_file_after_reading = false
    }
  }
  sink "file" { config = { path = "/tmp/agent-token" } }
}

template {
  destination          = "/render/.env.rotdemo"
  perms                = "0600"
  error_on_missing_key = false
  contents = <<EOT
S3_BUCKET={{ with secret "secret/data/kyc/_rotdemo" }}{{ .Data.data.S3_BUCKET }}{{ end }}
S3_ACCESS_KEY_ID={{ with secret "secret/data/kyc/_rotdemo" }}{{ .Data.data.S3_ACCESS_KEY_ID }}{{ end }}
S3_SECRET_ACCESS_KEY={{ with secret "secret/data/kyc/_rotdemo" }}{{ .Data.data.S3_SECRET_ACCESS_KEY }}{{ end }}
EOT
}
