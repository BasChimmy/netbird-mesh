# NetBird Mesh PoC — Multi-Case Learning Lab

This repository contains multiple Proof-of-Concept cases demonstrating NetBird mesh networking patterns. Each POC is self-contained under `poc/` and shares a single NetBird management plane.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Shared NetBird Management Plane (netbird/)         │
│  caddy + netbird-server + dashboard                 │
│  https://netbird.local                              │
└──────────────────────────┬──────────────────────────┘
                           │
          ┌────────────────┼────────────────┐
          ▼                                 ▼
┌─────────────────────┐          ┌─────────────────────┐
│ poc/k8s-statefulset  │          │ poc/bastion-server   │
│                      │          │                      │
│ 2 minikube clusters  │          │ bastion routing peer │
│ 5 MariaDB namespaces │          │ 2 isolated MariaDB   │
│ routing peers in k8s │          │ VMs on Docker net    │
└─────────────────────┘          └─────────────────────┘
```

## PoC Cases

| Case | Description | Approach |
|------|-------------|----------|
| [k8s-statefulset](poc/k8s-statefulset/) | Cross-cluster MariaDB access via NetBird routing peers in Kubernetes | 2 minikube clusters, StatefulSets, routing peer pods |
| [bastion-server](poc/bastion-server/) | Bastion jump-server pattern — devops reaches isolated VMs only through a NetBird routing peer | Docker containers, isolated network, proves connectivity + isolation |

## Prerequisites

- macOS or Linux
- Docker (Docker Desktop / Rancher Desktop / Colima)
- `curl`, `jq`, `openssl`
- For k8s-statefulset: `minikube`, `kubectl`
- ~8 GB RAM for bastion-server, ~16 GB for k8s-statefulset

## Quick Start

```bash
# 1. One-time host setup
echo '127.0.0.1 netbird.local' | sudo tee -a /etc/hosts

# 2. Start the shared NetBird management plane
make netbird-up

# 3. Run a specific PoC case
cd poc/bastion-server && make up && make test
```

## Repository Layout

```
├── netbird/                  # Shared: management server, certs, bootstrap
├── scripts/                  # Shared: config.sh, preflight, teardown
├── Makefile                  # Top-level targets
├── poc/
│   ├── k8s-statefulset/      # PoC 1
│   │   ├── HANDSON.md        # Step-by-step manual guide
│   │   └── ...
│   └── bastion-server/       # PoC 2
│       ├── HANDSON.md        # Step-by-step manual guide
│       └── ...
└── README.md                 # This file
```

## Global Commands

```bash
make help           # Show available targets
make netbird-up     # Start the shared control plane
make netbird-down   # Stop the shared control plane
make teardown-all   # Tear down everything
```

## Learning Approach

Each PoC includes a `HANDSON.md` that walks you through **every command manually** — no scripts, no black boxes. The automation scripts exist for convenience, but the hands-on guide is the primary learning path.
