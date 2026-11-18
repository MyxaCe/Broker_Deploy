pid_file = "/tmp/agent.pid"

vault { address = "http://broker-vault:8200" }

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
