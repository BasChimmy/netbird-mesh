# ─────────────────────────────────────────────────────────────
# Bastion server image — NetBird routing peer that bridges the mesh
# to an isolated Docker network hosting MariaDB VMs.
#
# Contains: NetBird agent + iptables (masquerade) + self-signed CA.
# Requires NET_ADMIN + SYS_ADMIN capabilities at runtime.
# ─────────────────────────────────────────────────────────────
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        iproute2 \
        iputils-ping \
        iptables \
        jq \
    && rm -rf /var/lib/apt/lists/*

# Install the NetBird agent.
RUN curl -fsSL https://pkgs.netbird.io/install.sh | sh \
    && rm -rf /var/lib/apt/lists/*

# Trust the local self-signed CA.
COPY rootCA.pem /usr/local/share/ca-certificates/netbird-poc-ca.crt
RUN update-ca-certificates

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
