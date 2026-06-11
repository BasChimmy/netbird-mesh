# NetBird Control Plane (local, self-hosted)

Self-hosted NetBird control plane for the PoC, running fully locally on
`netbird.local` with a self-signed CA (no Let's Encrypt). Uses the modern
**combined** `netbird-server` image (management + signal + relay + STUN +
embedded Dex IdP) behind a Caddy reverse proxy that terminates TLS.

## Components

| Service          | Image                        | Role                                    |
|------------------|------------------------------|-----------------------------------------|
| `netbird-caddy`  | `caddy:2.8`                  | TLS termination + routing on 80/443     |
| `netbird-server` | `netbirdio/netbird-server`   | mgmt + signal + relay + STUN + IdP      |
| `netbird-dashboard` | `netbirdio/dashboard`     | Web UI                                  |

## Files

| File                  | Purpose                                              |
|-----------------------|------------------------------------------------------|
| `docker-compose.yml`  | Defines the 3 services + volumes + network           |
| `Caddyfile`           | TLS + gRPC(h2c)/HTTP routing per NetBird path prefixes|
| `config.yaml.tmpl`    | Combined-server config template (secrets injected)   |
| `dashboard.env.tmpl`  | Dashboard env template                               |
| `gen-certs.sh`        | Generates self-signed CA + server cert (with SANs)   |
| `netbird-up.sh`       | Renders config, generates secrets, starts the stack  |

Rendered `config.yaml`, `dashboard.env`, the `certs/*.pem`, and
`.keys/control-plane.secrets` are generated locally and git-ignored.

## Usage

```bash
# One-time: map the local domain (required by dashboard + agents)
echo '127.0.0.1 netbird.local' | sudo tee -a /etc/hosts

# Start / stop / logs
./netbird/netbird-up.sh            # generate secrets+certs, render, start
./netbird/netbird-up.sh --logs     # follow logs
./netbird/netbird-up.sh --down     # stop
```

### Trust the CA (so the browser accepts the dashboard)

macOS:

```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain netbird/certs/rootCA.pem
```

Then open https://netbird.local and log in with the initial admin
(default `admin@netbird.local` / `NetBirdAdmin1!`, override via
`ADMIN_EMAIL` / `ADMIN_PASSWORD` env vars).

## Verify (without trusting the CA system-wide)

```bash
curl --cacert netbird/certs/rootCA.pem \
  --resolve netbird.local:443:127.0.0.1 \
  https://netbird.local/oauth2/.well-known/openid-configuration
```

## Notes

- STUN (UDP 3478) is exposed directly; it cannot be proxied over HTTP.
- The combined server stores everything in SQLite under the
  `netbird_data` volume — fine for a single-node PoC.
- Agents (cluster routing peers, DevOps container) must trust
  `certs/rootCA.pem` to validate the management TLS connection.
