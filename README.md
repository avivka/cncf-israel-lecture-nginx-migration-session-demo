# Life After ingress-nginx: Architecting the Exit

A live, **zero-downtime** migration from **ingress-nginx** to **Traefik**, driven
by a **canary DNS switch** — the same pattern used in a real customer migration.

> Companion demo for the CNCF Israel talk
> **"Life After ingress-nginx: Architecting the Exit."**

---

## Why this exists

The Kubernetes-maintained **[ingress-nginx](https://github.com/kubernetes/ingress-nginx)**
controller is winding down. Maintenance is being scaled back and the project has
steered users toward the **Gateway API** and other controllers for the future.
If you run it in production — and a very large share of clusters do — you now own
a migration decision: **what do you move to, and how do you get there without an
outage or a big-bang rewrite of every annotation?**

This demo answers the *how* with a strategy that is:

- **Safe** — both controllers run side by side; you can stop or roll back at any
  step.
- **Testable** — every phase is observable, and a live load generator proves not
  a single request is dropped.
- **Incremental** — traffic shifts gradually (a canary), not all at once.
- **Low-rewrite** — Traefik reads your **existing** `nginx.ingress.kubernetes.io/*`
  annotations natively, so most Ingresses move as-is.

---

## The core idea

Two mechanisms combine to make the switch invisible to users:

1. **Traefik's `kubernetesIngressNGINX` provider** — Traefik watches the *same*
   `nginx` IngressClass and translates NGINX annotations (basic auth, body size,
   timeouts, ssl-redirect, …) into native Traefik routers and middlewares. Your
   Ingress YAML doesn't change.

2. **A catch-all IngressRoute as a safety net** — Traefik forwards anything it
   hasn't (yet) taken over straight to the ingress-nginx Service. So during the
   overlap window **both** entry points return `200` for **every** route:

   ```
   User → NGINX            → App     (the old path)
   User → Traefik          → App     (routes Traefik already serves natively)
   User → Traefik → NGINX  → App     (anything not migrated yet, via catch-all)
   ```

Because every path is healthy, you can move traffic between them purely at the
**DNS** layer — no in-cluster traffic surgery, no downtime.

---

## What the demo proves

A load generator queries **Azure DNS on every request**, hits whatever IP(s) the
A-record returns, and prints a green `✓` for each `200`. As you flip DNS during
the cutover, the load generator **follows the DNS change in real time** and keeps
scrolling green — visibly proving zero dropped requests.

Verified end-to-end run during development: **0 failures, 0 empty-DNS reads, both
canary transitions detected, traffic served by both controllers.**

---

## Prerequisites

- **Azure CLI** (`az`) authenticated: `az login`
- `kubectl`, `helm` v3.x, `jq`, `curl`, `python3`, `openssl`
- An Azure subscription allowed to create **AKS clusters** and **DNS zones**

**Verified against:** AKS Kubernetes **1.35**, Traefik chart **41.x** (Traefik
**v3.7**), Gateway API CRDs **v1.2.0**, ingress-nginx (latest chart). Region and
names are configurable via env vars (`RESOURCE_GROUP`, `LOCATION`, `CLUSTER_NAME`,
`K8S_VERSION`, `DNS_ZONE`).

---

## Demo flow (2 terminals + a browser)

### Terminal 1 — you drive

```bash
export RESOURCE_GROUP=cncf-nginx-migration-demo
```

| Step | Script | What happens |
|------|--------|-------------|
| 0 | `./00-prerequisites.sh` | Creates the AKS cluster, adds Helm repos, installs **Gateway API CRDs**. **Pre-run this — it takes a few minutes.** Idempotent. |
| 1 | `./01-setup-nginx.sh` | Deploys ingress-nginx, the sample app (echo-server ×2), a basic-auth secret, two Ingresses (vanilla **S0** + annotated **S1**), and an Azure DNS zone with A-records → NGINX IP at **TTL 30s**. **Then start the load generator in Terminal 2.** |
| 2 | `./02-audit.sh` | The annotation audit: every NGINX annotation by frequency, snippet detection, per-Ingress migration **tier** (S0/S1/S3), and Ingresses missing an explicit IngressClass. |
| 3 | `./03-deploy-traefik.sh` | Deploys **Traefik v3** with the `kubernetesIngressNGINX` provider, applies the **catch-all** IngressRoute, verifies both IPs serve `200`, and opens the **dashboard**. |
| 4 | `./04-cutover.sh` | **The route-by-route DNS canary switch** (interactive — press Enter between phases). |
| 5 | `./05-cleanup.sh` | Removes everything; optionally deletes the AKS cluster. |

The cutover (step 4) migrates **one route at a time** — `app` first, then `secure`.
Each route goes through the same gradual, two-move canary:

| Move | DNS A-record for *that* route | Effect |
|------|-------------------------------|--------|
| **Canary** | `[NGINX, TRAEFIK]` | Add Traefik IP → clients resolve ~50/50. Both serve `200`. |
| **Cutover** | `[TRAEFIK]` | Remove NGINX IP → 100% Traefik for this route. |

The **other route stays entirely on NGINX** until its own turn — you can watch
this live in the load generator. After all routes are moved, TTL is raised back
to 300s. Keep NGINX running 24–48h (cache drain), then `helm uninstall`.

> Migrate a single route only: `ROUTES="app" ./04-cutover.sh`. The order and set
> of routes are controlled by the `ROUTES` env var (default: `app secure`).

### Terminal 2 — audience-facing (keep running the whole time)

```bash
export RESOURCE_GROUP=cncf-nginx-migration-demo
./load-generator.sh
```

- Watches **both** routes every cycle — `app` (no auth) and `secure` (basic auth)
- Reads each route's Azure DNS A-record live and hits whatever IP(s) it returns
  (round-robins across multiple)
- Green `✓` per `200`, red `✗` per failure, running success/fail counters
- Prints `>>> [route] DNS CHANGED <<<` the instant a route's record changes
- Labels each hit as **nginx** or **traefik**, so you can watch one route move to
  Traefik while the other stays on NGINX — neither ever drops a request

### Browser — Traefik dashboard

Opens automatically in step 03 at `http://localhost:9000/dashboard/`. To
(re)start the port-forward manually:

```bash
kubectl port-forward -n traefik deploy/traefik 9000:9000
# then open http://localhost:9000/dashboard/
```

> Port-forward the **deployment**, not the Service — the dashboard lives on the
> internal `traefik` entrypoint (container port `9000`), which is intentionally
> **not** exposed on the LoadBalancer.

You'll see routers named `…@kubernetesingressnginx` — Traefik reading the
existing NGINX Ingresses natively — including the **basic-auth middleware**
translated straight from the `nginx.ingress.kubernetes.io/auth-*` annotations.

---

## Migration tiers (from the audit)

The audit (`02-audit.sh`) buckets every Ingress by how hard it is to move:

| Tier | What it is | Effort |
|------|------------|--------|
| **S0 — vanilla** | Host/path/service, no NGINX annotations | Minutes — moves automatically |
| **S1 — annotations** | Common annotations (auth, timeouts, body-size, ssl-redirect) | Hours — translated by the NGINX provider |
| **S3 — snippets** | `server-snippet` / `configuration-snippet` (raw NGINX config) | Weeks–months — manual translation, no automatic path |

The demo ships one of each of S0 (`echo-basic`) and S1 (`echo-annotated`) so you
can watch both move. **Snippets are the real cost of a migration** — the audit is
how you size that up front.

---

## The DNS canary pattern (at a glance)

```
BEFORE:   DNS → [NGINX]                TTL=30s
          User → NGINX → App

STEP 3:   Deploy Traefik + catch-all   (DNS unchanged)
          User → NGINX → App                       (unchanged)
          User → Traefik → App                     (routes served natively)
          User → Traefik → NGINX → App             (catch-all safety net)

PHASE 2:  DNS → [NGINX, TRAEFIK]        50/50 canary
          Half via NGINX, half via Traefik — both 200, zero drops.

PHASE 3:  DNS → [TRAEFIK]              100% Traefik
          Old cached lookups (≤30s) may still hit NGINX — fine, it's still up.

AFTER:    Keep NGINX 24–48h (cache drain), then: helm uninstall ingress-nginx
```

---

## What gets deployed

**Sample app** — `echo-server` (2 replicas, ClusterIP Service) that echoes
request details, so you can see which controller served each request.

**Ingresses** — `echo-basic` (S0, `app.demo.cncf-migration.local`) and
`echo-annotated` (S1, `secure.demo.cncf-migration.local`, basic auth + proxy
tuning).

**Controllers** — ingress-nginx and Traefik v3, side by side, each with its own
LoadBalancer IP and IngressClass (`nginx` and `traefik`).

**Azure** — an AKS cluster and a DNS zone (`demo.cncf-migration.local`) whose
A-records are the lever the whole cutover pulls.

---

## Troubleshooting (real gotchas, already handled)

These are baked into the scripts/values; documented here because they bite anyone
doing this on AKS:

- **NGINX public IP times out on AKS.** The default Azure LB health probe hits
  `/`, but nginx returns **404** for `/` (no host match), so Azure marks the
  backend unhealthy and blackholes the IP. Fix: annotate the controller Service
  with `service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path:
  /healthz` (in `values/nginx-values.yaml`).
- **Traefik dashboard port-forward fails.** The dashboard is on the internal
  `traefik` entrypoint (`9000`), which isn't a Service port. Port-forward
  `deploy/traefik`, not `svc/traefik`.
- **Load generator shows "DNS EMPTY".** Newer `az` returns DNS fields as
  `ARecords`/`TTL` (PascalCase); older as `aRecords`/`ttl`. Queries use a
  `ARecords[...] || aRecords[...]` fallback to work on both.
- **DNS TTL won't lower to 30s.** `az network dns record-set a add-record` resets
  TTL to the 3600s default, so TTL is lowered **after** adding the record, and
  `--set TTL=…` falls back to `--set ttl=…` across az versions.
- **Traefik won't install / schema errors.** Traefik chart 41.x (v3.7) uses
  `log:`/`accessLog:` (not `logs:`) and has **no** `api.insecure`; the dashboard
  is served via a secure `ingressRoute.dashboard`. Gateway API CRDs must be
  installed before enabling the Gateway provider (done in step 0).

---

## File structure

```
.
├── README.md                          # This file
├── LICENSE.md                         # All rights reserved — read before reusing
├── 00-prerequisites.sh                # AKS cluster + Helm repos + Gateway API CRDs
├── 01-setup-nginx.sh                  # ingress-nginx + sample app + DNS (TTL 30)
├── 02-audit.sh                        # Annotation audit + migration tiers
├── 03-deploy-traefik.sh               # Traefik + catch-all + dashboard
├── 04-cutover.sh                      # DNS canary switch (the migration)
├── 05-cleanup.sh                      # Remove everything
├── load-generator.sh                  # Zero-downtime proof (Terminal 2)
├── manifests/
│   ├── sample-app.yaml                # Echo server deployment + service
│   ├── ingress-nginx-basic.yaml       # Vanilla Ingress (S0)
│   ├── ingress-nginx-annotated.yaml   # Annotated Ingress (S1)
│   ├── traefik-catchall.yaml          # Catch-all IngressRoute (safety net)
│   └── gateway-api-route.yaml         # Optional: Gateway API (HTTPRoute + Gateway)
└── values/
    ├── nginx-values.yaml              # Helm values for ingress-nginx
    └── traefik-values.yaml            # Helm values for Traefik
```

---

## Demo credentials

The `secure.*` host uses HTTP basic auth: **`demo` / `demo123`**. It's a
throwaway credential generated at setup time — not a secret, and it grants
nothing beyond the echo server in this demo cluster.

## License

**All rights reserved** — see [LICENSE.md](LICENSE.md). This is demo code for a
talk, published so you can read and learn from it. Please don't lift it wholesale
into your own projects; if you'd like to reuse it, just ask.
