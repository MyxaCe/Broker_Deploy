ui = true

storage "raft" {
  path    = "/openbao/data"
  node_id = "bao-stand-1"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}

api_addr     = "http://broker-vault:8200"
cluster_addr = "http://broker-vault:8201"
