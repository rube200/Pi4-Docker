# Pi4-Docker

Docker Compose stack for a home server: **Unbound** (recursive DNS), **Pi-hole** (filtering and DHCP helper), **DNS-over-HTTPS** ([doh-server](https://github.com/DNSCrypt/doh-server)), **Nginx** (reverse proxy, TLS, DoH/DoT front ends), and **WireGuard**. Optional **systemd** unit and **shell scripts** automate firewall rules, certificate renewal hooks, and Pi-hole TLS refresh. **Hostinger is entirely optional:** omit `DNS_API` and skip the Hostinger sections if you use another DNS provider or static records.

**License:** GNU General Public License v3.0 — see [LICENSE](LICENSE).

**Repository:** https://github.com/rube200/Pi4-Docker

## Support and disclaimer

This repository is **reference configuration** for self-hosting: **no warranty**, **not a security audit**, and **not a supported product**. Operators are responsible for updates, firewall posture, and exposure to the internet. Issues and pull requests are welcome; response time is **best effort** only.

## Trademarks

This project may reference or display logos for **Pi-hole**, **Home Assistant**, **Kodi**, and similar projects. Those marks belong to their respective owners. This project is **not** affiliated with or endorsed by them.

## Requirements

- **Docker** and **Docker Compose** plugin (`docker compose`).
- **Linux** host with kernel support for WireGuard and iptables/nftables as used by the containers.
- **Privileged / capabilities** as defined in `docker-compose.yaml` (e.g. `NET_ADMIN` for Pi-hole, WireGuard, DHCP relay).
- **Persistent host paths** (bind mounts): `/etc/pihole`, `/etc/letsencrypt`, `/var/www/certbot`, `/etc/wireguard`, `/lib/modules` (read-only for WireGuard).

### Network and ports (host → container)

These are the **published** mappings from [docker-compose.yaml](docker-compose.yaml): `host:container` on the Docker host. **Publishing in Compose only binds ports on the host; it does not mean every published port must be reachable from the public internet.** Use your **host firewall** and **router port forwarding** to match your threat model.

**Exposure patterns (pick what matches you):**

- **LAN-only services:** Many operators keep **Pi-hole admin (44353)** and optional **direct Unbound (5335)** / **DoH backend (3000)** off WAN; clients use **53** only on trusted networks unless you intentionally offer a public resolver.
- **Full public edge (reference setup for this repo):** WireGuard **plus** **DNS (53)**, **HTTP/HTTPS (80, 443)**, **DoT (853)**, and **DoH (440)** on the WAN. That is a valid design if you want remote DNS and a public web presence behind the same host; it also **widens your attack surface**—keep the host patched, rate-limit where you can, and restrict Pi-hole / admin paths if needed.

| Host port | Proto | Service | Role |
|-----------|-------|---------|------|
| **53** | TCP, UDP | Pi-hole | Standard DNS (DHCP clients and LAN resolvers use this). |
| **44353** | TCP | Pi-hole | Pi-hole web UI and API over **HTTPS** (nginx proxies `https://…/admin` here). |
| **80** | TCP | Nginx | HTTP (redirect / ACME challenge as configured). |
| **443** | TCP | Nginx | HTTPS for the main site and vhosts (see `nginx/templates/`). |
| **440** | TCP | Nginx → DoH | **DNS-over-HTTPS** TLS endpoint; nginx forwards to the `doh` service. Keep **`DOH_PUBLIC_PORT`** in `.env` aligned with this (default `440`). |
| **853** | TCP | Nginx → Pi-hole | **DNS-over-TLS** (stream proxy to Pi-hole’s DNS on the bridge). |
| **51820** | UDP | WireGuard | VPN listen port inside the container (default **ListenPort** in WireGuard config). |
| **5335** | TCP, UDP | Unbound | Optional **direct** Unbound on the host (Pi-hole normally uses Unbound on the **internal** Docker network). Often **LAN-only**; expose on WAN only if you intend to run a public resolver. |
| **3000** | TCP | DoH container | `doh-proxy` listens here; in normal use **clients hit port 440** on nginx. **WAN clients should use 440** (TLS front); **3000** is optional for debugging or internal-only publishing. |

**Firewall: UDP 182 → 51820 (optional):** [extra-script/nftables.conf](extra-script/nftables.conf) includes **`udp dport 182 redirect to :51820`** in `table inet nat` so WireGuard can be reached on **port 182** on the host while the container still listens on **51820**. Typical reasons: **ISP or upstream filtering** of “non-standard” high ports, **obfuscation** of the obvious `51820/udp` port on scans, or **port forwarding** from a router that only allows certain inbound ports. If you use this redirect, set client **`Endpoint = your.host:182`** (or forward **182** from the router to the host’s **182**); the stack still maps **`51820:51820`** in Compose, so both ports can work on the host depending on your rules.

**Conflicts:** If something else on the host already binds **53** (systemd-resolved, another DNS, etc.), Pi-hole’s publish will fail until that is moved or disabled. **DHCP relay** uses `network_mode: host`; it does not add extra compose `ports:` lines but still participates in broadcast DHCP on the host network stack.

**Architecture note:** The DoH image downloads `doh-proxy` for **x86_64** or **aarch64** only; 32-bit ARM is not supported (see `doh-docker/docker-entrypoint.sh`).

## Quick start

1. Clone the repository and enter the directory.

2. Copy the environment template and edit it:

   ```bash
   cp .env.example .env
   ```

3. Set at least `SERVER_HOSTNAME` and `PIHOLE_LAN_IP` in `.env`. See [.env.example](.env.example) for all variables.

4. Ensure host directories exist and permissions match your setup for Pi-hole, WireGuard, and Certbot paths above.

5. Start the stack:

   ```bash
   docker compose up -d
   ```

## Configuration

- **Compose file:** [docker-compose.yaml](docker-compose.yaml) — service graph, fixed bridge network `172.28.0.0/16`, healthchecks, and image tags.
- **Environment:** [.env.example](.env.example) — copy to `.env` (never commit `.env`).
- **Nginx:** `nginx/` — templates under `nginx/templates/` (processed at container start), static site under `nginx/html/`. Optional subdomain reverse-proxy samples live under `nginx/examples/` (copy into `nginx/templates/` as `*.conf.template` and rebuild; they are not loaded until you do).

### Landing page: Home Assistant and Kodi (not ready by default)

**Home Assistant and Kodi are placeholders only** in this repository: the compose stack does **not** run those apps, and **no** nginx vhosts for `home-assistant.*` or `kodi.*` are enabled until you add your own `*.conf.template` (see `nginx/examples/`) and something listening behind `proxy_pass`. The landing page tiles stay **disabled** until those subdomains respond. **Pi-hole** is the dashboard wired for typical use once DNS and TLS are in place.

- **WireGuard:** `wireguard-docker/` — server config template; keys can be generated at container start (see `docker-entrypoint.sh`).
- **Extra automation:** `extra-script/` — optional **Hostinger** DNS helpers (`DNS_API`), Certbot DNS hook, firewall, Pi-hole TLS renewal. **You do not need Hostinger** to run the stack; see below.

## Hostinger DNS and API setup (optional)

**Hostinger integration is optional.** The core stack (Unbound, Pi-hole, DoH, Nginx, WireGuard) runs without it. Use this section only if your domain’s DNS is on Hostinger and you want **dynamic DNS** and/or **DNS-01** hooks that call their API.

The scripts talk to Hostinger’s **public DNS API** at `https://developers.hostinger.com` using a **Bearer token**. They are written for a domain whose **DNS zone is managed in Hostinger** (same account as the token).

### 1. Create an API token

1. Log in to [Hostinger hPanel](https://hpanel.hostinger.com/).
2. Open the **API** section (hPanel sidebar; search for “API” if needed).
3. **Generate a new token**, name it, set an expiry if you want, then **copy the token once** and store it safely.

Official overview: [What is Hostinger API?](https://support.hostinger.com/en/articles/10840865-what-is-hostinger-public-api)

### 2. Configure `.env`

- **`SERVER_HOSTNAME`** — required for the stack (TLS, DoH, Pi-hole web domain, etc.); set to your public **FQDN** or apex as you use it in nginx/Pi-hole.
- **`DNS_API`** — **omit this entirely** if you are not using Hostinger (or leave it unset). Add it **only** when you want the Hostinger scripts or Certbot DNS hook below.

If you use Hostinger automation:

- **`SERVER_HOSTNAME`** must match the **DNS zone name** in Hostinger (e.g. `example.com`) so `/api/dns/v1/zones/${SERVER_HOSTNAME}` is correct.
- **`DNS_API`** is your Hostinger API token.

```bash
SERVER_HOSTNAME=example.com
# Optional — only for Hostinger scripts / DNS-01 hook:
# DNS_API=your_hostinger_api_token_here
```

`docker-compose.yaml` passes `DNS_API` into the **nginx** container when set, so optional tooling inside that container can read it.

### 3. Dynamic DNS (public IPv4 → `@` and `*` A records)

Script: [extra-script/update-dns-record-hostinger.sh](extra-script/update-dns-record-hostinger.sh).

- If **`DNS_API` is unset**, the script **exits successfully** and does nothing (safe for hosts without Hostinger).
- If set, it detects the host’s public IPv4, reads the zone from the API, then **creates or updates** **`A` records for `@` and `*`** to that IP (TTL 3600).

**Requirements:** `SERVER_HOSTNAME` set; domain’s DNS must be manageable via that Hostinger API (token needs permission to read/update that zone).

**Optional automation:** [services-docker.service](services-docker.service) runs this script as **`ExecStartPre`** before `docker compose up -d`, so each boot can refresh DNS before services start.

### 4. ACME DNS-01 (Let’s Encrypt TXT via Hostinger)

**Optional.** Only if you issue certificates with Certbot and want **DNS-01** through Hostinger. Other CA methods (HTTP-01, another DNS provider, manual certs) do not need this script.

Script: [extra-script/certbot-hook-dns.sh](extra-script/certbot-hook-dns.sh).

- Implements Certbot **manual** hooks: `auth` creates `_acme-challenge.<domain>` **TXT** records; `cleanup` removes them.
- **`DNS_API` is required** (script exits with an error if missing).
- Certbot sets **`CERTBOT_DOMAIN`** and **`CERTBOT_VALIDATION`**`; the hook waits and checks public DNS (Google / Cloudflare DNS-over-HTTPS) until the TXT is visible.

**Example — first certificate** (run on a host that has `certbot`, `curl`, and this repo; export `DNS_API` or source `.env`):

```bash
export DNS_API="your_hostinger_api_token_here"

certbot certonly \
  --manual \
  --preferred-challenges dns \
  --manual-auth-hook "/absolute/path/to/Pi4-Docker/extra-script/certbot-hook-dns.sh auth" \
  --manual-cleanup-hook "/absolute/path/to/Pi4-Docker/extra-script/certbot-hook-dns.sh cleanup" \
  -d "example.com" \
  -d "*.example.com"
```

Use your real install path instead of `/absolute/path/to/Pi4-Docker`. For **renewal**, keep the same hooks in the certificate’s renewal configuration (under `/etc/letsencrypt/renewal/`) so `certbot renew` continues to use DNS-01.

**Note:** [nginx/docker-entrypoint.sh](nginx/docker-entrypoint.sh) runs **`certbot renew`** and copies certs from `/etc/letsencrypt/live/<hostname>/` into the container. Initial issuance and hook wiring are still **your** responsibility on the host (or another environment) before those paths exist.

### 5. Troubleshooting

- **HTTP errors from Hostinger:** wrong token, token without DNS access, or **`SERVER_HOSTNAME` not matching** the zone name in Hostinger.
- **Certbot TXT “not visible”:** nameservers for the domain must point at Hostinger’s DNS for the API-written records to be what the public internet resolves; propagation can take a few minutes.

## Optional systemd service

[services-docker.service](services-docker.service) assumes the project lives at **`/opt/Pi4-Docker`** and loads **`/opt/Pi4-Docker/.env`**. To use it elsewhere, either:

- Copy or symlink the repo to that path, **or**
- Edit `WorkingDirectory=`, `EnvironmentFile=`, and every `ExecStartPre=` / `ExecStart=` path in the unit file to match your install, then install the unit under `/etc/systemd/system/` and run `systemctl daemon-reload`.

## Security

This stack exposes DNS and VPN surfaces to your network and possibly the internet, depending on your firewall and port forwarding. Review `extra-script/firewall-rules.sh` and your host firewall. If you set **`DNS_API`**, treat it like any other **secret** (Hostinger token). WireGuard keys are secrets too. Do not commit `.env`.

To **report a vulnerability in this project** (this repo’s compose, scripts, or shipped integration defaults), follow [SECURITY.md](SECURITY.md).

## Image versions

Published images and base images are **pinned to specific tags** in `docker-compose.yaml` and Dockerfiles so builds are reproducible. Upgrade deliberately (check upstream release notes), then update tags and test.

To confirm what is newest on Docker Hub, use each image’s tags API (for example `https://hub.docker.com/v2/repositories/pihole/pihole/tags?ordering=last_updated`) or the Hub UI. **Pi-hole:** the highest `YYYY.MM.N` tag on Hub is currently the same image as `latest` (same digest). **Nginx:** the highest `X.Y.Z-alpine-slim` tag can trail `mainline-alpine-slim`; when they match digest, the semver tag is still “current mainline.”

## Contributing

Contributions are welcome under GPLv3. There is no separate contributor agreement; by contributing you agree your work is licensed under the same terms as this repository.
