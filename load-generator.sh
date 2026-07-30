#!/usr/bin/env bash
# load-generator.sh — LIVE TRAFFIC THAT FOLLOWS DNS CHANGES (route by route)
#
# This is the zero-downtime proof. On every cycle it reads the CURRENT Azure DNS
# A-records for BOTH demo routes and hits each one:
#
#   app.<zone>     — vanilla route (S0), no auth
#   secure.<zone>  — annotated route (S1), HTTP basic auth (demo/demo123)
#
# Because both routes are watched independently, you can migrate them ONE AT A
# TIME: while `app` is being canaried/cut over to Traefik, `secure` keeps hitting
# NGINX — and neither route ever drops a request.
#
# Run this in a SECOND TERMINAL visible to the audience.
#
# Usage:
#   ./load-generator.sh                  # uses defaults
#   ./load-generator.sh <RESOURCE_GROUP> # custom RG

set -uo pipefail

RG="${1:-${RESOURCE_GROUP:-cncf-nginx-migration-demo}}"
DNS_ZONE="${DNS_ZONE:-demo.cncf-migration.local}"
INTERVAL="${INTERVAL:-0.5}"

# Routes to exercise: "record|host|curl-extra-args"
ROUTES=(
  "app|app.${DNS_ZONE}|"
  "secure|secure.${DNS_ZONE}|-u demo:demo123"
)

clear
echo ""
echo "  ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
echo "  ┃         LIVE TRAFFIC — ZERO DOWNTIME PROOF (route by route)      ┃"
echo "  ┃                                                                  ┃"
echo "  ┃  Reads Azure DNS for EACH route every cycle and hits it.         ┃"
echo "  ┃  Migrate one route at a time — the other never notices.          ┃"
echo "  ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
echo ""
echo "  Zone:      ${DNS_ZONE}"
echo "  Routes:    app (no auth), secure (basic auth)"
echo "  Interval:  ${INTERVAL}s"
echo "  Started:   $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# ─── Detect controller IPs for labeling ──────────────────────────────────────
NGINX_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
TRAEFIK_IP=$(kubectl get svc traefik -n traefik \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
echo "  Known IPs:"
[ -n "${NGINX_IP}" ]   && echo "    NGINX:   ${NGINX_IP}"
[ -n "${TRAEFIK_IP}" ] && echo "    Traefik: ${TRAEFIK_IP}"
echo ""
echo "  ─────────────────────────────────────────────────────────────────────"
printf "  %-8s │ %-7s │ %-6s │ %-7s │ %-10s │ %s\n" \
  "TIME" "ROUTE" "STATUS" "LATENCY" "CONTROLLER" "DNS IPs"
echo "  ─────────────────────────────────────────────────────────────────────"

SUCCESS=0
FAIL=0
REQ=0
# Per-route "last seen DNS" is tracked in indirect scalars (LAST_DNS_app, …)
# rather than an associative array — macOS ships bash 3.2, which has neither
# `declare -A` nor associative arrays.

label_ip () { # $1 = ip
  if   [ "$1" = "${NGINX_IP}" ];   then echo "nginx"
  elif [ "$1" = "${TRAEFIK_IP}" ]; then echo "traefik"
  else echo "unknown"; fi
}

while true; do
  REQ=$((REQ + 1))
  TS=$(date '+%H:%M:%S')

  # ── One DNS call per cycle for ALL records, parsed case-insensitively ──────
  # Newer az returns ARecords/TTL (PascalCase), older aRecords/ttl — handle both.
  DNS_JSON=$(az network dns record-set a list -g "${RG}" -z "${DNS_ZONE}" -o json 2>/dev/null || echo "[]")

  for entry in "${ROUTES[@]}"; do
    IFS='|' read -r REC HOST EXTRA <<< "${entry}"

    DNS_IPS=$(printf '%s' "${DNS_JSON}" | python3 -c "
import json,sys
try: data=json.load(sys.stdin)
except Exception: data=[]
rec=sys.argv[1]
for rs in data:
    if rs.get('name')==rec:
        arecs=rs.get('ARecords') or rs.get('aRecords') or []
        print(' '.join(a.get('ipv4Address','') for a in arecs))
        break
" "${REC}" 2>/dev/null | xargs)

    # Detect and announce DNS changes per route (indirect scalar per route)
    last_var="LAST_DNS_${REC}"
    eval "prev=\${${last_var}:-}"
    if [ -n "${DNS_IPS}" ] && [ "${DNS_IPS}" != "${prev}" ] && [ -n "${prev}" ]; then
      echo ""
      printf "  \033[1;36m  >>> [%s] DNS CHANGED: [%s] → [%s] <<<\033[0m\n" \
        "${REC}" "${prev}" "${DNS_IPS}"
      echo ""
    fi
    eval "${last_var}=\"\${DNS_IPS}\""

    if [ -z "${DNS_IPS}" ]; then
      printf "  \033[33m%-8s │ %-7s │ ---    │ ---     │ %-10s │ DNS EMPTY\033[0m\n" \
        "${TS}" "${REC}" "---"
      continue
    fi

    # Round-robin across whatever IPs DNS currently returns
    IP_ARRAY=(${DNS_IPS})
    TARGET_IP="${IP_ARRAY[$(( (REQ - 1) % ${#IP_ARRAY[@]} ))]}"

    RESP=$(curl -s -o /dev/null -w "%{http_code}|%{time_total}" \
      --connect-timeout 3 --max-time 5 ${EXTRA} \
      -H "Host: ${HOST}" "http://${TARGET_IP}/" 2>/dev/null || echo "000|0.000")
    CODE="${RESP%%|*}"; LAT="${RESP##*|}"
    CTRL=$(label_ip "${TARGET_IP}")
    DNS_DISPLAY=$(echo "${DNS_IPS}" | tr ' ' ',')

    if [ "${CODE}" = "200" ]; then
      SUCCESS=$((SUCCESS + 1))
      printf "  \033[32m%-8s │ %-7s │ %s    │ %ss │ %-10s │ [%s] ✓%d\033[0m\n" \
        "${TS}" "${REC}" "${CODE}" "${LAT}" "${CTRL}" "${DNS_DISPLAY}" "${SUCCESS}"
    else
      FAIL=$((FAIL + 1))
      printf "  \033[1;31m%-8s │ %-7s │ %s    │ %ss │ %-10s │ [%s] ✗ FAIL #%d\033[0m\n" \
        "${TS}" "${REC}" "${CODE}" "${LAT}" "${CTRL}" "${DNS_DISPLAY}" "${FAIL}"
    fi
  done

  sleep "${INTERVAL}"
done
