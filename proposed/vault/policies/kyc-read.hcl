path "secret/data/kyc/*" {
  capabilities = ["read"]
}

path "secret/metadata/kyc/*" {
  capabilities = ["read", "list"]
}
