#!/bin/sh
# Не маскировать трафик из сети Tailscale в контейнеры Docker: иначе прокси видит 172.19.0.1 вместо 100.64.x.x
# и фильтр доступа к админке по внутренней сети не работает (28.11, разрешено владельцем). Идемпотентно.
iptables -t nat -C POSTROUTING -s 100.64.0.0/10 -d 172.16.0.0/12 -j RETURN 2>/dev/null \
  || iptables -t nat -I POSTROUTING 1 -s 100.64.0.0/10 -d 172.16.0.0/12 -j RETURN
first=$(iptables -t nat -S POSTROUTING | sed -n 2p)
case "$first" in *"100.64.0.0/10"*"172.16.0.0/12"*RETURN*) ;; *)
  iptables -t nat -D POSTROUTING -s 100.64.0.0/10 -d 172.16.0.0/12 -j RETURN
  iptables -t nat -I POSTROUTING 1 -s 100.64.0.0/10 -d 172.16.0.0/12 -j RETURN ;; esac
