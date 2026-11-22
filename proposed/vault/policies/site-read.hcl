path "secret/data/site/*" {
  capabilities = ["read"]
}

path "secret/metadata/site/*" {
  capabilities = ["read", "list"]
}
