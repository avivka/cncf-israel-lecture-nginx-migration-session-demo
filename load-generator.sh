#!/usr/bin/env bash
# load-generator.sh — LIVE TRAFFIC THAT FOLLOWS DNS CHANGES
#
# This is the zero-downtime proof. It queries Azure DNS on every cycle,
# gets the current A record IPs, and hits them. When DNS changes during
# the canary cutover, the load generator follows — and never drops.
#
# Run this in a SECOND TERMINAL visible to the audience.
#
# Usage:
#   ./load-generator.sh                        # uses defaults
#   ./load-generator.sh <RESOURCE_GROUP>        # custom RG

set -euo pipefail

RG="${1:-${RESOURCE_GROUP:-cncf-nginx-migration-demo}}"
DNS_ZONE="${DNS_ZONE:-demo.cncf-migration.local}"
DNS_RECORD="${DNS_RECORD:-app}"
HOST="app.${DNS_ZONE}"
INTERVAL=0.5

clear
echo ""
echo "  ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
echo "  ┃            LIVE TRAFFIC — ZERO DOWNTIME PROOF                    ┃"
echo "  ┃                                                                  ┃"
echo "  ┃  This queries Azure DNS for the A record on every request.       ┃"
echo "  ┃  When DNS changes (canary), traffic follows — and never drops.   ┃"
echo "  ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
echo ""
echo "  DNS Record:  ${DNS_RECORD}.${DNS_ZONE}"
echo "  Host header: ${HOST}"
echo "  Interval:    ${INTERVAL}s"
echo "  Started:     $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# ─── Detect controller IPs for labeling ──────────────────────────────────────
NGINX_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
TRAEFIK_IP=$(kubectl get svc traefik -n traefik \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

echo "  Known IPs:"
[ -n "${NGINX_IP}" ]  && echo "    NGINX:   ${NGINX_IP}"
[ -n "${TRAEFIK_IP}" ] && echo "    Traefik: ${TRAEFIK_IP}"
echo ""
echo "  ───────────────────────────────────────────────────────────────────"
printf "  %-10s │ %-6s │ %-7s │ %-16s │ %-10s │ %s\n" \
  "TIME" "STATUS" "LATENCY" "TARGET IP" "CONTROLLER" "DNS IPs"
echo "  ───────────────────────────────────────────────────────────────────"

SUCCESS=0
FAIL=0
REQ=0
LAST_DNS_IPS=""

while true; do
  REQ=$((REQ + 1))
  TS=$(date '+%H:%M:%S')

  # ── Query Azure DNS for current A record IPs ──────────────────────────────
  DNS_IPS=$(az network dns record-set a show \
    -g "${RG}" -z "${DNS_ZONE}" -n "${DNS_RECORD}" \
    --query "aRecords[].ipv4Address" -o tsv 2>/dev/null | tr '\n' ' ' | xargs)

  if [ -z "${DNS_IPS}" ]; then
    printf "  \033[33m%-10s │ ---    │ ---     │ %-16s │ %-10s │ DNS EMPTY\033[0m\n" \
      "${TS}" "---" "---"
    sleep "${INTERVAL}"
    continue
  fi

  # Show when DNS changes
  if [ "${DNS_IPS}" != "${LAST_DNS_IPS}" ] && [ -n "${LAST_DNS_IPS}" ]; then
    echo ""
    printf "  \033[1;36m  >>> DNS CHANGED: [%s] → [%s] <<<\033[0m\n" "${LAST_DNS_IPS}" "${DNS_IPS}"
    echo ""
  fi
  LAST_DNS_IPS="${DNS_IPS}"

  # Pick an IP from DNS (round-robin through returned IPs)
  IP_ARRAY=(${DNS_IPS})
  IP_COUNT=${#IP_ARRAY[@]}
  IDX=$(( (REQ - 1) % IP_COUNT ))
  TARGET_IP="${IP_ARRAY[${IDX}]}"

  # Label the target
  if [ "${TARGET_IP}" = "${NGINX_IP}" ]; then
    CTRL_LABEL="nginx"
  elif [ "${TARGET_IP}" = "${TRAEFIK_IP}" ]; then
    CTRL_LABEL="traefik"
  else
    CTRL_LABEL="unknown"
  fi

  # ── Hit the app ────────────────────────────────────────────────────────────
  RESP=$(curl -s -o /dev/null \
    -w "%{http_code}|%{time_total}" \
    --connect-timeout 3 \
    --max-time 5 \
    -H "Host: ${HOST}" \
    "http://${TARGET_IP}/" 2>/dev/null || echo "000|0.000")

  CODE=$(echo "${RESP}" | cut -d'|' -f1)
  LAT=$(echo "${RESP}" | cut -d'|' -f2)

  DNS_DISPLAY=$(echo "${DNS_IPS}" | tr ' ' ',')

  if [ "${CODE}" = "200" ]; then
    SUCCESS=$((SUCCESS + 1))
    printf "  \033[32m%-10s │ %s    │ %ss │ %-16s │ %-10s │ [%s]  ✓ %d\033[0m\n" \
      "${TS}" "${CODE}" "${LAT}" "${TARGET_IP}" "${CTRL_LABEL}" "${DNS_DISPLAY}" "${SUCCESS}"
  else
    FAIL=$((FAIL + 1))
    printf "  \033[1;31m%-10s │ %s    │ %ss │ %-16s │ %-10s │ [%s]  ✗ FAIL #%d\033[0m\n" \
      "${TS}" "${CODE}" "${LAT}" "${TARGET_IP}" "${CTRL_LABEL}" "${DNS_DISPLAY}" "${FAIL}"
  fi

  sleep "${INTERVAL}"
done
