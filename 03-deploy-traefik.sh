#!/usr/bin/env bash
# 03-deploy-traefik.sh — Deploy Traefik side-by-side + open dashboard
# After this: both controllers run, Traefik dashboard is accessible
# Idempotent: safe to run multiple times

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DNS_ZONE="${DNS_ZONE:-demo.cncf-migration.local}"

echo "=== Step 3: Deploy Traefik Side-by-Side ==="
echo ""

# ─── Deploy Traefik ──────────────────────────────────────────────────────────
echo "Deploying Traefik v3 with kubernetesIngressNGINX provider enabled..."
helm upgrade --install traefik traefik/traefik \
  --namespace traefik \
  --create-namespace \
  --values "${SCRIPT_DIR}/values/traefik-values.yaml" \
  --wait

echo "Waiting for Traefik pods..."
kubectl wait --namespace traefik \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/name=traefik \
  --timeout=120s

# ─── Wait for Traefik LoadBalancer IP ────────────────────────────────────────
echo "Waiting for Traefik LoadBalancer IP..."
for i in $(seq 1 60); do
  TRAEFIK_IP=$(kubectl get svc traefik -n traefik \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  if [ -n "${TRAEFIK_IP}" ]; then break; fi
  sleep 3
done

NGINX_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "<pending>")

# ─── Deploy catch-all IngressRoute ───────────────────────────────────────────
echo ""
echo "Deploying catch-all IngressRoute (Traefik → NGINX forwarding)..."
kubectl apply -f "${SCRIPT_DIR}/manifests/traefik-catchall.yaml"
echo "Traffic flow now available: User → Traefik → NGINX → App"

# ─── Show both controllers ──────────────────────────────────────────────────
echo ""
echo "=========================================="
echo " Both controllers running side-by-side"
echo "=========================================="
echo ""
echo "ingress-nginx:"
kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller -o wide
echo ""
echo "Traefik:"
kubectl get pods -n traefik -l app.kubernetes.io/name=traefik -o wide
echo ""
echo "IngressClasses:"
kubectl get ingressclass
echo ""
echo "=========================================="
echo " IPs"
echo "=========================================="
echo ""
echo "  ingress-nginx: ${NGINX_IP}"
echo "  Traefik:       ${TRAEFIK_IP:-<pending>}"
echo ""

# ─── Verify traffic through Traefik (via catch-all → NGINX) ─────────────────
if [ -n "${TRAEFIK_IP}" ]; then
  echo "=========================================="
  echo " Verify: traffic through Traefik works"
  echo "=========================================="
  echo ""
  echo "  Direct via NGINX (app.${DNS_ZONE}):"
  curl -s -o /dev/null -w "    HTTP %{http_code} (%{time_total}s)\n" \
    -H "Host: app.${DNS_ZONE}" "http://${NGINX_IP}/" || echo "    FAILED"
  echo ""
  echo "  Via Traefik catch-all → NGINX (app.${DNS_ZONE}):"
  curl -s -o /dev/null -w "    HTTP %{http_code} (%{time_total}s)\n" \
    -H "Host: app.${DNS_ZONE}" "http://${TRAEFIK_IP}/" || echo "    FAILED"
  echo ""
  echo "  Annotated app via Traefik (secure.${DNS_ZONE}, basic auth):"
  curl -s -o /dev/null -w "    HTTP %{http_code} (%{time_total}s)\n" \
    -u demo:demo123 \
    -H "Host: secure.${DNS_ZONE}" "http://${TRAEFIK_IP}/" || echo "    FAILED"
  echo ""
fi

# ─── Open Traefik Dashboard ─────────────────────────────────────────────────
echo "=========================================="
echo " Traefik Dashboard"
echo "=========================================="
echo ""
echo "Starting port-forward to Traefik dashboard..."
echo "  Dashboard URL: http://localhost:9000/dashboard/"
echo ""
echo "  (Running in background — kill with: pkill -f 'port-forward.*traefik.*9000')"
echo ""

# Kill existing port-forward if any
pkill -f 'port-forward.*traefik.*9000' 2>/dev/null || true
sleep 1

kubectl port-forward -n traefik svc/traefik 9000:9000 &>/dev/null &
DASHBOARD_PID=$!
echo "  Dashboard port-forward PID: ${DASHBOARD_PID}"
sleep 2

# Try to open in browser
if command -v open &>/dev/null; then
  open "http://localhost:9000/dashboard/"
elif command -v xdg-open &>/dev/null; then
  xdg-open "http://localhost:9000/dashboard/"
fi

echo ""
echo "=========================================="
echo " Load generator is still running"
echo "=========================================="
echo ""
echo " It's still hitting NGINX via DNS — all green."
echo " When we run the DNS canary, it will detect the DNS change"
echo " automatically and start hitting Traefik too."
echo ""
echo " Traefik's catch-all forwards to NGINX — so BOTH IPs return 200."
echo " That's the safety net that enables zero-downtime DNS switch."
echo ""
echo "=========================================="
echo " Ready for DNS canary cutover"
echo "=========================================="
echo ""
echo "Next: run ./04-cutover.sh"
