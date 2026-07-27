#!/usr/bin/env bash
# 04-cutover.sh — DNS CANARY SWITCH: Zero-Downtime Migration
#
# This is the core of the demo. The pattern (from a real customer migration):
#
#   BEFORE (done in 01-setup):
#     - DNS TTL lowered to 30s (in prod, do this days before)
#     - DNS A record → NGINX IP only
#
#   PHASE 1: Deploy catch-all (done in 03-deploy-traefik):
#     - Traefik IngressRoute catches all traffic → forwards to NGINX
#     - Both IPs serve 200 — Traefik via catch-all, NGINX directly
#
#   PHASE 2: DNS CANARY (this script)
#     - Add Traefik IP to DNS → round-robin 50/50
#     - Load generator shows: both IPs green, zero drops
#
#   PHASE 3: COMPLETE CUTOVER (this script)
#     - Remove NGINX IP from DNS → 100% Traefik
#     - Load generator shows: Traefik only, zero drops
#
#   PHASE 4: RAISE TTL (this script)
#     - TTL back to 300s (production value)
#     - NGINX stays running 24-48h for cache drain
#
# The load generator in the second terminal is querying Azure DNS
# on every request — it FOLLOWS the DNS changes in real time.

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
RESOURCE_GROUP="${RESOURCE_GROUP:-cncf-nginx-migration-demo}"
DNS_ZONE="${DNS_ZONE:-demo.cncf-migration.local}"
DNS_RECORD="${DNS_RECORD:-app}"

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

echo ""
echo "  ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
echo "  ┃           DNS CANARY CUTOVER — ZERO DOWNTIME                     ┃"
echo "  ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
echo ""
echo "  NGINX IP:   ${NGINX_IP}"
echo "  Traefik IP: ${TRAEFIK_IP}"
echo "  DNS:        ${DNS_RECORD}.${DNS_ZONE}"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 1: Show current state
# ══════════════════════════════════════════════════════════════════════════════
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  CURRENT STATE"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  DNS points to NGINX only. TTL is 30s (pre-lowered)."
echo "  In production, you lower TTL days before the cutover."
echo ""
echo "  Current DNS:"
az network dns record-set a show \
  -g "${RESOURCE_GROUP}" -z "${DNS_ZONE}" -n "${DNS_RECORD}" \
  --query "{TTL: ttl, IPs: aRecords[].ipv4Address}" -o json 2>/dev/null | \
  python3 -c "
import json,sys
d=json.load(sys.stdin)
print(f'    TTL: {d[\"TTL\"]}s')
for ip in d['IPs']:
    print(f'    A:   {ip}')
" 2>/dev/null || echo "    ${DNS_RECORD} → ${NGINX_IP} (TTL=30)"
echo ""
echo "  The catch-all IngressRoute is already deployed (step 03)."
echo "  Traefik forwards all traffic → NGINX. Both IPs serve 200."
echo ""
echo "  >>> Check the load generator — all green. <<<"
echo ""

read -rp "  Press Enter to start DNS canary (add Traefik IP)..."
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 2: DNS CANARY — Add Traefik IP (50/50 round-robin)
# ══════════════════════════════════════════════════════════════════════════════
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PHASE 2: DNS CANARY — Adding Traefik IP"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Adding ${TRAEFIK_IP} to the A record..."
echo ""

az network dns record-set a add-record \
  -g "${RESOURCE_GROUP}" -z "${DNS_ZONE}" -n "${DNS_RECORD}" \
  --ipv4-address "${TRAEFIK_IP}" --output none

echo "  DNS now has TWO A records (round-robin):"
az network dns record-set a show \
  -g "${RESOURCE_GROUP}" -z "${DNS_ZONE}" -n "${DNS_RECORD}" \
  --query "{TTL: ttl, IPs: aRecords[].ipv4Address}" -o json 2>/dev/null | \
  python3 -c "
import json,sys
d=json.load(sys.stdin)
print(f'    TTL: {d[\"TTL\"]}s')
for ip in d['IPs']:
    print(f'    A:   {ip}')
" 2>/dev/null || echo "    ${NGINX_IP} + ${TRAEFIK_IP}"
echo ""
echo "  Clients now resolve to EITHER IP — 50/50 canary."
echo "  Both return 200:"
echo "    - NGINX handles traffic directly"
echo "    - Traefik handles traffic via catch-all → NGINX → App"
echo ""
echo "  >>> Look at the load generator — DNS CHANGED, still all green. <<<"
echo ""

read -rp "  Press Enter to complete cutover (remove NGINX IP)..."
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 3: COMPLETE CUTOVER — Remove NGINX IP (100% Traefik)
# ══════════════════════════════════════════════════════════════════════════════
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PHASE 3: COMPLETE CUTOVER — Removing NGINX IP"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Removing ${NGINX_IP} from DNS..."
echo ""

az network dns record-set a remove-record \
  -g "${RESOURCE_GROUP}" -z "${DNS_ZONE}" -n "${DNS_RECORD}" \
  --ipv4-address "${NGINX_IP}" --output none

echo "  DNS now points to Traefik ONLY:"
az network dns record-set a show \
  -g "${RESOURCE_GROUP}" -z "${DNS_ZONE}" -n "${DNS_RECORD}" \
  --query "{TTL: ttl, IPs: aRecords[].ipv4Address}" -o json 2>/dev/null | \
  python3 -c "
import json,sys
d=json.load(sys.stdin)
print(f'    TTL: {d[\"TTL\"]}s')
for ip in d['IPs']:
    print(f'    A:   {ip}')
" 2>/dev/null || echo "    ${TRAEFIK_IP} only"
echo ""
echo "  100% of new DNS lookups → Traefik."
echo "  Old cached entries (max 30s) may still hit NGINX — that's fine,"
echo "  NGINX is still running."
echo ""
echo "  >>> Load generator: DNS CHANGED again, STILL all green. <<<"
echo ""

read -rp "  Press Enter to raise TTL back to production..."
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 4: RAISE TTL — Back to production value
# ══════════════════════════════════════════════════════════════════════════════
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PHASE 4: RAISE TTL — Back to production (300s)"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

az network dns record-set a update \
  -g "${RESOURCE_GROUP}" -z "${DNS_ZONE}" -n "${DNS_RECORD}" \
  --set ttl=300 --output none

echo "  Final DNS state:"
az network dns record-set a show \
  -g "${RESOURCE_GROUP}" -z "${DNS_ZONE}" -n "${DNS_RECORD}" \
  --query "{TTL: ttl, IPs: aRecords[].ipv4Address}" -o json 2>/dev/null | \
  python3 -c "
import json,sys
d=json.load(sys.stdin)
print(f'    TTL: {d[\"TTL\"]}s')
for ip in d['IPs']:
    print(f'    A:   {ip}')
" 2>/dev/null || echo "    ${TRAEFIK_IP} (TTL=300)"

echo ""
echo ""
echo "  ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
echo "  ┃                    MIGRATION COMPLETE                            ┃"
echo "  ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
echo ""
echo "  What just happened (zero downtime throughout):"
echo ""
echo "    1. TTL pre-lowered to 30s (done before cutover window)"
echo "    2. Traefik deployed with catch-all → NGINX (safety net)"
echo "    3. DNS canary: added Traefik IP (50/50 round-robin)"
echo "       → Load generator showed ZERO drops"
echo "    4. Removed NGINX IP (100% Traefik)"
echo "       → Load generator showed ZERO drops"
echo "    5. Raised TTL back to 300s"
echo ""
echo "  In production, next steps:"
echo "    - Keep NGINX running 24-48h (DNS cache drain)"
echo "    - Monitor Traefik dashboard for errors"
echo "    - Then: helm uninstall ingress-nginx -n ingress-nginx"
echo ""
