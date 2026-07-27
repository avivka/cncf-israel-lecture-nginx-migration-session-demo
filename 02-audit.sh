#!/usr/bin/env bash
# 02-audit.sh — Run the annotation audit to assess migration scope
# This is the "run the audit" step from the presentation

set -euo pipefail

echo "=== Step 2: Annotation Audit ==="
echo ""
echo "──────────────────────────────────────────────────────────────"
echo "1. All NGINX annotations in use (sorted by frequency)"
echo "──────────────────────────────────────────────────────────────"
echo ""

kubectl get ingress -A -o json | \
  jq -r '.items[].metadata.annotations // {} | to_entries[] |
    select(.key | startswith("nginx.ingress.kubernetes.io/")) |
    .key | ltrimstr("nginx.ingress.kubernetes.io/")' | \
  sort | uniq -c | sort -rn

echo ""
echo "──────────────────────────────────────────────────────────────"
echo "2. Snippet usage (S3 tier — most expensive to migrate)"
echo "──────────────────────────────────────────────────────────────"
echo ""

SNIPPETS=$(kubectl get ingress -A -o json | \
  jq -r '.items[] | select(
    .metadata.annotations["nginx.ingress.kubernetes.io/server-snippet"] != null or
    .metadata.annotations["nginx.ingress.kubernetes.io/configuration-snippet"] != null
  ) | .metadata.namespace + "/" + .metadata.name')

if [ -z "${SNIPPETS}" ]; then
  echo "No snippets found. Good news — no S3 tier Ingresses."
else
  echo "Ingresses with snippets:"
  echo "${SNIPPETS}"
fi

echo ""
echo "──────────────────────────────────────────────────────────────"
echo "3. Migration tier categorization (S0 / S1-S2 / S3)"
echo "──────────────────────────────────────────────────────────────"
echo ""

kubectl get ingress -A -o json | \
  jq -r '.items[] | {
    name: (.metadata.namespace + "/" + .metadata.name),
    tier: (
      if (.metadata.annotations["nginx.ingress.kubernetes.io/server-snippet"] != null or
          .metadata.annotations["nginx.ingress.kubernetes.io/configuration-snippet"] != null)
      then "S3-SNIPPETS"
      elif ([.metadata.annotations // {} | to_entries[] |
             select(.key | startswith("nginx.ingress.kubernetes.io/"))] | length) > 0
      then "S1-ANNOTATIONS"
      else "S0-VANILLA"
      end),
    annotation_count: ([.metadata.annotations // {} | to_entries[] |
                        select(.key | startswith("nginx.ingress.kubernetes.io/"))] | length)
  } | "\(.tier) [\(.annotation_count) annotations] \(.name)"' | sort

echo ""
echo "──────────────────────────────────────────────────────────────"
echo "4. Ingresses without explicit IngressClass (danger zone)"
echo "──────────────────────────────────────────────────────────────"
echo ""

NO_CLASS=$(kubectl get ingress -A -o json | \
  jq -r '.items[] | select(.spec.ingressClassName == null) |
    .metadata.namespace + "/" + .metadata.name')

if [ -z "${NO_CLASS}" ]; then
  echo "All Ingresses have explicit ingressClassName. Safe for side-by-side."
else
  echo "WARNING: These Ingresses have no ingressClassName — both controllers may claim them:"
  echo "${NO_CLASS}"
fi

echo ""
echo "=== Audit Complete ==="
echo ""
echo "Summary: Review the tier categorization above."
echo "  S0-VANILLA   = Minutes to migrate (automated)"
echo "  S1-ANNOTATIONS = Hours per annotation type"
echo "  S3-SNIPPETS  = Weeks to months (manual translation)"
echo ""
echo "Next: run ./03-deploy-traefik.sh"
