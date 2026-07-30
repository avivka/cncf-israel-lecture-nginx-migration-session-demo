#!/usr/bin/env bash
# 01-setup-nginx.sh — Deploy ingress-nginx + sample app + Azure DNS
#
# After this step:
#   - Echo server app is running (2 replicas)
#   - ingress-nginx serves it via 2 Ingress resources
#   - Azure DNS A records point to the NGINX LoadBalancer IP
#   - The app is reachable via: curl http://<NGINX_IP>/ -H "Host: app.demo.cncf-migration.local"
#
# Idempotent: safe to run multiple times

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Configuration ───────────────────────────────────────────────────────────
RESOURCE_GROUP="${RESOURCE_GROUP:-cncf-nginx-migration-demo}"
DNS_ZONE="${DNS_ZONE:-demo.cncf-migration.local}"

echo "=== Step 1: Deploy ingress-nginx + Sample App + DNS ==="
echo ""

# ─── Create demo namespace ───────────────────────────────────────────────────
kubectl create namespace demo --dry-run=client -o yaml | kubectl apply -f -

# ─── Deploy ingress-nginx ────────────────────────────────────────────────────
echo "Deploying ingress-nginx..."
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --values "${SCRIPT_DIR}/values/nginx-values.yaml" \
  --wait

echo "Waiting for ingress-nginx controller pod..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s

# ─── Wait for LoadBalancer IP ────────────────────────────────────────────────
echo "Waiting for ingress-nginx LoadBalancer IP..."
for i in $(seq 1 60); do
  NGINX_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  if [ -n "${NGINX_IP}" ]; then break; fi
  sleep 3
done

if [ -z "${NGINX_IP}" ]; then
  echo "ERROR: Timed out waiting for NGINX LoadBalancer IP"
  exit 1
fi
echo "ingress-nginx LoadBalancer IP: ${NGINX_IP}"

# ─── Deploy sample application ──────────────────────────────────────────────
echo ""
echo "Deploying sample app (echo-server, 2 replicas)..."
kubectl apply -f "${SCRIPT_DIR}/manifests/sample-app.yaml"

echo "Waiting for sample app pods..."
kubectl wait --namespace demo \
  --for=condition=ready pod \
  --selector=app=echo-server \
  --timeout=60s

echo ""
echo "Sample app running:"
kubectl get pods -n demo -l app=echo-server
echo ""

# ─── Create basic auth secret ───────────────────────────────────────────────
# Credentials: demo / demo123
# Generate the apr1 (Apache MD5) hash at runtime so it always matches the
# password — a hardcoded hash drifted from the password before and produced
# 401s even with correct creds. Idempotent via apply.
echo "Creating basic-auth secret (demo / demo123)..."
AUTH_USER="${AUTH_USER:-demo}"
AUTH_PASS="${AUTH_PASS:-demo123}"
AUTH_HASH="$(openssl passwd -apr1 "${AUTH_PASS}")"
kubectl create secret generic basic-auth \
  --namespace demo \
  --from-literal=auth="${AUTH_USER}:${AUTH_HASH}" \
  --dry-run=client -o yaml | kubectl apply -f -

# ─── Deploy Ingress resources ───────────────────────────────────────────────
echo "Deploying Ingress resources..."
kubectl apply -f "${SCRIPT_DIR}/manifests/ingress-nginx-basic.yaml"
kubectl apply -f "${SCRIPT_DIR}/manifests/ingress-nginx-annotated.yaml"
echo ""

echo "Ingress resources:"
kubectl get ingress -n demo
echo ""

# ─── Set up Azure DNS zone + records ────────────────────────────────────────
echo "Setting up Azure DNS zone: ${DNS_ZONE}"
if ! az network dns zone show -g "${RESOURCE_GROUP}" -n "${DNS_ZONE}" &>/dev/null; then
  az network dns zone create -g "${RESOURCE_GROUP}" -n "${DNS_ZONE}" --output none
fi

# Create A records → NGINX, TTL lowered to 30s (canary-ready).
# Order matters: `add-record` creates-or-updates the record-set and resets TTL
# to the 3600s default, so we lower TTL *after* adding the IP, not before.
# The `--set TTL=30` (with a lowercase fallback) covers both az/DNS API model
# casings — newer az exposes the property as `TTL` (PascalCase), older as `ttl`.
for rec in app secure; do
  echo "Creating DNS: ${rec}.${DNS_ZONE} → ${NGINX_IP} (TTL=30s)"
  az network dns record-set a delete \
    -g "${RESOURCE_GROUP}" -z "${DNS_ZONE}" -n "${rec}" --yes 2>/dev/null || true
  az network dns record-set a add-record \
    -g "${RESOURCE_GROUP}" -z "${DNS_ZONE}" -n "${rec}" \
    --ipv4-address "${NGINX_IP}" --output none
  az network dns record-set a update \
    -g "${RESOURCE_GROUP}" -z "${DNS_ZONE}" -n "${rec}" --set TTL=30 --output none 2>/dev/null || \
  az network dns record-set a update \
    -g "${RESOURCE_GROUP}" -z "${DNS_ZONE}" -n "${rec}" --set ttl=30 --output none
done

# ─── Verify the app is reachable ─────────────────────────────────────────────
echo ""
echo "=========================================="
echo "  Verifying app is reachable"
echo "=========================================="
echo ""
echo "  Vanilla app (app.${DNS_ZONE}):"
curl -s -o /dev/null -w "    HTTP %{http_code} (%{time_total}s)\n" \
  -H "Host: app.${DNS_ZONE}" "http://${NGINX_IP}/" || echo "    FAILED"

echo "  Annotated app (secure.${DNS_ZONE}, basic auth):"
curl -s -o /dev/null -w "    HTTP %{http_code} (%{time_total}s)\n" \
  -u demo:demo123 \
  -H "Host: secure.${DNS_ZONE}" "http://${NGINX_IP}/" || echo "    FAILED"

# ─── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "=========================================="
echo "  Setup Complete"
echo "=========================================="
echo ""
echo "  App:     echo-server (2 replicas)"
echo "  NGINX:   ${NGINX_IP}"
echo ""
echo "  DNS endpoints (TTL=30s):"
echo "    app.${DNS_ZONE}    → ${NGINX_IP}"
echo "    secure.${DNS_ZONE} → ${NGINX_IP}"
echo ""
echo "  Test manually:"
echo "    curl -H 'Host: app.${DNS_ZONE}' http://${NGINX_IP}/"
echo "    curl -u demo:demo123 -H 'Host: secure.${DNS_ZONE}' http://${NGINX_IP}/"
echo ""
echo "=========================================="
echo "  START THE LOAD GENERATOR NOW"
echo "=========================================="
echo ""
echo "  Open a SECOND terminal (visible to audience) and run:"
echo ""
echo "    cd ${SCRIPT_DIR}"
echo "    export RESOURCE_GROUP=${RESOURCE_GROUP}"
echo "    ./load-generator.sh"
echo ""
echo "  You should see a wall of green lines hitting the app via NGINX."
echo "  Keep it running for the ENTIRE demo."
echo ""
echo "Next: run ./02-audit.sh"
