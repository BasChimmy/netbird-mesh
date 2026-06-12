# PoC: Bastion Server — NetBird Routing Peer to Isolated VMs

## Overview

This PoC demonstrates the **bastion/jump-server pattern** using NetBird mesh
networking. A DevOps server reaches MariaDB instances on isolated VMs **only**
through a bastion container that acts as a NetBird routing peer.

It proves:
1. ✅ **Connectivity** — `mysql -h` works from DevOps server to VMs via the mesh
2. ✅ **Isolation** — Without the NetBird route, VMs are completely unreachable
3. ✅ **Control** — Toggling a route via API instantly enables/disables access

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  Docker network: netbird (shared with management plane)          │
│                                                                  │
│  ┌──────────────────┐         ┌──────────────────────────────┐  │
│  │  devops-server    │◄─WG───►│  bastion                     │  │
│  │  (NetBird peer)   │        │  (NetBird routing peer)      │  │
│  │                   │        │                              │  │
│  │  mysql -h 10.99… │        │  Advertises 10.99.0.0/24    │  │
│  └──────────────────┘         │  IP forward + masquerade     │  │
│                                └──────────────┬───────────────┘  │
└───────────────────────────────────────────────┼──────────────────┘
                                                │
┌───────────────────────────────────────────────┼──────────────────┐
│  Docker network: bastion-vms (isolated, --internal)              │
│                                                │                  │
│                     ┌─────────────────────────┐│                  │
│                     │ bastion (10.99.0.10)    ││                  │
│                     └─────────────────────────┘│                  │
│                                                │                  │
│  ┌──────────────────┐         ┌──────────────────┐              │
│  │  vm-db-1          │         │  vm-db-2          │              │
│  │  10.99.0.11      │         │  10.99.0.12      │              │
│  │  MariaDB 11.4     │         │  MariaDB 11.4     │              │
│  └──────────────────┘         └──────────────────┘              │
└──────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- Shared NetBird management plane running (`make netbird-up` from repo root)
- Docker
- `curl`, `jq`
- ~4 GB available RAM

## Quick Start (automated)

```bash
# From this directory (poc/bastion-server/)
make up      # Bootstrap + build + start everything
make test    # Prove connectivity AND isolation
make down    # Tear down containers
make clean   # Tear down + remove NetBird API resources
```

## Manual Walkthrough (recommended for learning)

See **[HANDSON.md](HANDSON.md)** — a step-by-step guide that builds everything
using raw commands. Every step explains *what* and *why*.

## Files

```
├── docker-compose.yml     # Stack definition (2 networks, 4 services)
├── bastion/
│   ├── Dockerfile         # Ubuntu + NetBird + iptables
│   └── entrypoint.sh     # IP forward, masquerade, join mesh
├── devops-server/
│   ├── Dockerfile         # Ubuntu + NetBird + mariadb-client
│   └── entrypoint.sh     # Join mesh, idle
├── scripts/
│   ├── config.sh          # POC-specific configuration
│   ├── bootstrap.sh       # Create groups/keys/routes/policy via API
│   ├── up.sh             # Full orchestration
│   ├── test-connectivity.sh  # 3-phase connectivity + isolation test
│   └── teardown.sh       # Clean up
├── Makefile               # Convenience targets
├── HANDSON.md             # Step-by-step manual guide
└── README.md              # This file
```

## How It Works

1. The **bastion** container connects to both the `netbird` and `bastion-vms`
   Docker networks. It joins the NetBird mesh and is placed in the
   `bastion-routers` group.

2. A **network route** in NetBird tells all peers in the `devops-bastion` group:
   "To reach `10.99.0.0/24`, send traffic to a peer in `bastion-routers`."

3. The **DevOps server** receives this route. When it runs `mysql -h 10.99.0.11`,
   the kernel sees the WireGuard route and sends the packet through the encrypted
   tunnel to the bastion.

4. The **bastion** receives the packet, applies iptables masquerade (rewrites
   source to `10.99.0.10`), and forwards to the VM on the isolated network.

5. The VM replies to `10.99.0.10` (the bastion), which reverse-NATs and sends
   the response back through the WireGuard tunnel to the DevOps server.

## Cleanup

```bash
make clean   # Removes containers, volumes, networks, and NetBird API resources
```
