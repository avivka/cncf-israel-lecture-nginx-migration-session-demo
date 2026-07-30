#!/usr/bin/env bash
# 04-cutover.sh — ROUTE-BY-ROUTE DNS CANARY: Zero-Downtime Migration
#
# This is the core of the demo. We migrate ONE ROUTE AT A TIME from NGINX to
# Traefik, purely by changing DNS — gradually, and with zero downtime.
#
# For EACH route (app first, then secure):
#
#   START:   DNS → [NGINX]              (route served by NGINX)
#   CANARY:  DNS → [NGINX, TRAEFIK]     (add Traefik IP → ~50/50 round-robin)
#   CUTOVER: DNS → [TRAEFIK]            (remove NGINX IP → 100% Traefik)
#
# The safety net that makes every step return 200:
#   - Traefik reads the SAME nginx Ingresses natively (kubernetesIngressNGINX)
#   - AND a catch-all IngressRoute forwards anything else Traefik → NGINX → App
#
# The load generator in the second terminal queries Azure DNS for BOTH routes on
# every request. While `app` is migrating, `secure` keeps hitting NGINX untouched
# — proving routes move independently and nothing drops.

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
RESOURCE_GROUP="${RESOURCE_GROUP:-cncf-nginx-migration-demo}"
DNS_ZONE="${DNS_ZONE:-demo.cncf-migration.local}"
# Routes to migrate, in order. Override with e.g. ROUTES="app" for a single route.
ROUTES="${ROUTES:-app secure}"

# ─── Get IPs ─────────────────────────────────────────────────────────────────
NGINX_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
TRAEFIK_IP=$(kubectl get svc traefik -n traefik \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

if [ -z "${NGINX_IP}" ] || [ -z "${TRAEFIK_IP}" ]; then
  echo "ERROR: Both controllers must have LoadBalancer IPs."
  echo "  NGINX IP:   ${NGINX_IP:-<missing>}"
  echo "  Traefik IP: ${TRAEFIK_IP:-<missing>}"
  exit 1
fi

# ─── Helpers ─────────────────────────────────────────────────────────────────
# Print a record's TTL + IPs, handling both az/DNS API casings (ARecords/TTL vs
# aRecords/ttl).
show_dns () {
  local rec="$1"
  az network dns record-set a show \
    -g "${RESOURCE_GROUP}" -z "${DNS_ZONE}" -n "${rec}" \
    --query "{TTL: TTL || ttl, IPs: ARecords[].ipv4Address || aRecords[].ipv4Address}" \
    -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(f'      TTL: {d[\"TTL\"]}s')
for ip in (d['IPs'] or []):
    print(f'      A:   {ip}')
" 2>/dev/null || echo "      ${rec} (unavailable)"
}

# Migrate a single route: canary (add Traefik) then cutover (remove NGINX).
migrate_route () {
  local rec="$1"
  echo ""
  echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  ROUTE: ${rec}.${DNS_ZONE}"
  echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "  Current DNS (NGINX only):"
  show_dns "${rec}"
  echo ""
  echo "  >>> Load generator: '${rec}' is all green via NGINX. <<<"
  echo ""
  read -rp "  Press Enter to CANARY '${rec}' (add Traefik IP → 50/50)..."
  echo ""

  # ── CANARY: add Traefik IP ────────────────────────────────────────────────
  az network dns record-set a add-record \
    -g "${RESOURCE_GROUP}" -z "${DNS_ZONE}" -n "${rec}" \
    --ipv4-address "${TRAEFIK_IP}" --output none
  echo "  Canary live — '${rec}' now resolves to BOTH IPs (round-robin):"
  show_dns "${rec}"
  echo ""
  echo "  Both return 200: NGINX directly, Traefik natively (+ catch-all)."
  echo "  >>> Load generator: '${rec}' DNS CHANGED, still all green. <<<"
  echo ""
  read -rp "  Press Enter to CUT OVER '${rec}' (remove NGINX IP → 100% Traefik)..."
  echo ""

  # ── CUTOVER: remove NGINX IP ──────────────────────────────────────────────
  az network dns record-set a remove-record \
    -g "${RESOURCE_GROUP}" -z "${DNS_ZONE}" -n "${rec}" \
    --ipv4-address "${NGINX_IP}" --output none
  echo "  '${rec}' now points to Traefik ONLY:"
  show_dns "${rec}"
  echo ""
  echo "  >>> Load generator: '${rec}' DNS CHANGED again, STILL all green. <<<"
  echo "  '${rec}' is migrated. (Any other route is untouched — see the load gen.)"
  echo ""
}

# ─── Banner ──────────────────────────────────────────────────────────────────
echo ""
echo "  ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
echo "  ┃      ROUTE-BY-ROUTE DNS CANARY CUTOVER — ZERO DOWNTIME           ┃"
echo "  ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
echo ""
echo "  NGINX IP:   ${NGINX_IP}"
echo "  Traefik IP: ${TRAEFIK_IP}"
echo "  Routes:     ${ROUTES}   (migrated one at a time)"
echo ""
echo "  DNS TTL is already 30s (pre-lowered in step 01 — in prod, do this days"
echo "  ahead). The catch-all + native provider mean every path serves 200."
echo ""

# ─── Migrate each route independently ────────────────────────────────────────
for rec in ${ROUTES}; do
  migrate_route "${rec}"
done

# ─── Raise TTL back to production on all migrated routes ──────────────────────
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  FINALIZE: raise TTL back to production (300s)"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
read -rp "  Press Enter to raise TTL to 300s on all routes..."
echo ""
for rec in ${ROUTES}; do
  # PascalCase first (newer az/DNS model), fall back to lowercase.
  az network dns record-set a update \
    -g "${RESOURCE_GROUP}" -z "${DNS_ZONE}" -n "${rec}" --set TTL=300 --output none 2>/dev/null || \
  az network dns record-set a update \
    -g "${RESOURCE_GROUP}" -z "${DNS_ZONE}" -n "${rec}" --set ttl=300 --output none
  echo "  ${rec}.${DNS_ZONE}:"
  show_dns "${rec}"
done

echo ""
echo "  ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
echo "  ┃                    MIGRATION COMPLETE                            ┃"
echo "  ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
echo ""
echo "  What just happened — one route at a time, zero downtime throughout:"
echo ""
echo "    For each route:  [NGINX] → [NGINX, TRAEFIK] → [TRAEFIK]"
echo "      • Canary added Traefik IP (50/50)   → load gen: zero drops"
echo "      • Cutover removed NGINX IP (100%)   → load gen: zero drops"
echo "      • The OTHER route stayed on NGINX until its own turn"
echo "    Finally raised TTL back to 300s."
echo ""
echo "  In production, next steps:"
echo "    - Keep NGINX running 24-48h (DNS cache drain)"
echo "    - Watch the Traefik dashboard for errors"
echo "    - Then: helm uninstall ingress-nginx -n ingress-nginx"
echo ""
