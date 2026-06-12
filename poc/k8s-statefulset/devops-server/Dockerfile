# ─────────────────────────────────────────────────────────────
# DevOps server image — simulates an operator workstation/server that
# joins the NetBird mesh and reaches MariaDB across both clusters.
#
# Contains: NetBird agent + MariaDB client + the local self-signed CA.
# ─────────────────────────────────────────────────────────────
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Base tools + MariaDB client + deps for the NetBird install script.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        iproute2 \
        iputils-ping \
        netcat-openbsd \
        jq \
        mariadb-client \
    && rm -rf /var/lib/apt/lists/*

# Install the NetBird agent from the official install script.
RUN curl -fsSL https://pkgs.netbird.io/install.sh | sh \
    && rm -rf /var/lib/apt/lists/*

# Trust the local self-signed CA (copied in at build time) so the agent
# and tooling validate the management TLS connection to netbird.local.
COPY rootCA.pem /usr/local/share/ca-certificates/netbird-poc-ca.crt
RUN update-ca-certificates

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
