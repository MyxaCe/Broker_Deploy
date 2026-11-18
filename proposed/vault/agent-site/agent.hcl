pid_file = "/tmp/agent.pid"

vault {
  address = "http://broker-vault:8200"
}

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

template {
  destination = "/render/.env.kyc"
  perms       = "0600"
  error_on_missing_key = false
  contents = <<EOT
# СГЕНЕРИРОВАНО Vault Agent из OpenBao (secret/kyc/*). Руками не править.
S3_BUCKET={{ with secret "secret/data/kyc/s3" }}{{ .Data.data.S3_BUCKET }}{{ end }}
S3_ACCESS_KEY_ID={{ with secret "secret/data/kyc/s3" }}{{ .Data.data.S3_ACCESS_KEY_ID }}{{ end }}
S3_SECRET_ACCESS_KEY={{ with secret "secret/data/kyc/s3" }}{{ .Data.data.S3_SECRET_ACCESS_KEY }}{{ end }}
MINIO_ROOT_USER={{ with secret "secret/data/kyc/minio" }}{{ .Data.data.MINIO_ROOT_USER }}{{ end }}
MINIO_ROOT_PASSWORD={{ with secret "secret/data/kyc/minio" }}{{ .Data.data.MINIO_ROOT_PASSWORD }}{{ end }}
EOT
}
