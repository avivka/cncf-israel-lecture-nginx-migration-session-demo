#!/usr/bin/env bash
# 05-cleanup.sh — Remove all demo resources
# Idempotent: safe to run multiple times

set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-cncf-nginx-migration-demo}"
CLUSTER_NAME="${CLUSTER_NAME:-nginx-migration-demo}"
DNS_ZONE="${DNS_ZONE:-demo.cncf-migration.local}"

echo "=== Cleanup ==="
echo ""

# ─── Kill port-forward ──────────────────────────────────────────────────────
echo "Stopping dashboard port-forward..."
pkill -f 'port-forward.*traefik.*9000' 2>/dev/null || true

# ─── Remove DNS zone ────────────────────────────────────────────────────────
echo "Removing Azure DNS zone..."
az network dns zone delete -g "${RESOURCE_GROUP}" -n "${DNS_ZONE}" --yes 2>/dev/null || true

# ─── Remove catch-all ────────────────────────────────────────────────────────
echo "Removing Traefik catch-all IngressRoute..."
kubectl delete ingressroute nginx-catchall -n traefik --ignore-not-found

# ─── Remove Ingresses ───────────────────────────────────────────────────────
echo "Removing Ingress resources..."
kubectl delete ingress echo-basic echo-annotated -n demo --ignore-not-found

# ─── Remove sample app ──────────────────────────────────────────────────────
echo "Removing sample application..."
kubectl delete -f "$(dirname "${BASH_SOURCE[0]}")/manifests/sample-app.yaml" --ignore-not-found
kubectl delete secret basic-auth -n demo --ignore-not-found

# ─── Uninstall controllers ──────────────────────────────────────────────────
echo "Uninstalling Traefik..."
helm uninstall traefik -n traefik 2>/dev/null || true
kubectl delete namespace traefik --ignore-not-found

echo "Uninstalling ingress-nginx..."
helm uninstall ingress-nginx -n ingress-nginx 2>/dev/null || true
kubectl delete namespace ingress-nginx --ignore-not-found

echo "Removing demo namespace..."
kubectl delete namespace demo --ignore-not-found

echo ""
echo "=== In-cluster cleanup complete ==="
echo ""

read -rp "Delete the AKS cluster '${CLUSTER_NAME}'? (y/N) " DELETE_CLUSTER
if [[ "${DELETE_CLUSTER}" =~ ^[Yy]$ ]]; then
  echo "Deleting resource group (includes cluster, DNS zone, everything)..."
  az group delete --name "${RESOURCE_GROUP}" --yes --no-wait
  echo "Deletion initiated (runs in background)."
else
  echo "Cluster preserved. Delete manually:"
  echo "  az group delete --name ${RESOURCE_GROUP} --yes"
fi
