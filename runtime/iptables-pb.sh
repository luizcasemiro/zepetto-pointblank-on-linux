#!/usr/bin/env bash
# iptables-pb.sh - redireciona o 443 dos servidores de patch para a ponte local.
#
# O launcher fala HTTP puro na porta 443 (o WinHttp do Windows promove para TLS,
# o do Wine nao). A ponte em 127.0.0.1:8443 fala TLS de verdade.
#
# Idempotente: pode rodar quantas vezes quiser. Roda como root.
set -u
PORT="${PB_BRIDGE_PORT:-8443}"
HOSTS=("patch-br.zepetto.com" "patch-br-1.zepetto.com")
# IPs fixos conhecidos (fallback se o DNS falhar)
FIXOS=("103.88.232.101" "201.77.235.23")

# nunca redirecionar o proprio root (a ponte faz conexoes de saida na 443)
iptables -t nat -C OUTPUT 1 -p tcp --dport 443 -m owner --uid-owner 0 -j RETURN 2>/dev/null \
  || iptables -t nat -I OUTPUT 1 -p tcp --dport 443 -m owner --uid-owner 0 -j RETURN

ips=()
for h in "${HOSTS[@]}"; do
  while read -r ip; do
    [ -n "$ip" ] && ips+=("$ip")
  done < <(getent ahostsv4 "$h" 2>/dev/null | awk '{print $1}' | sort -u)
done
[ ${#ips[@]} -eq 0 ] && ips=("${FIXOS[@]}")

for ip in "${ips[@]}"; do
  iptables -t nat -C OUTPUT -p tcp -d "$ip" --dport 443 -j REDIRECT --to-ports "$PORT" 2>/dev/null \
    || iptables -t nat -A OUTPUT -p tcp -d "$ip" --dport 443 -j REDIRECT --to-ports "$PORT"
done

echo "regras ativas para: ${ips[*]}"
