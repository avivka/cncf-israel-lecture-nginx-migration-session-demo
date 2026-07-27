#!/usr/bin/env bash
# 00-prerequisites.sh — Set up AKS cluster and install tools
# Idempotent: safe to run multiple times

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
RESOURCE_GROUP="${RESOURCE_GROUP:-cncf-nginx-migration-demo}"
CLUSTER_NAME="${CLUSTER_NAME:-nginx-migration-demo}"
LOCATION="${LOCATION:-canadacentral}"
NODE_COUNT="${NODE_COUNT:-2}"
K8S_VERSION="${K8S_VERSION:-1.35}"

echo "=== Prerequisites: AKS Cluster Setup ==="
echo "Resource Group: ${RESOURCE_GROUP}"
echo "Cluster: ${CLUSTER_NAME}"
echo "Location: ${LOCATION}"
echo ""

# ─── Check required tools ────────────────────────────────────────────────────
for tool in az kubectl helm jq curl; do
  if ! command -v "${tool}" &>/dev/null; then
    echo "ERROR: '${tool}' is not installed. Please install it first."
    exit 1
  fi
done
echo "All required tools found."

# ─── Create Resource Group ───────────────────────────────────────────────────
if az group show --name "${RESOURCE_GROUP}" &>/dev/null; then
  echo "Resource group '${RESOURCE_GROUP}' already exists."
else
  echo "Creating resource group '${RESOURCE_GROUP}' in ${LOCATION}..."
  az group create --name "${RESOURCE_GROUP}" --location "${LOCATION}" --output none
fi

# ─── Create AKS Cluster ─────────────────────────────────────────────────────
if az aks show --resource-group "${RESOURCE_GROUP}" --name "${CLUSTER_NAME}" &>/dev/null; then
  echo "AKS cluster '${CLUSTER_NAME}' already exists."
else
  echo "Creating AKS cluster '${CLUSTER_NAME}' (${NODE_COUNT} nodes, k8s ${K8S_VERSION})..."
  az aks create \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${CLUSTER_NAME}" \
    --node-count "${NODE_COUNT}" \
    --kubernetes-version "${K8S_VERSION}" \
    --generate-ssh-keys \
    --network-plugin azure \
    --output none
fi

# ─── Get credentials ────────────────────────────────────────────────────────
echo "Getting AKS credentials..."
az aks get-credentials \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${CLUSTER_NAME}" \
  --overwrite-existing

# ─── Verify connectivity ────────────────────────────────────────────────────
echo ""
echo "Verifying cluster connectivity..."
kubectl cluster-info
echo ""
kubectl get nodes
echo ""

# ─── Add Helm repos ─────────────────────────────────────────────────────────
echo "Adding Helm repositories..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo add traefik https://traefik.github.io/charts 2>/dev/null || true
helm repo update

echo ""
echo "=== Prerequisites complete ==="
echo ""
echo "Environment variables for this demo session:"
echo "  export RESOURCE_GROUP=${RESOURCE_GROUP}"
echo "  export DNS_ZONE=demo.cncf-migration.local"
echo "  export DNS_RECORD=app"
echo ""
echo "Next: run ./01-setup-nginx.sh"
