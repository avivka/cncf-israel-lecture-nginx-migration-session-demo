# ingress-nginx to Traefik Migration Demo

Live demo for the CNCF Israel talk: **Life After ingress-nginx: Architecting the Exit**

## What This Demo Proves

Zero-downtime migration from ingress-nginx to Traefik using a DNS canary switch — the same pattern used in a real customer migration.

A load generator queries Azure DNS on every request. When DNS changes during the cutover, the load generator follows — and never drops a request.

## Prerequisites

- Azure CLI (`az`) authenticated (`az login`)
- `kubectl`, `helm` v3.x, `jq`, `curl`, `python3`
- An Azure subscription with permissions to create AKS clusters and DNS zones

## Demo Flow (2 Terminals)

### Terminal 1 — You drive

```bash
cd demo
export RESOURCE_GROUP=cncf-nginx-migration-demo
```

| Step | Script | What happens |
|------|--------|-------------|
| 0 | `./00-prerequisites.sh` | Creates AKS cluster (canadacentral, k8s 1.35), adds Helm repos. **Pre-run this — takes a few minutes.** |
| 1 | `./01-setup-nginx.sh` | Deploys ingress-nginx, sample app (echo-server, 2 replicas), basic-auth secret, 2 Ingress resources (vanilla S0 + annotated S1), Azure DNS zone with A record → NGINX IP (TTL=30s). **After this, start the load generator in Terminal 2.** |
| 2 | `./02-audit.sh` | Runs annotation audit: lists all NGINX annotations by frequency, detects snippets, categorizes Ingresses by migration tier (S0/S1/S3), flags Ingresses without explicit IngressClass. |
| 3 | `./03-deploy-traefik.sh` | Deploys Traefik v3 with `kubernetesIngressNGINX` provider, deploys catch-all IngressRoute (Traefik → NGINX forwarding), verifies both IPs serve 200, opens Traefik dashboard in browser (`http://localhost:9000/dashboard/`). |
| 4 | `./04-cutover.sh` | **The DNS canary switch (interactive, press Enter between phases):** |
| | | Phase 1: Show current state (DNS → NGINX only, TTL=30s) |
| | | Phase 2: Add Traefik IP to DNS (50/50 round-robin canary) |
| | | Phase 3: Remove NGINX IP from DNS (100% Traefik) |
| | | Phase 4: Raise TTL back to 300s |
| 5 | `./05-cleanup.sh` | Removes everything. Optionally deletes the AKS cluster. |

### Terminal 2 — Visible to audience (keep running the entire demo)

```bash
cd demo
export RESOURCE_GROUP=cncf-nginx-migration-demo
./load-generator.sh
```

This is the zero-downtime proof:
- Queries Azure DNS for the A record on every request
- Hits whatever IPs DNS returns (round-robins if multiple)
- Green `✓` for every 200, red `✗` for any failure
- Prints `>>> DNS CHANGED <<<` when it detects DNS record changes
- Shows which IP it hit (NGINX vs Traefik) and the current DNS state

### Browser — Traefik Dashboard

Opens automatically in step 03: `http://localhost:9000/dashboard/`

Shows routers, services, and middlewares — the audience can see Traefik picking up the NGINX-annotated Ingress resources.

## What Gets Deployed

### Sample App
- **echo-server** (2 replicas) — echoes request details (headers, path, method)
- **Service** (ClusterIP) — internal access for ingress controllers

### Ingress Resources
- **echo-basic** — vanilla Ingress (S0 tier): just host/path/service, no annotations
- **echo-annotated** — annotated Ingress (S1 tier): `ssl-redirect`, `auth-type: basic`, `auth-secret`, `proxy-body-size`, `proxy-read-timeout`, `proxy-send-timeout`

### Controllers
- **ingress-nginx** — Helm install with LoadBalancer service
- **Traefik v3** — Helm install with `kubernetesIngressNGINX` provider, catch-all IngressRoute, dashboard enabled

### Azure Resources
- **AKS cluster** — 2 nodes, k8s 1.35, canadacentral
- **DNS zone** — `demo.cncf-migration.local` with A record for the canary switch

## The DNS Canary Pattern

This is how zero-downtime DNS migration works:

```
BEFORE:   DNS → [NGINX IP]              TTL=30s
          App ← NGINX ← User

STEP 3:   Deploy Traefik + catch-all
          DNS → [NGINX IP]              (unchanged)
          App ← NGINX ← User           (unchanged)
          App ← NGINX ← Traefik        (catch-all ready, not in DNS yet)

PHASE 2:  DNS → [NGINX IP, TRAEFIK IP]  50/50 canary
          App ← NGINX ← User           (half of requests)
          App ← NGINX ← Traefik ← User (other half, via catch-all)
          Zero drops — both paths serve 200.

PHASE 3:  DNS → [TRAEFIK IP]            100% Traefik
          App ← NGINX ← Traefik ← User (all traffic)
          Zero drops — catch-all still forwards to NGINX.

AFTER:    Keep NGINX 24-48h, then remove.
          Traefik now serves everything directly via NGINX annotation provider.
```

## File Structure

```
demo/
├── README.md                          # This file
├── 00-prerequisites.sh                # AKS cluster setup
├── 01-setup-nginx.sh                  # ingress-nginx + sample app + DNS
├── 02-audit.sh                        # Annotation audit
├── 03-deploy-traefik.sh               # Traefik + catch-all + dashboard
├── 04-cutover.sh                      # DNS canary switch (the migration)
├── 05-cleanup.sh                      # Remove everything
├── load-generator.sh                  # Zero-downtime proof (run in Terminal 2)
├── manifests/
│   ├── sample-app.yaml                # Echo server deployment + service
│   ├── ingress-nginx-basic.yaml       # Vanilla Ingress (S0)
│   ├── ingress-nginx-annotated.yaml   # Annotated Ingress (S1)
│   ├── traefik-catchall.yaml          # Catch-all IngressRoute
│   └── gateway-api-route.yaml         # Optional: HTTPRoute + Gateway
└── values/
    ├── nginx-values.yaml              # Helm values for ingress-nginx
    └── traefik-values.yaml            # Helm values for Traefik
```
