# NetBird Mesh PoC — Full Learning Summary

## What is This PoC?

Connect 5 MariaDB databases across 2 Kubernetes clusters using NetBird mesh networking (WireGuard tunnels). The goal is to let a DevOps container reach any database ClusterIP across clusters — without exposing ports or changing any existing database config.

---

## The 4 Main Components

1. **NetBird control plane** — runs on Mac via Docker Compose. The brain of the mesh. Manages peers, groups, routes, and policies. Does NOT carry traffic.
2. **Two Minikube clusters** — each with MariaDB StatefulSets. ClusterIPs are normally unreachable from outside.
3. **Routing peer pod** (one per cluster) — joins the mesh and advertises which cluster Service CIDR it can reach.
4. **DevOps container** — also a mesh peer. Receives routes and reaches databases through routing peers over WireGuard tunnels.

### Traffic Flow

```
DevOps container
  ├── WireGuard tunnel ──> routing peer (clusterA) ──> MariaDB ns1/ns2/ns3
  └── WireGuard tunnel ──> routing peer (clusterB) ──> MariaDB ns4/ns5
```

---

## Key Concepts

### Groups

Labels assigned to peers. Control who routes traffic and who receives routes.

| Group | Purpose |
| --- | --- |
| kubernetes-routers-a | ClusterA gateway pod |
| kubernetes-routers-b | ClusterB gateway pod |
| devops | DevOps container |

### Setup Keys

How each peer knows which group it belongs to. Created in Step 4c with `auto_groups` attached. Passed as `NB_SETUP_KEY` env var when the pod or container starts. The control plane reads the key and auto-places the peer into the correct group.

- `router-a.key` → auto_groups: [routers-a]
- `router-b.key` → auto_groups: [routers-b]
- `devops.key` → auto_groups: [devops]

Setup keys are created in **Step 4c** — after groups exist (4b) and after PAT is obtained (4a).

### Routes

Tell NetBird what IP range is reachable through which router group, and which peers receive the route.

| Field | Meaning |
| --- | --- |
| network | Destination CIDR (e.g. 10.96.0.0/16) |
| peer_groups | Which group acts as the gateway |
| groups | Which peers receive and install this route |
| masquerade: true | Router rewrites src IP so MariaDB can reply back |

### Policies (ACL)

Zero-trust by default — everything is blocked unless explicitly allowed. Even with a route installed, traffic is dropped without a matching policy.

```
Policy: devops-to-k8s
  sources:       [devops]
  destinations:  [routers-a, routers-b]
  bidirectional: true
  action:        accept
```

### Critical Design Rule: Different Service CIDRs

The two clusters MUST use different Service CIDRs:

- ClusterA: `10.96.0.0/16`
- ClusterB: `10.97.0.0/16`

NetBird routes by destination IP range. If both clusters share the same CIDR, the mesh cannot distinguish them and traffic goes to the wrong cluster.

---

## Step-by-Step Walkthrough

### Step 0 — /etc/hosts

```bash
echo '127.0.0.1 netbird.local' | sudo tee -a /etc/hosts
```

One-time Mac setup. Resolves `netbird.local` to localhost. Only command needing `sudo`. Done once.

### Step 1 — TLS Certificates

NetBird agents refuse plain HTTP — HTTPS is required. No public domain, so we become our own CA.

- **1a**: Create root CA (`rootCA-key.pem` + `rootCA.pem`)
- **1b**: Create server key + CSR (`netbird.local-key.pem` + `.csr`)
- **1c**: Define SAN list — modern TLS ignores CN, only checks SAN (DNS.1=netbird.local, IP.1=127.0.0.1)
- **1d**: CA signs the server cert → `netbird.local.pem` (server cert + CA chain appended)

`rootCA.pem` is later given to ALL peers so they trust our control plane TLS. Baked into the DevOps Docker image and mounted as a ConfigMap in router pods.

### Step 2 — Secrets + Config

Generate 3 random secrets using `openssl rand`, fill into `config.yaml.tmpl` using `sed`:

| Secret | Purpose |
| --- | --- |
| RELAY_AUTH_SECRET | Authenticates peers to the relay |
| STORE_ENCRYPTION_KEY | Encrypts sensitive data at rest |
| IDP_COOKIE_KEY | Encrypts identity provider session cookies |

Templates stay in git. Rendered files with real secrets stay out of git.

### Step 3 — Start Control Plane

```bash
docker compose -f netbird/docker-compose.yml up -d
```

| Container | Role |
| --- | --- |
| netbird-caddy | Reverse proxy, terminates TLS on port 443, routes gRPC vs HTTP traffic |
| netbird-server | Mgmt + Signal + Relay + IDP (all-in-one image) |
| netbird-dashboard | Web UI — can also do Steps 4 and 8 via UI instead of API |

### Step 4 — Bootstrap via API

**4a — Create admin + PAT**

POST `/api/setup` creates the first owner and returns a Personal Access Token. This endpoint only works ONCE — it closes after the first use.

PAT = admin API token for YOU to configure things. Setup Key = enrollment token for PEERS to join. Never give peers the PAT.

**4b — Create 3 groups**

Create `kubernetes-routers-a`, `kubernetes-routers-b`, `devops`. Save group IDs to shell variables — needed in Step 8.

**4c — Create 3 setup keys**

- One per group with `auto_groups` attached
- `reusable: true` — same key can enroll many peers (safe for pod restarts)
- `ephemeral: true` — peer offline >10min = auto removed, keeps peer list clean
- Keys saved to `netbird/.keys/`

Keep terminal open after Step 4 — shell variables (`$PAT`, `$GID_*`) are needed in Step 8.

### Step 5 — Start Minikube Clusters

```bash
minikube start --profile clusterA --service-cluster-ip-range 10.96.0.0/16
minikube start --profile clusterB --service-cluster-ip-range 10.97.0.0/16
```

`--service-cluster-ip-range` sets the CIDR for Service ClusterIPs — must be different per cluster. Each profile becomes a kubectl context. Always use `--context` explicitly. Step 5 can run in parallel with Steps 1–4.

### Step 6 — Deploy MariaDB

5 namespaces total: ns1–ns3 (clusterA), ns4–ns5 (clusterB). Each namespace gets:

- `StatefulSet` + PVC — database pod with persistent storage (survives pod restarts)
- `mariadb` headless service — required by StatefulSet for stable DNS
- `mariadb-client` ClusterIP service — the stable IP that NetBird routes to

Use `rollout status` to wait for readiness before next step.

ClusterIPs are assigned dynamically and change every time clusters restart. Never hardcode them — always look them up fresh.

### Step 7 — Deploy Routing Peers

Per cluster — 3 kubectl commands:

```bash
kubectl --context clusterA create namespace netbird
kubectl --context clusterA -n netbird create configmap netbird-ca --from-file=rootCA.pem=netbird/certs/rootCA.pem
kubectl --context clusterA apply -f k8s/netbird-router/.rendered/router-A.yaml
```

| Pod Setting | Purpose |
| --- | --- |
| NB_SETUP_KEY | Joins mesh, auto-placed in correct group |
| hostAliases: netbird.local → HOST_IP | In-pod /etc/hosts equivalent |
| SSL_CERT_FILE | Points to CA cert from ConfigMap |
| NET_ADMIN + SYS_ADMIN | Creates WireGuard interface, manipulates routing tables |
| /dev/net/tun | WireGuard tunnel device |

HOST_IP = the address pods use to reach the Mac (detected from minikube, never hardcoded).

Verify: `kubectl -n netbird exec deploy/netbird-router -- netbird status` → should show `Management: Connected`.

### Step 8 — Create Routes + Policy

Must come AFTER Step 7 — routes with empty `peer_groups` return HTTP 422.

**Route for ClusterA:**

```json
{ "network": "10.96.0.0/16", "peer_groups": ["GID_ROUTERS_A"], "groups": ["GID_DEVOPS"], "masquerade": true }
```

**Route for ClusterB:**

```json
{ "network": "10.97.0.0/16", "peer_groups": ["GID_ROUTERS_B"], "groups": ["GID_DEVOPS"], "masquerade": true }
```

**Policy:**

```json
{ "sources": ["GID_DEVOPS"], "destinations": ["GID_ROUTERS_A", "GID_ROUTERS_B"], "bidirectional": true, "action": "accept" }
```

### Step 9 — DevOps Container

```bash
docker build -t netbird-poc/devops-server:latest devops-server
docker run -d --name devops-server \
  --cap-add NET_ADMIN --cap-add SYS_ADMIN --device /dev/net/tun \
  --add-host netbird.local:${HOST_IP} \
  -e NB_SETUP_KEY="$(cat netbird/.keys/devops.key)" \
  netbird-poc/devops-server:latest
```

Image contains: NetBird agent + MariaDB client + rootCA.pem baked in.

Wait ~25s for routes to propagate. Verify:

```bash
docker exec devops-server netbird status --detail
# Look for: 10.96.0.0/16 Status: Selected
#           10.97.0.0/16 Status: Selected
#           Both routing peers: Connected (P2P)
```

### Step 10 — Test Connectivity

**Test 1:** TCP + SQL check to all 5 ClusterIPs → expect TCP=OK SQL=OK for all 5

**Test 2:** Full write/read round-trip via real SQL

**Test 3 (Negative):** Run same check from Mac directly → must FAIL (timeout). This contrast IS the proof — same IP, same port, different result depending on whether you are inside the mesh.

---

## Q&A Key Insights

### ephemeral: true vs false in Production

| Peer Type | Setting | Reason |
| --- | --- | --- |
| Kubernetes pods | ephemeral: true | Pods restart often, auto-cleanup prevents stale entries |
| Permanent VMs/servers | ephemeral: false | Don't want server removed during maintenance window |
| Developer laptops | ephemeral: true | Laptops turn off, no need to keep stale entries |

Risk: pod offline >10min → auto-removed → brief traffic disruption until pod restarts and re-enrolls. Mitigate with good liveness probes and alerting.

### UI vs API

Everything in Steps 4 and 8 can also be done via the dashboard UI. API is preferred for automation and reproducibility. Production recommendation: use Terraform (NetBird has an official Terraform provider).

### Zero-Trust Between Clusters

ClusterA CANNOT reach ClusterB by design — no route or policy exists for that path. NetBird denies by default. Only explicitly allowed paths work. To allow cluster-to-cluster if needed: add a route distributing the other cluster CIDR to the router group, and add a policy permitting it.

### No Changes to Existing MariaDB

StatefulSet and Services need zero modifications. Just deploy the routing peer pod in a separate `netbird` namespace. The routing peer sits in the cluster and says: send me packets for this CIDR and I will forward them. MariaDB only sees normal internal cluster traffic.

Check NetworkPolicies first:

```bash
kubectl get networkpolicies -A
```

If NetworkPolicies exist, add a rule: allow from namespace `netbird` to MariaDB namespace on port 3306.

### Service CIDR Discovery in Production

Clusters already exist — discover their CIDRs:

```bash
kubectl --context <ctx> cluster-info dump | grep service-cluster-ip-range
kubectl --context <ctx> get svc -A | grep ClusterIP
```

If both clusters share the same CIDR — routing conflict. Must resolve before designing routes (use more specific subnets or check with cloud provider).

---

## Production Task Plan (Conicle)

### Target Environments

- DigitalOcean Kubernetes (MariaDB StatefulSets)
- Huawei CCE (MariaDB StatefulSets)
- Access clients: Airbyte VM, other VMs, pods from different clusters

NetBird is already self-hosted at Conicle — skip Steps 0–3. Start from group/key design directly.

### Group Design

| Group | Purpose |
| --- | --- |
| routers-digitalocean | Routing peer in DO K8s |
| routers-huawei | Routing peer in Huawei CCE |
| devops | DevOps team admin access |
| data-clients | Airbyte + VMs needing DB access |

### Phase Plan

1. **Phase 1** — Gather Info: discover Service CIDRs for DO and Huawei, check overlap, confirm existing NetBird setup
2. **Phase 2** — Design groups
3. **Phase 3** — Design routes (based on discovered CIDRs)
4. **Phase 4** — Design policies (least privilege per client type)
5. **Phase 5** — Check NetworkPolicies in both clusters
6. **Phase 6** — Create config objects in NetBird dashboard (groups, setup keys, routes, policies)
7. **Phase 7** — Deploy routing peer pods in DO K8s + Huawei CCE (3 kubectl commands per cluster)
8. **Phase 8** — Install NetBird agent on Airbyte + VMs (`netbird up --setup-key ...`)
9. **Phase 9** — Test all connections + negative tests

### Production Differences vs PoC

| Item | PoC | Production |
| --- | --- | --- |
| TLS cert | Self-signed CA | Real domain + Let's Encrypt (no rootCA setup needed) |
| Control plane | Docker Compose on Mac | Dedicated VM with backups |
| Clusters | Minikube | Real CCE / DO Kubernetes clusters |
| Config management | curl API calls | Terraform (NetBird provider) |
| Monitoring | Manual checks | VictoriaMetrics integration |

### ISO 27001 Relevance

NetBird directly supports compliance requirements:

- Encrypted traffic in transit (WireGuard)
- Zero-trust access control (deny by default)
- Centralized access management (one control plane for all environments)
- Audit trail (NetBird logs all peer connections)
- Least privilege (each service only reaches what it needs)

---

## Prerequisites

- macOS (tested) or Linux with: `docker`, `minikube`, `kubectl`, `jq`, `curl`, `openssl`
- ~16 GB RAM recommended (2 clusters + control plane + DevOps container)
- A working Docker daemon (Docker Desktop / Rancher Desktop)

## How to Use

This PoC is designed to be followed **step-by-step** via [`HANDSON.md`](HANDSON.md). Read the walkthrough above to understand the concepts, then execute the hands-on guide.

### Reset for a Fresh Run

```bash
make restart-handson
```

This tears down everything (clusters, control plane, DevOps container, generated certs/keys) and removes the DevOps image so you can start over from HANDSON.md Step 1. The `/etc/hosts` entry is preserved across runs.

## Repository Layout

```
netbird-poc/
├── Makefile                     # reset command (make restart-handson)
├── HANDSON.md                   # step-by-step execution guide
├── netbird/                     # self-hosted control plane
│   ├── docker-compose.yml       #   caddy + netbird-server + dashboard
│   ├── Caddyfile                #   TLS termination + gRPC/HTTP routing
│   ├── config.yaml.tmpl         #   combined-server config template
│   ├── dashboard.env.tmpl       #   dashboard env template
│   ├── gen-certs.sh             #   self-signed CA + server cert
│   ├── netbird-up.sh            #   render + start the control plane
│   ├── netbird-bootstrap.sh     #   API: owner/PAT, groups, keys, routes, ACL
│   └── README.md                #   control-plane details
├── k8s/
│   ├── mariadb/mariadb.yaml.tmpl       # StatefulSet + Services + Secret
│   └── netbird-router/router.yaml.tmpl # routing-peer Deployment
├── devops-server/               # DevOps container (agent + mysql client + CA)
│   ├── Dockerfile
│   └── entrypoint.sh
└── scripts/
    ├── config.sh                # single source of truth for all params
    ├── preflight.sh
    ├── clusters-up.sh
    ├── deploy-mariadb.sh
    ├── deploy-router.sh
    ├── devops-up.sh
    ├── list-db-endpoints.sh
    ├── test-connectivity.sh
    └── teardown.sh
```

## Configuration

All tunables live in [`scripts/config.sh`](scripts/config.sh) and can be overridden via environment variables (CIDRs, namespaces, credentials, image tags, cluster sizing, group names, host IP, etc.).

> **Host IP is auto-detected.** Cluster pods reach the host control plane via `host.minikube.internal`. The scripts detect it per machine automatically. To force a specific value, set `NETBIRD_HOST_IP=<ip>`.

## Troubleshooting

- **Routes fail with 422 "list of group ids should not be empty"** — routers haven't registered yet; ensure Step 7 succeeded first.
- **DevOps container shows `Networks: -`** — wait ~20s for route convergence, then `docker exec devops-server netbird status --detail`.
- **TLS errors from agents** — confirm `netbird/certs/rootCA.pem` exists and router pods mounted the `netbird-ca` ConfigMap.
- **Port 80/443/3478 already allocated** — another service holds the port; stop it or run `make restart-handson` first.
- **Dashboard**: https://netbird.local (admin `admin@netbird.local` / `NetBirdAdmin1!`).
