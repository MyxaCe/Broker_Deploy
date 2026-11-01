# OpenBao — конфигурация узла на стенде (Р-456 B).
#
# Один узел, integrated storage (raft) — внешней БД не требует.
# TLS ВНУТРИ broker-back ОТКЛЮЧЁН СОЗНАТЕЛЬНО и это решение штаба (спека,
# «listener без TLS внутри broker-back либо mTLS — решение штаба»): наружу
# порт не публикуется (см. compose.yml, ports нет), в сеть broker-back ходят
# только свои контейнеры. Включение TLS/mTLS — отдельным заходом, когда штаб
# решит выставлять UI наружу через прокси под ADMIN_IP (открытый вопрос 4 спеки).

ui = true

# mlock: OpenBao 2.7 УБРАЛ поддержку mlock вовсе (upstream). Поэтому ни
# `disable_mlock`, ни capability IPC_LOCK здесь больше не используются
# (в compose.yml IPC_LOCK снят). Защита секретов от попадания в своп теперь
# делается на уровне ХОСТА: отключить или зашифровать swap. На стенде есть
# /swapfile 4G — это решение владельца/ops (см. README, остаточные риски),
# не меняем своп машины из задачи по секретам.

storage "raft" {
  path    = "/openbao/data"
  node_id = "bao-stand-1"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}

# Адреса, по которым узел зовёт сам себя и свой кластер. Имя broker-vault —
# это container_name, оно резолвится в сети broker-back.
api_addr     = "http://broker-vault:8200"
cluster_addr = "http://broker-vault:8201"
