# Hands-On Walkthrough — Bastion Server PoC

This guide rebuilds the **entire** bastion-server PoC using raw commands only —
no `*.sh` scripts, no `make`. Every step explains *what* you run and *why*, so
you understand each moving part instead of treating the scripts as a black box.

> The scripts in this repo automate exactly these commands. This document is
> the "show your work" version.

**Run everything from the repo root:**

```bash
cd /path/to/netbird-mesh-poc
```

---

## The mental model (read this first)

We are building three things and wiring them together:

1. **A bastion container** — a NetBird routing peer that sits on two Docker
   networks: the shared `netbird` network (where the control plane and other
   peers live) and an isolated `bastion-vms` network (where MariaDB VMs live).
   It advertises "I can reach `10.99.0.0/24`" to the mesh.

2. **Two MariaDB "VM" containers** — on the isolated `bastion-vms` network
   with static IPs (`10.99.0.11`, `10.99.0.12`). They have **no** connection
   to the outside world.

3. **A DevOps server container** — a NetBird peer on the `netbird` network
   ONLY. It receives the bastion's route and can therefore `mysql -h 10.99.0.11`
   through an encrypted WireGuard tunnel via the bastion.

```
DevOps server ──WireGuard──> bastion (routing peer) ──> vm-db-1 (10.99.0.11)
   (netbird)                  (netbird + bastion-vms)   (bastion-vms only)
                                                    └──> vm-db-2 (10.99.0.12)
```

The **key insight**: the DevOps server has NO interface on `10.99.0.0/24`.
Traffic *must* flow through the NetBird mesh route via the bastion. If you
disable that route, the DevOps server loses all access to the VMs. This proves
the bastion is the sole gateway.

---

## Prerequisites

Before starting, ensure:
- The shared NetBird management plane is running (`make netbird-up` from root)
- The admin PAT exists at `netbird/.keys/admin.pat` (created by the initial
  `netbird/netbird-bootstrap.sh` run)
- Docker is running
- `curl`, `jq`, `openssl` are installed

Verify the control plane is healthy:

```bash
curl --cacert netbird/certs/rootCA.pem \
  --resolve netbird.local:443:127.0.0.1 \
  https://netbird.local/api/users \
  -H "Authorization: Token $(cat netbird/.keys/admin.pat)" | jq '.[0].email'
```

You should see `"admin@netbird.local"`.

---

## Step 1 — Create NetBird groups for this PoC

We need two groups:
- `bastion-routers` — the bastion peer joins this group. Routes are advertised
  by peers in this group.
- `devops-bastion` — the DevOps server joins this group. Routes are
  *distributed* to peers in this group (they receive the route table entries).

```bash
PAT="$(cat netbird/.keys/admin.pat)"
CA="netbird/certs/rootCA.pem"

# Helper: use an array so the command expands correctly in bash/zsh
CURL=(curl -fsS --cacert "$CA" --resolve netbird.local:443:127.0.0.1)

GID_BASTION="$("${CURL[@]}" -H "Authorization: Token $PAT" \
  -H "Content-Type: application/json" \
  -X POST https://netbird.local/api/groups \
  --data-raw '{"name":"bastion-routers"}' | jq -r '.id')"

echo "bastion-routers group ID: $GID_BASTION"

GID_DEVOPS="$("${CURL[@]}" -H "Authorization: Token $PAT" \
  -H "Content-Type: application/json" \
  -X POST https://netbird.local/api/groups \
  --data-raw '{"name":"devops-bastion"}' | jq -r '.id')"

echo "devops-bastion group ID: $GID_DEVOPS"
```

**Why two groups?** NetBird routes have two sides: `peer_groups` (who
advertises the route) and `groups` (who receives it). Separating them means
the DevOps server gets the route but doesn't try to *be* a router.

---

## Step 2 — Create setup keys

A setup key is an enrollment token. When a NetBird agent starts, it presents
the setup key to join the mesh and get placed into the associated group.

```bash
# Setup key for the bastion (valid 1 year, reusable, ephemeral peer)
BASTION_KEY="$("${CURL[@]}" -H "Authorization: Token $PAT" \
  -H "Content-Type: application/json" \
  -X POST https://netbird.local/api/setup-keys \
  --data-raw "{
    \"name\": \"bastion-server\",
    \"type\": \"reusable\",
    \"expires_in\": 31536000,
    \"auto_groups\": [\"$GID_BASTION\"],
    \"usage_limit\": 0,
    \"ephemeral\": true
  }" | jq -r '.key')"

echo "$BASTION_KEY" > netbird/.keys/bastion.key
chmod 600 netbird/.keys/bastion.key
echo "Bastion setup key saved"

# Setup key for the devops server
DEVOPS_KEY="$("${CURL[@]}" -H "Authorization: Token $PAT" \
  -H "Content-Type: application/json" \
  -X POST https://netbird.local/api/setup-keys \
  --data-raw "{
    \"name\": \"devops-bastion\",
    \"type\": \"reusable\",
    \"expires_in\": 31536000,
    \"auto_groups\": [\"$GID_DEVOPS\"],
    \"usage_limit\": 0,
    \"ephemeral\": true
  }" | jq -r '.key')"

echo "$DEVOPS_KEY" > netbird/.keys/devops-bastion.key
chmod 600 netbird/.keys/devops-bastion.key
echo "DevOps setup key saved"
```

**Why ephemeral?** Ephemeral peers are automatically removed from the mesh
when they disconnect for a configured period. Perfect for PoC containers that
get recreated frequently.

---

## Step 3 — Create the isolated Docker network

This is the private network the MariaDB VMs live on. The `--internal` flag
means Docker won't create a gateway to the host — no NAT, no internet access.

```bash
docker network create \
  --subnet 10.99.0.0/24 \
  --internal \
  bastion-vms
```

**Why `--internal`?** It proves true isolation. If we didn't use `--internal`,
Docker would add a route from the host to this subnet, which would defeat the
purpose of demonstrating that the NetBird mesh route is the *only* path.

**Verify:**

```bash
docker network inspect bastion-vms | jq '.[0].IPAM.Config[0].Subnet'
# Should output: "10.99.0.0/24"

docker network inspect bastion-vms | jq '.[0].Internal'
# Should output: true
```

---

## Step 4 — Start the MariaDB VM containers

These simulate VMs running a database service. They only connect to the
`bastion-vms` network.

```bash
docker run -d \
  --name vm-db-1 \
  --network bastion-vms \
  --ip 10.99.0.11 \
  -e MARIADB_ROOT_PASSWORD=rootpass \
  -e MARIADB_DATABASE=appdb \
  -e MARIADB_USER=appuser \
  -e MARIADB_PASSWORD=apppass \
  mariadb:11.4

docker run -d \
  --name vm-db-2 \
  --network bastion-vms \
  --ip 10.99.0.12 \
  -e MARIADB_ROOT_PASSWORD=rootpass \
  -e MARIADB_DATABASE=appdb \
  -e MARIADB_USER=appuser \
  -e MARIADB_PASSWORD=apppass \
  mariadb:11.4
```

**Why static IPs?** The NetBird route advertises a CIDR (`10.99.0.0/24`).
Within that range we need to know where each DB lives. In production this
would be DNS; here we use fixed IPs for simplicity.

**Verify (wait ~10s for MariaDB to initialize):**

```bash
docker exec vm-db-1 mariadb -u appuser -papppass -e "SELECT 'vm-db-1 alive'"
docker exec vm-db-2 mariadb -u appuser -papppass -e "SELECT 'vm-db-2 alive'"
```

---

## Step 5 — Build and start the bastion container

The bastion is the bridge: it joins the NetBird mesh AND connects to the
isolated VM network. It enables IP forwarding and masquerade so mesh traffic
destined for `10.99.0.0/24` gets delivered to the VMs.

### 5a. Prepare the build context

```bash
cd poc/bastion-server/bastion

# The Dockerfile expects rootCA.pem in the build context
cp ../../../netbird/certs/rootCA.pem ./rootCA.pem
```

### 5b. Review the Dockerfile

```dockerfile
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg iproute2 iputils-ping iptables jq \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://pkgs.netbird.io/install.sh | sh \
    && rm -rf /var/lib/apt/lists/*

COPY rootCA.pem /usr/local/share/ca-certificates/netbird-poc-ca.crt
RUN update-ca-certificates

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

**Why `iptables`?** The masquerade rule uses iptables NAT to rewrite the source
address of forwarded packets. Without it, the MariaDB VMs would see the DevOps
server's NetBird IP (100.64.x.x) as source and have no route back.

### 5c. Build

```bash
docker build -t bastion-poc:latest .
```

### 5d. Run the bastion (attach to both networks)

```bash
# Determine your host IP for /etc/hosts resolution inside the container.
# On Docker Desktop/Rancher Desktop: host-gateway resolves to the host.
HOST_IP="$(docker network inspect bridge | jq -r '.[0].IPAM.Config[0].Gateway')"

docker run -d \
  --name bastion \
  --network netbird \
  --cap-add NET_ADMIN \
  --cap-add SYS_ADMIN \
  --sysctl net.ipv4.ip_forward=1 \
  -e NB_SETUP_KEY="$(cat ../../../netbird/.keys/bastion.key)" \
  -e NB_MANAGEMENT_URL=https://netbird.local \
  -e NB_HOSTNAME=bastion-server \
  -e NETBIRD_HOST_IP="${HOST_IP}" \
  -e NETBIRD_DOMAIN=netbird.local \
  -e BASTION_VM_SUBNET=10.99.0.0/24 \
  bastion-poc:latest

# Attach the bastion to the isolated VM network too
docker network connect --ip 10.99.0.10 bastion-vms bastion
```

**Why two `--cap-add`?** `NET_ADMIN` allows creating the WireGuard tunnel
interface and managing routes/iptables. `SYS_ADMIN` is needed for the NetBird
agent to manage network namespaces on some Docker runtimes.

**Why `--sysctl net.ipv4.ip_forward=1`?** Without IP forwarding, the kernel
drops packets that arrive on one interface but are destined for another. The
bastion must forward mesh traffic → VM network.

**Verify:**

```bash
# Check NetBird joined
docker exec bastion netbird status
# Should show: "Connected"

# Check IP forwarding
docker exec bastion cat /proc/sys/net/ipv4/ip_forward
# Should output: 1

# Check masquerade rule
docker exec bastion iptables -t nat -L POSTROUTING -n -v
# Should show the MASQUERADE rule for 100.64.0.0/10 -> 10.99.0.0/24

# Check bastion can reach VMs
docker exec bastion ping -c 1 10.99.0.11
docker exec bastion ping -c 1 10.99.0.12
```

Go back to repo root:

```bash
cd ../../..
```

---

## Step 6 — Build and start the DevOps server

The DevOps server is a leaf peer — it only joins the mesh and receives routes.
It does NOT connect to the `bastion-vms` network.

### 6a. Prepare the build context

```bash
cd poc/bastion-server/devops-server
cp ../../../netbird/certs/rootCA.pem ./rootCA.pem
```

### 6b. Build

```bash
docker build -t devops-bastion-poc:latest .
```

### 6c. Run (netbird network only)

```bash
HOST_IP="$(docker network inspect bridge | jq -r '.[0].IPAM.Config[0].Gateway')"

docker run -d \
  --name devops-server \
  --network netbird \
  --cap-add NET_ADMIN \
  --cap-add SYS_ADMIN \
  -e NB_SETUP_KEY="$(cat ../../../netbird/.keys/devops-bastion.key)" \
  -e NB_MANAGEMENT_URL=https://netbird.local \
  -e NB_HOSTNAME=devops-bastion-poc \
  -e NETBIRD_HOST_IP="${HOST_IP}" \
  -e NETBIRD_DOMAIN=netbird.local \
  devops-bastion-poc:latest
```

**Verify:**

```bash
docker exec devops-server netbird status
# Should show: "Connected"

# Confirm it does NOT have a direct route to 10.99.0.0/24
docker exec devops-server ip route | grep 10.99
# Should show NOTHING (no direct route)
# The route will appear via NetBird's WireGuard interface ONLY after we create the mesh route
```

Go back to repo root:

```bash
cd ../../..
```

---

## Step 7 — Create the NetBird network route

Now we tell NetBird: "The peers in the `bastion-routers` group can route
traffic to `10.99.0.0/24`. Distribute this route to the `devops-bastion`
group."

```bash
PAT="$(cat netbird/.keys/admin.pat)"
CA="netbird/certs/rootCA.pem"
CURL=(curl -fsS --cacert "$CA" --resolve netbird.local:443:127.0.0.1)

ROUTE_RESP="$("${CURL[@]}" -H "Authorization: Token $PAT" \
  -H "Content-Type: application/json" \
  -X POST https://netbird.local/api/routes \
  --data-raw "{
    \"description\": \"Bastion PoC route to VM subnet\",
    \"network_id\": \"bastion-vms\",
    \"enabled\": true,
    \"network\": \"10.99.0.0/24\",
    \"metric\": 9999,
    \"masquerade\": true,
    \"peer_groups\": [\"$GID_BASTION\"],
    \"groups\": [\"$GID_DEVOPS\"],
    \"keep_route\": true
  }")"

ROUTE_ID="$(echo "$ROUTE_RESP" | jq -r '.id')"
echo "Route created: $ROUTE_ID"
echo "$ROUTE_ID" > netbird/.keys/bastion-route.id
```

**Key fields explained:**
- `network`: the CIDR being advertised (`10.99.0.0/24`)
- `peer_groups`: which peers are capable of routing this traffic (bastion)
- `groups`: which peers should receive this route (devops)
- `masquerade: true`: the bastion rewrites source IPs so VMs don't need a
  return route to the mesh
- `metric: 9999`: lowest priority (only one route here, doesn't matter)
- `keep_route: true`: keep routing even if no peer is "selected" as primary

**Why `masquerade`?** Without it, vm-db-1 would receive a MySQL connection from
`100.64.x.x` (the DevOps server's mesh IP). The VM has no route to that
network, so the reply packet would be dropped. Masquerade makes the bastion's
own `10.99.0.10` appear as the source, and the VM can reply directly.

---

## Step 8 — Create the ACL policy

NetBird blocks traffic between groups by default. We need an explicit policy
allowing the devops group to talk to the bastion-routers group.

```bash
"${CURL[@]}" -H "Authorization: Token $PAT" \
  -H "Content-Type: application/json" \
  -X POST https://netbird.local/api/policies \
  --data-raw "{
    \"name\": \"devops-to-bastion\",
    \"description\": \"Allow DevOps to reach bastion routers\",
    \"enabled\": true,
    \"rules\": [{
      \"name\": \"devops-to-bastion-rule\",
      \"description\": \"all traffic\",
      \"enabled\": true,
      \"action\": \"accept\",
      \"bidirectional\": true,
      \"protocol\": \"all\",
      \"sources\": [\"$GID_DEVOPS\"],
      \"destinations\": [\"$GID_BASTION\"]
    }]
  }" | jq '.name'
```

**Why bidirectional?** TCP requires both directions (SYN and SYN-ACK). Without
bidirectional, the bastion couldn't send response packets back through the mesh.

**Verify (wait ~5s for route propagation):**

```bash
sleep 5
docker exec devops-server ip route | grep 10.99
# Should now show a route via the wg (WireGuard) interface, e.g.:
# 10.99.0.0/24 dev wt0 scope link
```

---

## Step 9 — Create DNS aliases (friendly names for VMs)

Remembering IPs like `10.99.0.11` is painful. NetBird supports **Custom DNS
Zones** — you can create A records so peers resolve friendly names like
`vm-db-1.db.internal` instead of raw IPs.

### 9a. Create a custom DNS zone

```bash
ZONE_RESP="$("${CURL[@]}" -H "Authorization: Token $PAT" \
  -H "Content-Type: application/json" \
  -X POST https://netbird.local/api/dns/zones \
  --data-raw "{
    \"name\": \"Bastion VMs\",
    \"domain\": \"db.internal\",
    \"enable_search_domain\": true,
    \"distribution_groups\": [\"$GID_DEVOPS\"]
  }")"

ZONE_ID="$(echo "$ZONE_RESP" | jq -r '.id')"
echo "DNS Zone created: $ZONE_ID (db.internal)"
```

**Why `enable_search_domain: true`?** It adds `db.internal` to the peer's DNS
search list. This means you can query just `vm-db-1` instead of the full
`vm-db-1.db.internal`.

### 9b. Add A records for each VM

```bash
"${CURL[@]}" -H "Authorization: Token $PAT" \
  -H "Content-Type: application/json" \
  -X POST "https://netbird.local/api/dns/zones/$ZONE_ID/records" \
  --data-raw '{
    "name": "vm-db-1.db.internal",
    "type": "A",
    "content": "10.99.0.11",
    "ttl": 300
  }' | jq '{name, type, content}'

"${CURL[@]}" -H "Authorization: Token $PAT" \
  -H "Content-Type: application/json" \
  -X POST "https://netbird.local/api/dns/zones/$ZONE_ID/records" \
  --data-raw '{
    "name": "vm-db-2.db.internal",
    "type": "A",
    "content": "10.99.0.12",
    "ttl": 300
  }' | jq '{name, type, content}'
```

**Why A records?** These map hostnames to IPv4 addresses. When the DevOps
server queries `vm-db-1.db.internal`, NetBird's local DNS resolver returns
`10.99.0.11` — then the routing table sends traffic through the bastion.

### 9c. Verify DNS resolution (wait ~5s for propagation)

```bash
sleep 5
docker exec devops-server nslookup vm-db-1.db.internal
# Should resolve to 10.99.0.11

docker exec devops-server nslookup vm-db-2.db.internal
# Should resolve to 10.99.0.12
```

Now you can use friendly names:

```bash
docker exec devops-server mysql -h vm-db-1.db.internal \
  -u appuser -papppass --connect-timeout=10 \
  -e "SELECT 'Connected via DNS alias!' AS message"
```

---

## Step 10 — Test connectivity: mysql -h from DevOps to VMs

This is the moment of truth. The DevOps server should be able to reach the
MariaDB VMs through the NetBird mesh → bastion → VM subnet path.

```bash
docker exec devops-server mysql -h 10.99.0.11 \
  -u appuser -papppass \
  --connect-timeout=10 \
  -e "SELECT 'Hello from vm-db-1' AS message"

docker exec devops-server mysql -h 10.99.0.12 \
  -u appuser -papppass \
  --connect-timeout=10 \
  -e "SELECT 'Hello from vm-db-2' AS message"
```

✅ If both return results, the bastion routing pattern **works**. Traffic flows:

```
devops-server → WireGuard tunnel → bastion → 10.99.0.0/24 → vm-db-1/2
```

You can also use the DNS aliases from Step 9:

```bash
docker exec devops-server mysql -h vm-db-1.db.internal -u appuser -papppass -e "SELECT 'via DNS!' AS msg"
docker exec devops-server mysql -h vm-db-2.db.internal -u appuser -papppass -e "SELECT 'via DNS!' AS msg"
```

---

## Step 11 — Prove isolation: disable the route

Now we prove the DevOps server *cannot* reach the VMs without the bastion
route. This is the most important validation — it shows the VMs are truly
isolated.

### 10a. Disable the route via the API

```bash
ROUTE_ID="$(cat netbird/.keys/bastion-route.id)"

# Get the full route object
ROUTE_JSON="$("${CURL[@]}" -H "Authorization: Token $PAT" \
  https://netbird.local/api/routes/$ROUTE_ID)"

# Set enabled=false — only send writable fields (API rejects read-only ones)
echo "$ROUTE_JSON" | jq '{
  description, network_id, enabled: false, network, metric,
  masquerade, peer_groups, groups, keep_route
}' | \
  "${CURL[@]}" -H "Authorization: Token $PAT" \
    -H "Content-Type: application/json" \
    -X PUT "https://netbird.local/api/routes/$ROUTE_ID" \
    -d @- > /dev/null

echo "Route disabled"
```

### 10b. Wait for route withdrawal (~8s)

```bash
sleep 8
```

**Why wait?** The NetBird agent polls for configuration changes. It takes a few
seconds for the route to be withdrawn from the DevOps server's routing table.

### 10c. Try mysql again (should FAIL)

```bash
docker exec devops-server mysql -h 10.99.0.11 \
  -u appuser -papppass \
  --connect-timeout=5 \
  -e "SELECT 1" 2>&1 || echo "EXPECTED: Connection failed (isolation confirmed)"
```

✅ If the connection **times out or is refused**, isolation is confirmed. The
DevOps server has no path to `10.99.0.0/24` without the mesh route.

**Verify the route is gone:**

```bash
docker exec devops-server ip route | grep 10.99
# Should show NOTHING — the WireGuard route was removed
```

---

## Step 12 — Restore the route

```bash
echo "$ROUTE_JSON" | jq '{
  description, network_id, enabled: true, network, metric,
  masquerade, peer_groups, groups, keep_route
}' | \
  "${CURL[@]}" -H "Authorization: Token $PAT" \
    -H "Content-Type: application/json" \
    -X PUT "https://netbird.local/api/routes/$ROUTE_ID" \
    -d @- > /dev/null

echo "Route re-enabled"
sleep 8

# Verify connectivity is back
docker exec devops-server mysql -h 10.99.0.11 \
  -u appuser -papppass \
  --connect-timeout=10 \
  -e "SELECT 'Route restored — vm-db-1 reachable again' AS message"
```

✅ Connectivity should be restored, proving the route is the sole control point.

---

## Step 13 — Cleanup

When you're done exploring, tear everything down:

```bash
# Stop and remove containers
docker rm -f devops-server bastion vm-db-1 vm-db-2

# Remove the isolated network
docker network rm bastion-vms

# (Optional) Remove NetBird resources via API
ROUTE_ID="$(cat netbird/.keys/bastion-route.id)"
"${CURL[@]}" -H "Authorization: Token $PAT" -X DELETE "https://netbird.local/api/routes/$ROUTE_ID"

# Find and delete the policy
POLICY_ID="$("${CURL[@]}" -H "Authorization: Token $PAT" https://netbird.local/api/policies | jq -r '.[] | select(.name=="devops-to-bastion") | .id')"
"${CURL[@]}" -H "Authorization: Token $PAT" -X DELETE "https://netbird.local/api/policies/$POLICY_ID"

# Find and delete the DNS zone
ZONE_ID="$("${CURL[@]}" -H "Authorization: Token $PAT" https://netbird.local/api/dns/zones | jq -r '.[] | select(.domain=="db.internal") | .id')"
[[ -n "$ZONE_ID" ]] && "${CURL[@]}" -H "Authorization: Token $PAT" -X DELETE "https://netbird.local/api/dns/zones/$ZONE_ID"

# Remove key files
rm -f netbird/.keys/bastion.key netbird/.keys/devops-bastion.key
rm -f netbird/.keys/bastion-route.id netbird/.keys/bastion-bootstrap.state

# Remove staged CA copies
rm -f poc/bastion-server/bastion/rootCA.pem
rm -f poc/bastion-server/devops-server/rootCA.pem
```

---

## What you proved

By completing this walkthrough you demonstrated:

1. **Routing peer pattern** — A single bastion container bridges two networks
   by joining the NetBird mesh and advertising a route.
2. **True network isolation** — The MariaDB VMs are on a Docker-internal
   network with no external route. The DevOps server cannot reach them
   directly.
3. **Mesh-controlled access** — Connectivity is enabled/disabled purely by
   toggling a NetBird route via API. No firewall rules, no network
   reconfiguration.
4. **Masquerade** — The bastion rewrites source addresses so VMs don't need
   mesh awareness or return routes.

This pattern maps directly to production: replace Docker containers with actual
VMs/servers, replace `10.99.0.0/24` with your private network CIDR, and the
architecture works identically.
