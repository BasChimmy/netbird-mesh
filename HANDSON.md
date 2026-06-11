# Hands-On Walkthrough — Building the NetBird Mesh PoC by Hand

This guide rebuilds the **entire** PoC using raw commands only — no `*.sh`
scripts, no `make`. Every step explains *what* you run and *why*, so you
understand each moving part instead of treating the scripts as a black box.

> The scripts in this repo automate exactly these commands. This document is
> the "show your work" version.

**Run everything from the repo root:**

```bash
cd /Users/basjirayu/Desktop/my_projects/devops/netbird-poc
```

## The mental model (read this first)

We are building four things and wiring them together:

1. **A NetBird control plane** (on your Mac, via Docker Compose) — the
   "brain" of the mesh. It authenticates peers, hands out IPs, distributes
   routes, and enforces access policies. It does **not** carry your traffic.
2. **Two minikube clusters**, each with **MariaDB** databases. Their internal
   Service IPs (ClusterIPs) are normally unreachable from outside the cluster.
3. **One NetBird "routing peer" per cluster** — a pod running the NetBird
   agent that joins the mesh and advertises *"I can reach this cluster's
   Service network."* It's the bridge between the mesh and the cluster.
4. **A DevOps container** — also a NetBird peer. It receives the routes and can
   therefore reach the database ClusterIPs *through* the routing peers, over
   encrypted WireGuard tunnels.

```
DevOps container ──WireGuard──> routing peer (clusterA) ──> MariaDB in ns1/2/3
                 └─WireGuard──> routing peer (clusterB) ──> MariaDB in ns4/5
```

The single most important design rule: **the two clusters must use different
Service CIDRs** (`10.96.0.0/16` vs `10.97.0.0/16`). NetBird decides where to
send a packet purely by its destination IP range. If both clusters used the
same range, the mesh could not tell them apart.

---

## Step 0 — One-time host setup

```bash
echo '127.0.0.1 netbird.local' | sudo tee -a /etc/hosts
```

**Why:** The control plane is addressed by the hostname `netbird.local`. Your
Mac needs to resolve that name to itself. We use a fake local domain (not a
real one) because this is fully offline — there is no public DNS or Let's
Encrypt involved. This is the only command that needs `sudo`, and you only
ever do it once.

---

## Step 1 — Create a local TLS certificate authority (CA) + server cert

NetBird agents speak to the control plane over HTTPS and **refuse plain HTTP**.
With no public domain we cannot get a real (Let's Encrypt) certificate, so we
become our own certificate authority and issue a cert for `netbird.local`.

```bash
mkdir -p netbird/certs
```

### 1a. The root CA

```bash
openssl genrsa -out netbird/certs/rootCA-key.pem 4096
openssl req -x509 -new -nodes -key netbird/certs/rootCA-key.pem -sha256 -days 3650 \
  -subj "/C=US/O=NetBird PoC Local CA/CN=NetBird PoC Root CA" \
  -out netbird/certs/rootCA.pem
```

**Why:** A CA is a self-signed "trust anchor." Anything it signs is trusted by
whoever trusts the CA. We will later hand `rootCA.pem` to every NetBird agent
so they trust our server certificate. `genrsa` makes the CA's private key;
`req -x509` creates the self-signed CA certificate from it.

### 1b. The server private key + signing request (CSR)

```bash
openssl genrsa -out netbird/certs/netbird.local-key.pem 4096
openssl req -new -key netbird/certs/netbird.local-key.pem \
  -subj "/C=US/O=NetBird PoC/CN=netbird.local" \
  -out netbird/certs/netbird.local.csr
```

**Why:** This is the key/cert the web server (Caddy) will actually present. A
CSR ("certificate signing request") is the cert-to-be that we ask the CA to
sign in the next step.

### 1c. Subject Alternative Names (SAN)

```bash
cat > netbird/certs/netbird.local.ext <<'EOF'
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = netbird.local
DNS.2 = localhost
IP.1  = 127.0.0.1
EOF
```

**Why:** Modern TLS clients ignore the old "Common Name" field and validate the
hostname against the **SAN** list. Without `DNS.1 = netbird.local` here, every
client would reject the cert with a hostname-mismatch error. This was a real
gotcha — a cert with only a CN silently fails.

### 1d. Sign the server cert with the CA, then build a full chain

```bash
openssl x509 -req -in netbird/certs/netbird.local.csr \
  -CA netbird/certs/rootCA.pem -CAkey netbird/certs/rootCA-key.pem -CAcreateserial \
  -out netbird/certs/netbird.local.pem -days 825 -sha256 \
  -extfile netbird/certs/netbird.local.ext

cat netbird/certs/rootCA.pem >> netbird/certs/netbird.local.pem
```

**Why:** The CA signs the CSR, producing `netbird.local.pem`. We append the CA
cert to the server cert so Caddy serves a **full chain** (server + issuer),
which lets clients build the trust path. `825` days is the max validity modern
browsers accept for a leaf cert.

**Verify:**

```bash
openssl x509 -in netbird/certs/netbird.local.pem -noout -subject -ext subjectAltName
```

---

## Step 2 — Generate secrets and render the control-plane config

The control plane is configured by `config.yaml` (combined server) and
`dashboard.env` (the web UI). The repo ships **templates** with `__PLACEHOLDER__`
markers; we fill them in with generated secrets.

```bash
mkdir -p netbird/.keys

# Three independent 256-bit secrets, base64-encoded
RELAY_AUTH_SECRET="$(openssl rand -base64 32)"
STORE_ENCRYPTION_KEY="$(openssl rand -base64 32)"
IDP_COOKIE_KEY="$(openssl rand -base64 32)"
```

**Why each secret exists:**
- `RELAY_AUTH_SECRET` — authenticates peers to the built-in relay (used when a
  direct P2P tunnel can't be established).
- `STORE_ENCRYPTION_KEY` — encrypts sensitive data at rest in the server's
  database (setup keys, tokens).
- `IDP_COOKIE_KEY` — encrypts the embedded identity provider's session cookies.

```bash
# Render config.yaml
sed \
  -e "s|__NETBIRD_DOMAIN__|netbird.local|g" \
  -e "s|__RELAY_AUTH_SECRET__|${RELAY_AUTH_SECRET}|g" \
  -e "s|__STORE_ENCRYPTION_KEY__|${STORE_ENCRYPTION_KEY}|g" \
  -e "s|__IDP_COOKIE_KEY__|${IDP_COOKIE_KEY}|g" \
  netbird/config.yaml.tmpl > netbird/config.yaml

# Render dashboard.env
sed -e "s|__NETBIRD_DOMAIN__|netbird.local|g" \
  netbird/dashboard.env.tmpl > netbird/dashboard.env
```

**Why `sed`:** It's a simple find-and-replace to turn the templates into real
config. We keep templates in git and the rendered files out of git (they hold
secrets).

---

## Step 3 — Start the control plane

```bash
docker compose -f netbird/docker-compose.yml up -d
```

**Why:** This starts three containers on a shared Docker network:
- `netbird-caddy` — reverse proxy that terminates our self-signed TLS on
  ports 80/443 and routes requests to the right backend.
- `netbird-server` — the **combined** server: management + signal + relay +
  STUN + an embedded identity provider, all in one image.
- `netbird-dashboard` — the web UI.

Caddy is needed because the server speaks both gRPC (for the agent protocol)
and plain HTTP (API, OAuth) — Caddy presents one clean HTTPS endpoint and
splits traffic by URL path behind the scenes.

**Verify (give it ~15s to boot):**

```bash
sleep 15
docker ps --filter name=netbird-

# Confirm TLS works and the identity provider is serving discovery metadata.
# --resolve forces netbird.local -> 127.0.0.1 for just this request,
# --cacert tells curl to trust our CA.
curl --cacert netbird/certs/rootCA.pem --resolve netbird.local:443:127.0.0.1 \
  https://netbird.local/oauth2/.well-known/openid-configuration
```

You should get JSON with `"issuer": "https://netbird.local/oauth2"`.

---

## Step 4 — Bootstrap the mesh objects via the NetBird API

A fresh NetBird instance has no users. We use the **setup API** (enabled by
`NB_SETUP_PAT_ENABLED=true` in the compose file) to create the first owner and
get a **Personal Access Token (PAT)** we can automate with. Then we create the
groups and setup keys our peers will use.

> **Concept — setup key vs PAT.** A *PAT* is an admin API token (for *us* to
> configure things). A *setup key* is an enrollment token (for a *peer* to join
> the mesh). Peers never see the PAT.

### 4a. Create the owner + PAT

```bash
RESP="$(curl -fsS --cacert netbird/certs/rootCA.pem --resolve netbird.local:443:127.0.0.1 -X POST https://netbird.local/api/setup -H "Content-Type: application/json" -d '{"email":"admin@netbird.local","name":"PoC Admin","password":"NetBirdAdmin1!","create_pat":true,"pat_expire_in":365}')"

echo "$RESP" | jq -r '.personal_access_token' > netbird/.keys/admin.pat
chmod 600 netbird/.keys/admin.pat
PAT="$(cat netbird/.keys/admin.pat)"
```

**Why:** Creating the first owner *closes* the setup endpoint (it only works
while no account exists), so this both bootstraps admin access and locks the
door behind us. We save the PAT to a file and into `$PAT` for reuse.

### 4b. Create the three groups

```bash
GID_ROUTERS_A="$(curl -fsS --cacert netbird/certs/rootCA.pem --resolve netbird.local:443:127.0.0.1 -H "Authorization: Token $PAT" -H "Content-Type: application/json" -X POST https://netbird.local/api/groups --data-raw '{"name":"kubernetes-routers-a"}' | jq -r '.id')"

GID_ROUTERS_B="$(curl -fsS --cacert netbird/certs/rootCA.pem --resolve netbird.local:443:127.0.0.1 -H "Authorization: Token $PAT" -H "Content-Type: application/json" -X POST https://netbird.local/api/groups --data-raw '{"name":"kubernetes-routers-b"}' | jq -r '.id')"

GID_DEVOPS="$(curl -fsS --cacert netbird/certs/rootCA.pem --resolve netbird.local:443:127.0.0.1 -H "Authorization: Token $PAT" -H "Content-Type: application/json" -X POST https://netbird.local/api/groups --data-raw '{"name":"devops"}' | jq -r '.id')"

echo "routers-a=$GID_ROUTERS_A  routers-b=$GID_ROUTERS_B  devops=$GID_DEVOPS"
```

**Why three groups, and why routers are split:** Groups are how NetBird targets
routes and policies. The clusterA router goes in `kubernetes-routers-a`, the
clusterB router in `kubernetes-routers-b`. They are **separate on purpose**:
each group advertises only *its own* cluster's CIDR. If both routers shared one
group, the group would claim to reach *both* CIDRs and traffic could be sent to
the wrong cluster (blackholed). The `devops` group is where our container lands.

### 4c. Create one reusable setup key per group

```bash
curl -fsS --cacert netbird/certs/rootCA.pem --resolve netbird.local:443:127.0.0.1 -H "Authorization: Token $PAT" -H "Content-Type: application/json" -X POST https://netbird.local/api/setup-keys --data-raw "{\"name\":\"router-clusterA\",\"type\":\"reusable\",\"expires_in\":31536000,\"auto_groups\":[\"$GID_ROUTERS_A\"],\"usage_limit\":0,\"ephemeral\":true}" | jq -r '.key' > netbird/.keys/router-a.key

curl -fsS --cacert netbird/certs/rootCA.pem --resolve netbird.local:443:127.0.0.1 -H "Authorization: Token $PAT" -H "Content-Type: application/json" -X POST https://netbird.local/api/setup-keys --data-raw "{\"name\":\"router-clusterB\",\"type\":\"reusable\",\"expires_in\":31536000,\"auto_groups\":[\"$GID_ROUTERS_B\"],\"usage_limit\":0,\"ephemeral\":true}" | jq -r '.key' > netbird/.keys/router-b.key

curl -fsS --cacert netbird/certs/rootCA.pem --resolve netbird.local:443:127.0.0.1 -H "Authorization: Token $PAT" -H "Content-Type: application/json" -X POST https://netbird.local/api/setup-keys --data-raw "{\"name\":\"devops-server\",\"type\":\"reusable\",\"expires_in\":31536000,\"auto_groups\":[\"$GID_DEVOPS\"],\"usage_limit\":0,\"ephemeral\":true}" | jq -r '.key' > netbird/.keys/devops.key

chmod 600 netbird/.keys/*.key
```

**Why these options:**
- `auto_groups` — a peer joining with this key is **automatically placed** in
  the right group. That's how the clusterA router lands in `routers-a` without
  any manual step.
- `reusable` + `usage_limit: 0` — the key can enroll many peers (handy if a
  pod restarts).
- `ephemeral: true` — peers that go offline for ~10 min are auto-removed,
  keeping the peer list clean for restart-prone pods.
- `expires_in: 31536000` — one year (the API max).

**Keep these shell variables** (`$PAT`, `$GID_ROUTERS_A`, `$GID_ROUTERS_B`,
`$GID_DEVOPS`) — Step 8 needs them.

---

## Step 5 — Start the two minikube clusters

```bash
minikube start --profile clusterA --driver docker --cpus 2 --memory 3072 \
  --kubernetes-version stable \
  --service-cluster-ip-range 10.96.0.0/16 \
  --extra-config kubeadm.pod-network-cidr=10.244.0.0/16

minikube start --profile clusterB --driver docker --cpus 2 --memory 3072 \
  --kubernetes-version stable \
  --service-cluster-ip-range 10.97.0.0/16 \
  --extra-config kubeadm.pod-network-cidr=10.245.0.0/16
```

**Why the flags:**
- `--profile` — minikube runs two independent clusters keyed by profile name.
  Each profile becomes a kubectl **context** of the same name.
- `--service-cluster-ip-range` — **the critical flag.** It sets the CIDR that
  Service ClusterIPs are allocated from. A=`10.96/16`, B=`10.97/16`, distinct
  so the mesh can route to each unambiguously.
- `--extra-config kubeadm.pod-network-cidr` — keeps the pod networks distinct
  too, for tidiness.

**Verify:**

```bash
kubectl --context clusterA get nodes
kubectl --context clusterB get nodes
```

> Always pass `--context` explicitly. If you have other kubeconfigs loaded, the
> "current" context might point somewhere else entirely.

---

## Step 6 — Deploy MariaDB into all five namespaces

ns1–3 live in clusterA, ns4–5 in clusterB. For each we render the MariaDB
template (injecting the namespace and credentials), create the namespace,
apply, and wait for the database to be ready.

```bash
mkdir -p k8s/mariadb/.rendered

for ns in ns1 ns2 ns3; do CTX=clusterA
  sed -e "s|__NAMESPACE__|$ns|g" -e "s|__ROOT_PASSWORD__|rootpass|g" \
      -e "s|__APP_DB__|appdb|g" -e "s|__APP_USER__|appuser|g" \
      -e "s|__APP_PASSWORD__|apppass|g" -e "s|__MARIADB_IMAGE__|mariadb:11.4|g" \
      -e "s|__MARIADB_PORT__|3306|g" -e "s|__STORAGE_SIZE__|1Gi|g" \
      k8s/mariadb/mariadb.yaml.tmpl > k8s/mariadb/.rendered/mariadb-$ns.yaml
  kubectl --context $CTX create namespace $ns --dry-run=client -o yaml | kubectl --context $CTX apply -f -
  kubectl --context $CTX apply -f k8s/mariadb/.rendered/mariadb-$ns.yaml
  kubectl --context $CTX -n $ns rollout status statefulset/mariadb --timeout 300s
done

for ns in ns4 ns5; do CTX=clusterB
  sed -e "s|__NAMESPACE__|$ns|g" -e "s|__ROOT_PASSWORD__|rootpass|g" \
      -e "s|__APP_DB__|appdb|g" -e "s|__APP_USER__|appuser|g" \
      -e "s|__APP_PASSWORD__|apppass|g" -e "s|__MARIADB_IMAGE__|mariadb:11.4|g" \
      -e "s|__MARIADB_PORT__|3306|g" -e "s|__STORAGE_SIZE__|1Gi|g" \
      k8s/mariadb/mariadb.yaml.tmpl > k8s/mariadb/.rendered/mariadb-$ns.yaml
  kubectl --context $CTX create namespace $ns --dry-run=client -o yaml | kubectl --context $CTX apply -f -
  kubectl --context $CTX apply -f k8s/mariadb/.rendered/mariadb-$ns.yaml
  kubectl --context $CTX -n $ns rollout status statefulset/mariadb --timeout 300s
done
```

**Why each piece:**
- Each namespace gets a **StatefulSet** (1 replica, PVC-backed so data
  survives restarts), a **headless service** `mariadb` (required by the
  StatefulSet for stable pod DNS), and a **ClusterIP service** `mariadb-client`
  (the stable IP the mesh will target — it lives inside the advertised CIDR).
- `create namespace ... --dry-run=client -o yaml | kubectl apply -f -` is the
  idempotent "create-if-missing" idiom: it never errors if the namespace
  already exists.
- `rollout status` blocks until MariaDB passes its readiness probe, so the next
  steps don't race a half-started database.

**Verify and note the ClusterIPs (you'll target these):**

```bash
for ns in ns1 ns2 ns3; do kubectl --context clusterA -n $ns get svc mariadb-client \
  -o jsonpath="clusterA $ns {.spec.clusterIP}:3306"$'\n'; done
for ns in ns4 ns5; do kubectl --context clusterB -n $ns get svc mariadb-client \
  -o jsonpath="clusterB $ns {.spec.clusterIP}:3306"$'\n'; done
```

---

## Step 7 — Deploy a NetBird routing peer into each cluster

This is the bridge. Each cluster gets a pod running the NetBird agent. It joins
the mesh with that cluster's setup key (landing in the right group) and is
later told to advertise the cluster's Service CIDR.

Two things must exist before the pod: the `netbird` namespace and a ConfigMap
holding our CA (so the agent trusts the management TLS). We create the CA
ConfigMap with `kubectl --from-file` rather than baking the cert into the YAML,
because embedding a multi-line PEM into YAML via `sed` is error-prone.

> **First, detect your host IP** (the address cluster pods use to reach the
> control plane on your Mac). It differs by Docker backend, so don't assume
> `192.168.65.254`. Ask minikube:
>
> ```bash
> HOST_IP="$(minikube -p clusterA ssh "grep host.minikube.internal /etc/hosts | awk '{print \$1}'" | tr -d '[:space:]\r')"
> echo "HOST_IP=$HOST_IP"
> ```
>
> You should see a real IPv4 address. We use `$HOST_IP` in the `sed` commands
> below. (The scripts do this detection automatically; here we do it by hand.)

```bash
mkdir -p k8s/netbird-router/.rendered

# ---------- clusterA ----------
kubectl --context clusterA create namespace netbird \
  --dry-run=client -o yaml | kubectl --context clusterA apply -f -
kubectl --context clusterA -n netbird create configmap netbird-ca \
  --from-file=rootCA.pem=netbird/certs/rootCA.pem \
  --dry-run=client -o yaml | kubectl --context clusterA apply -f -

sed -e "s|__SETUP_KEY__|$(cat netbird/.keys/router-a.key)|g" \
    -e "s|__HOST_IP__|${HOST_IP}|g" \
    -e "s|__NETBIRD_DOMAIN__|netbird.local|g" \
    -e "s|__PEER_HOSTNAME__|netbird-router-clustera|g" \
    k8s/netbird-router/router.yaml.tmpl > k8s/netbird-router/.rendered/router-A.yaml
kubectl --context clusterA apply -f k8s/netbird-router/.rendered/router-A.yaml
kubectl --context clusterA -n netbird rollout status deployment/netbird-router --timeout 180s

# ---------- clusterB ----------
kubectl --context clusterB create namespace netbird \
  --dry-run=client -o yaml | kubectl --context clusterB apply -f -
kubectl --context clusterB -n netbird create configmap netbird-ca \
  --from-file=rootCA.pem=netbird/certs/rootCA.pem \
  --dry-run=client -o yaml | kubectl --context clusterB apply -f -

sed -e "s|__SETUP_KEY__|$(cat netbird/.keys/router-b.key)|g" \
    -e "s|__HOST_IP__|${HOST_IP}|g" \
    -e "s|__NETBIRD_DOMAIN__|netbird.local|g" \
    -e "s|__PEER_HOSTNAME__|netbird-router-clusterb|g" \
    k8s/netbird-router/router.yaml.tmpl > k8s/netbird-router/.rendered/router-B.yaml
kubectl --context clusterB apply -f k8s/netbird-router/.rendered/router-B.yaml
kubectl --context clusterB -n netbird rollout status deployment/netbird-router --timeout 180s
```

**Why the key details in the manifest:**
- **`hostAliases` → `$HOST_IP netbird.local`** — `$HOST_IP` (which you detected
  above) is the address minikube pods use to reach your Mac (a.k.a.
  `host.minikube.internal`, where the control plane runs). This is the
  in-cluster equivalent of the `/etc/hosts` line from Step 0. The value differs
  by Docker backend, which is why we detect it instead of hardcoding.
- **`SSL_CERT_FILE=/etc/netbird-ca/rootCA.pem`** + the mounted ConfigMap — tells
  the agent to trust our CA.
- **`securityContext.capabilities: NET_ADMIN, SYS_RESOURCE, SYS_ADMIN`** — the
  agent creates a WireGuard interface and manipulates routing, which needs
  these kernel capabilities.
- **`netbird status --check` probes** — the agent's own health checks, so
  Kubernetes knows when the peer is actually live/ready.

**Verify the routers joined (should say `Management: Connected`):**

```bash
kubectl --context clusterA -n netbird exec deploy/netbird-router -- netbird status
kubectl --context clusterB -n netbird exec deploy/netbird-router -- netbird status
```

---

## Step 8 — Create the routes and the access policy

The routers are on the mesh but nobody has told the mesh *what they can reach*
or *who is allowed to use them*. We fix both now via the API.

> **Order matters:** this must come *after* Step 7. A route's `peer_groups` must
> contain at least one registered peer, or the API rejects it with HTTP 422.

```bash
# Route: clusterA's Service CIDR, reachable via the routers-a group,
# distributed to (installed on) the devops group.
curl -fsS --cacert netbird/certs/rootCA.pem --resolve netbird.local:443:127.0.0.1 -H "Authorization: Token $PAT" -H "Content-Type: application/json" -X POST https://netbird.local/api/routes --data-raw "{\"description\":\"PoC route for clusterA-svc\",\"network_id\":\"clusterA-svc\",\"enabled\":true,\"network\":\"10.96.0.0/16\",\"metric\":9999,\"masquerade\":true,\"peer_groups\":[\"$GID_ROUTERS_A\"],\"groups\":[\"$GID_DEVOPS\"],\"keep_route\":true}"

# Route: clusterB's Service CIDR via routers-b, distributed to devops.
curl -fsS --cacert netbird/certs/rootCA.pem --resolve netbird.local:443:127.0.0.1 -H "Authorization: Token $PAT" -H "Content-Type: application/json" -X POST https://netbird.local/api/routes --data-raw "{\"description\":\"PoC route for clusterB-svc\",\"network_id\":\"clusterB-svc\",\"enabled\":true,\"network\":\"10.97.0.0/16\",\"metric\":9999,\"masquerade\":true,\"peer_groups\":[\"$GID_ROUTERS_B\"],\"groups\":[\"$GID_DEVOPS\"],\"keep_route\":true}"

# ACL policy: allow the devops group to reach both router groups.
curl -fsS --cacert netbird/certs/rootCA.pem --resolve netbird.local:443:127.0.0.1 -H "Authorization: Token $PAT" -H "Content-Type: application/json" -X POST https://netbird.local/api/policies --data-raw "{\"name\":\"devops-to-k8s\",\"description\":\"DevOps server to k8s routers\",\"enabled\":true,\"rules\":[{\"name\":\"devops-to-routers\",\"description\":\"allow devops to both clusters\",\"enabled\":true,\"action\":\"accept\",\"bidirectional\":true,\"protocol\":\"all\",\"sources\":[\"$GID_DEVOPS\"],\"destinations\":[\"$GID_ROUTERS_A\",\"$GID_ROUTERS_B\"]}]}"
```

**Why each field:**
- `network` — the destination CIDR this route covers.
- `peer_groups` — *which peers act as the gateway* for this CIDR (the routers).
- `groups` — *which peers receive/install the route* (the devops peer). This
  field is required and must be non-empty — omitting it is the classic 422.
- `masquerade: true` — the router rewrites the source IP to its own before
  forwarding into the cluster, so MariaDB's replies come back to the router
  (which then relays them over the mesh). Without this, the database would try
  to reply to a `100.80.x.x` mesh IP it has no route to.
- The **policy** is the zero-trust gate: even with a route installed, traffic is
  dropped unless an ACL explicitly permits `source group → destination group`.
  NetBird denies by default.

**Verify:**

```bash
curl -fsS --cacert netbird/certs/rootCA.pem --resolve netbird.local:443:127.0.0.1 \
  -H "Authorization: Token $PAT" https://netbird.local/api/routes | jq '.[].network'
```

---

## Step 9 — Build and run the DevOps container

Finally, the "client." We build an image with the NetBird agent + the MariaDB
client + our CA, then run it as a mesh peer in the `devops` group.

```bash
# Stage the CA into the build context (the Dockerfile COPYs ./rootCA.pem),
# build, then remove the staged copy so it doesn't linger.
cp netbird/certs/rootCA.pem devops-server/rootCA.pem
docker build -t netbird-poc/devops-server:latest devops-server
rm -f devops-server/rootCA.pem

# Run it as a mesh peer.
# (Re-detect HOST_IP in case you're in a fresh shell since Step 7.)
HOST_IP="${HOST_IP:-$(minikube -p clusterA ssh "grep host.minikube.internal /etc/hosts | awk '{print \$1}'" | tr -d '[:space:]\r')}"
docker rm -f devops-server 2>/dev/null || true
docker run -d \
  --name devops-server \
  --cap-add NET_ADMIN \
  --cap-add SYS_ADMIN \
  --device /dev/net/tun \
  --add-host netbird.local:${HOST_IP} \
  -e NB_SETUP_KEY="$(cat netbird/.keys/devops.key)" \
  -e NB_MANAGEMENT_URL="https://netbird.local" \
  -e NB_HOSTNAME="devops-server" \
  -e NETBIRD_DOMAIN="netbird.local" \
  netbird-poc/devops-server:latest
```

**Why the `docker run` flags:**
- `--cap-add NET_ADMIN` + `--device /dev/net/tun` — WireGuard needs to create a
  TUN network interface inside the container; these grant that ability.
- `--cap-add SYS_ADMIN` — lets the agent adjust routing/sysctls.
- `--add-host netbird.local:${HOST_IP}` — same trick as the routers'
  `hostAliases`: the container resolves the control-plane domain to the host.
- `NB_SETUP_KEY` (the devops key) auto-joins it to the `devops` group, which is
  exactly the group the routes were distributed to and the policy allows.

**Why it works even without trusting the CA on your Mac:** the agent trusts the
CA via the file baked into the image, not your macOS keychain.

**Verify mesh convergence (wait ~25s for routes to propagate):**

```bash
sleep 25
docker exec devops-server netbird status --detail
```

Look for both `10.96.0.0/16` and `10.97.0.0/16` with `Status: Selected`, and
both routing peers `Connected` (ideally `P2P`).

---

## Step 10 — Test connectivity (the payoff)

> **Critical:** MariaDB ClusterIPs are assigned **dynamically** by Kubernetes
> and **change every time you recreate the clusters** (e.g. after
> `make restart-handson`). Never hardcode them — always look them up live, as
> below. (This is why the real `test-connectivity.sh` discovers them at runtime
> rather than baking them in.)

### 10a. Capture the current ClusterIPs into a variable

```bash
DB_ENDPOINTS="$(for ns in ns1 ns2 ns3 ns6; do kubectl --context clusterA -n $ns get svc mariadb-client -o jsonpath="clusterA $ns {.spec.clusterIP}"$'\n'; done; for ns in ns4 ns5; do kubectl --context clusterB -n $ns get svc mariadb-client -o jsonpath="clusterB $ns {.spec.clusterIP}"$'\n'; done)"
echo "$DB_ENDPOINTS"
```

This prints something like (your IPs will differ):

```
clusterA ns1 10.96.27.99
clusterA ns2 10.96.115.107
clusterA ns3 10.96.119.254
clusterB ns4 10.97.85.240
clusterB ns5 10.97.158.52
```

### 10b. Loop over all five — TCP check + real SQL round-trip

```bash
echo "$DB_ENDPOINTS" | while read -r cluster ns ip; do
  printf "%-9s %-4s %-15s " "$cluster" "$ns" "$ip"
  if docker exec devops-server nc -z -w5 "$ip" 3306 2>/dev/null; then
    tcp=OK
  else
    tcp=FAIL
  fi
  sql="$(docker exec devops-server mariadb -h "$ip" -uroot -prootpass -N -B \
    -e "SELECT 'OK';" 2>/dev/null)"
  printf "TCP=%-5s SQL=%s\n" "$tcp" "${sql:-FAIL}"
done
```

Every row should read `TCP=OK SQL=OK`.

### 10c. A full write/read round-trip against one DB (pick any IP above)

```bash
# Replace with one of YOUR live IPs from 10a (do not reuse old-run IPs).
DB_IP=$(echo "$DB_ENDPOINTS" | head -1 | awk '{print $3}')
docker exec devops-server mariadb -h "$DB_IP" -uroot -prootpass appdb -e "CREATE TABLE IF NOT EXISTS hello(id INT AUTO_INCREMENT PRIMARY KEY, note VARCHAR(50)); INSERT INTO hello(note) VALUES('reached via netbird mesh'); SELECT * FROM hello;"
```

### 10d. Prove it's mesh-only (negative test)

Run the same check **from your Mac** (not inside the container). It should
fail/time out — no database port is bound on the host. The same IP that works
from inside the meshed container is unreachable from outside. That contrast
*is* the proof.

```bash
nc -zv -w5 "$DB_IP" 3306   # expected: fails / times out
```

> **Why the ClusterIP, not the DNS name?** Cross-mesh DNS resolution isn't
> configured in this PoC, so `mariadb-client.ns1.svc.cluster.local` won't
> resolve inside the DevOps container. The mesh routes by IP, and the ClusterIP
> is the stable, routable target inside the advertised CIDR.

> **Shortcut:** the bundled script does 10a–10b for you with no manual IP
> handling: `./scripts/test-connectivity.sh`


---

## Order-of-operations cheat sheet

| Order | Step | Depends on | Why |
|-------|------|-----------|-----|
| 0 | `/etc/hosts` | — | host resolves `netbird.local` |
| 1 | CA + cert | — | agents require valid TLS |
| 2 | secrets + render | 1 | config needs secrets |
| 3 | control plane up | 2 | the mesh brain |
| 4 | owner/PAT/groups/keys | 3 | API must be reachable |
| 5 | clusters up | — | (parallel to 1–4) |
| 6 | MariaDB | 5 | needs clusters |
| 7 | routers | 4, 5 | need setup keys + clusters |
| 8 | routes + ACL | **7** | route peer_groups need a live peer (else 422) |
| 9 | DevOps container | 4, 8 | needs devops key + routes to exist |
| 10 | test | 9 | needs ~25s convergence first |

---

## Teardown (manual)

```bash
docker rm -f devops-server
minikube delete --profile clusterA
minikube delete --profile clusterB
docker compose -f netbird/docker-compose.yml down -v

# Optional: remove generated secrets/certs (forces a fresh CA next time)
rm -rf netbird/.keys netbird/certs/*.pem netbird/certs/*.csr \
       netbird/certs/*.srl netbird/certs/*.ext \
       netbird/config.yaml netbird/dashboard.env \
       k8s/mariadb/.rendered k8s/netbird-router/.rendered

# Optional: drop the /etc/hosts line you added in Step 0
# sudo sed -i '' '/netbird.local/d' /etc/hosts
```

**Note:** if you delete the CA, any browser trust you set up for the old CA is
now stale — you'd re-trust the newly generated one next time.
