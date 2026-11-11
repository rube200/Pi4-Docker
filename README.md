# Pi4-Docker

Docker Compose stack for a home server on a Raspberry Pi 4:

- **Unbound**: caching, DNSSEC-validating forwarder to Quad9 over DNS-over-TLS.
- **Pi-hole**: DNS filtering and the LAN’s DHCP server.
- **DHCP relays** (IPv4 and IPv6), so Pi-hole on the Docker network can serve the LAN.
- **DNS-over-HTTPS** and **Oblivious DoH** ([doh-server](https://github.com/DNSCrypt/doh-server)).
- **nginx**: reverse proxy, TLS, and the DoH and DNS-over-TLS front ends.
- **WireGuard**: VPN for remote devices.

Every service runs on both IPv4 and IPv6. A **systemd** unit and **host scripts** apply the firewall, update DNS records, renew certificates, and refresh Pi-hole’s TLS certificate. **Hostinger is entirely optional:** omit `DNS_API` and skip [Hostinger DNS](#hostinger-dns-optional) if you use another DNS provider or static records.

**License:** GNU General Public License v3.0 — see [LICENSE](LICENSE).

**Repository:** https://github.com/rube200/Pi4-Docker

## Contents

1. [Overview](#overview)
2. [Requirements](#requirements)
3. [Quick start](#quick-start)
4. [Configuration](#configuration)
5. [Network and ports](#network-and-ports)
6. [Firewall and rate limits](#firewall-and-rate-limits)
7. [WireGuard](#wireguard)
8. [Certificates](#certificates)
9. [Hostinger DNS (optional)](#hostinger-dns-optional)
10. [systemd service](#systemd-service)
11. [Maintenance](#maintenance)
12. [Troubleshooting](#troubleshooting)
13. [Security](#security)
14. [Support and disclaimer](#support-and-disclaimer)

## Overview

![How clients reach each service, and the ports between them](docs/overview.svg)

### Services

Every container has a fixed address on the Docker network `services_network` (`172.28.0.0/16` / `fd28::/64`), and the IPv6 one mirrors the IPv4 one. The DHCP relays use the host’s network instead.

| Container | IPv4 | IPv6 | Role |
|-----------|------|------|------|
| (the host) | `172.28.0.1` | `fd28::1` | Docker gateway: containers reach the Pi’s own services here. |
| `unbound` | `172.28.0.2` | `fd28::2` | Resolver on **5335**, forwarding to Quad9 over DoT; Pi-hole’s only upstream. |
| `pihole` | `172.28.0.3` | `fd28::3` | DNS filtering on **53**, DHCP server, web interface on **44353** (behind nginx). |
| `doh` | `172.28.0.4` | `fd28::4` | doh-proxy on **3000**: DNS-over-HTTPS and Oblivious DoH, forwarding to Pi-hole. |
| `wireguard` | `172.28.0.5` | `fd28::5` | VPN server on **51820**/UDP. |
| `nginx` | `172.28.0.6` | `fd28::6` | Websites, the Pi-hole web interface, the DoH front end and DoT, all over TLS. |
| `dhcp-relay`, `dhcpv6-relay` | host network | host network | Relay LAN DHCPv4 / DHCPv6 requests to Pi-hole. |

Compose starts Unbound first, then Pi-hole, and the rest once Pi-hole is healthy. Pi-hole does not wait for Unbound to be healthy, so the LAN keeps DHCP and local names while there is no internet.

### Repository layout

| Path | Contents |
|------|----------|
| [docker-compose.yaml](docker-compose.yaml) | Service graph, the dual-stack bridge network, healthchecks and image tags. |
| [.env.example](.env.example) | Every setting you can change; copy it to `.env` (never commit `.env`). |
| [unbound-docker/](unbound-docker/), [doh-docker/](doh-docker/), [dhcp-relay-docker/](dhcp-relay-docker/), [nginx-docker/](nginx-docker/), [wireguard-docker/](wireguard-docker/) | The locally built images (Pi-hole uses the published image). |
| [host-scripts/](host-scripts/) | Firewall, certificate renewal, Pi-hole TLS renewal, and the optional Hostinger DNS helpers. |
| [services-docker.service](services-docker.service) | systemd unit that runs the host scripts and starts the stack at boot. |
| [docs/](docs/) | The overview diagram (SVG, follows the light or dark theme). |

## Requirements

- **Docker Engine 27 or later** and the **Docker Compose** plugin (`docker compose`), with Docker’s IPv6 NAT enabled (`"ip6tables": true` in `/etc/docker/daemon.json`, the default since Docker 27; older engines only offer it as an experimental feature). Debian’s own `docker.io` package is older in both bookworm and trixie; install from [Docker’s own repository](https://docs.docker.com/engine/install/debian/).
- **Linux** host with kernel support for WireGuard, iptables and nftables. The kernel loads the `wireguard` module itself when the container creates its interface; if `wg-quick` fails with “Unknown device type”, load it at boot with `echo wireguard | sudo tee /etc/modules-load.d/wireguard.conf`. The DoH image only supports **x86_64** and **aarch64** (64-bit Raspberry Pi OS on a Pi 4).
- **IPv4 and IPv6 on the LAN.** IPv6 is not optional: the Pi needs a global IPv6 address on `HOST_LAN_IFACE`, and `HOST_LAN_IP6` must be set. Docker turns on IPv6 forwarding, and a forwarding host ignores Router Advertisements unless `net.ipv6.conf.<iface>.accept_ra=2` is set (persist it under `/etc/sysctl.d/`).
- **Socket buffer for Unbound:** `net.core.rmem_max=1048576` on the host (persist it under `/etc/sysctl.d/`). The container cannot raise the limit itself, so without it Unbound does not get the 1 MB receive buffer (`so-rcvbuf`) its config asks for.
- **Capabilities** as defined in `docker-compose.yaml`: `NET_ADMIN` for Pi-hole, WireGuard and the DHCP relays, `SYS_NICE` for Pi-hole. Unbound, doh, WireGuard and nginx drop `NET_RAW`, so they cannot forge traffic on the Docker network, and doh-proxy runs as `nobody`. Every container except Pi-hole runs with `no-new-privileges`. No container runs privileged or can load kernel modules.
- **Persistent host paths** (bind mounts): `/etc/pihole`, `/etc/letsencrypt/live`, `/etc/letsencrypt/archive` and `/var/www/certbot` (read-only for nginx, which never sees the ACME account key), `/etc/wireguard`.
- **Host tools** for the scripts in [host-scripts/](host-scripts/): `nft`, for TLS `certbot` and `openssl`, and, only with `DNS_API` (Hostinger), `curl` and `dig` (bind9-dnsutils). Without `dig` the Hostinger scripts fall back to the system resolver, which may not be up yet at boot.

Both sysctls in one file (replace `eth0` with your `HOST_LAN_IFACE`), then apply it:

```bash
printf '%s\n' 'net.core.rmem_max=1048576' 'net.ipv6.conf.eth0.accept_ra=2' | sudo tee /etc/sysctl.d/99-pi4-docker.conf
```

```bash
sudo sysctl --system
```

## Quick start

1. Clone the repository to `/opt/Pi4-Docker` (the path the systemd unit and the examples below use) as root, and enter it. The systemd unit and Certbot run its scripts as root, so a checkout your normal user can write would let anything running as that user become root. Use `sudo` for every command below that touches the checkout.

   ```bash
   sudo git clone https://github.com/rube200/Pi4-Docker /opt/Pi4-Docker
   ```

   ```bash
   cd /opt/Pi4-Docker
   ```

2. Copy the environment template and set at least `HOST_SERVER_HOSTNAME`, `HOST_LAN_IP` and `HOST_LAN_IP6`. See [.env.example](.env.example) for all variables. Also add your LAN’s global IPv6 prefix (the `/64` of `HOST_LAN_IP6`) to `TRUSTED_PREFIX6`: LAN devices reach the Pi from their global IPv6 addresses, and without it the firewall treats them like internet clients (shared DNS rate limit, no SSH).

   ```bash
   sudo cp .env.example .env
   ```

   Make it readable by root only, because it can hold the Hostinger token (`DNS_API`), which can rewrite your DNS records and get certificates for your domain:

   ```bash
   sudo chmod 600 .env
   ```

3. Apply the host firewall, then enable `nftables.service` so the saved rules load early at every boot, before Docker starts any container. Without it the Pi has no firewall until the systemd unit below runs, and after a power cut Docker restarts the containers before that.

   ```bash
   sudo sh host-scripts/firewall-rules.sh
   ```

   ```bash
   sudo systemctl enable nftables
   ```

   Use `systemctl reload nftables`, never `restart` or `stop`: stopping the Debian unit flushes every ruleset, Docker’s included.

4. Start the stack. The first run builds the local images; Docker creates the bind-mounted host directories (`/etc/pihole`, `/etc/wireguard`, …) if they are missing.

   ```bash
   sudo docker compose up -d
   ```

5. Set the Pi-hole web password. The web interface is at `https://pi-hole.<hostname>/admin`.

   ```bash
   sudo docker exec -it pihole pihole setpassword
   ```

   The login page is on the internet, so also turn on two-factor authentication (TOTP) under **Settings → Web interface / API**. nginx caps login attempts for all clients together, so during a password-guessing attack your own logins can get **429** too; sessions you already have keep working.

6. Issue the TLS certificate on the host (see [Certificates](#certificates)). Until then nginx serves a self-signed placeholder.

7. In Pi-hole’s settings, turn on its **DHCP server** with a range in your LAN and your router as the gateway, then turn off your router’s DHCP server: the relays forward LAN requests to Pi-hole, which hands out `HOST_LAN_IP` as the DNS server. If the router’s DHCP server cannot be turned off, shrink its range to the fewest addresses it allows, outside Pi-hole’s range: clients take whichever offer arrives first, so the router keeps winning some until its range is used up. IPv6 needs nothing in Pi-hole: the compose file sets up stateless DHCPv6, which hands out `HOST_LAN_IP6` as the DNS server while addresses still come from the router (SLAAC). Clients only ask for it when the router’s Router Advertisements set the *other configuration* (O) flag, and Android never asks, so if the router can advertise a DNS server (RDNSS), point it at `HOST_LAN_IP6` too.

8. Add WireGuard clients (see [WireGuard](#wireguard)).

9. Optional: install the [systemd service](#systemd-service) so all of the above runs at boot.

## Configuration

Settings you are expected to change live in `.env` (see [.env.example](.env.example)); the rest is fixed in the files below.

- **Unbound:** [unbound-docker/pi-hole.conf](unbound-docker/pi-hole.conf) is the resolver config, based on the Pi-hole guide, on port **5335**; only the Docker network may query it. Instead of recursing from the root servers in plaintext, it forwards every query to Quad9 (`dns.quad9.net`, with malware blocking) over DNS-over-TLS. There is no fallback to recursion: if Quad9 is unreachable, DNS fails rather than leaking queries in plaintext. Quad9 validates DNSSEC and Unbound checks every answer again, so a bogus answer is refused even if it comes from Quad9. Quad9 cannot sign the NXDOMAIN it synthesizes for a blocked name, so Quad9's blocks reach clients as SERVFAIL rather than NXDOMAIN. Unbound reports unhealthy while none of Quad9's addresses answers over DNS-over-TLS with a valid certificate; the healthcheck asks Quad9 directly, because an answer from Unbound's cache would hide an outage.
- **Pi-hole:** configured through the `FTLCONF_*` variables in the compose file (DNSSEC off because Unbound already validates, Unbound as the only upstream, the relayed DHCP subnets, the web domain and port). Pi-hole shows these settings as read-only in its web interface; change them in the compose file. Everything else, the DHCP server included, is set in the web interface and kept in `/etc/pihole`. Web interface logins last 30 days (`FTLCONF_webserver_session_timeout`).
- **DHCP relays:** [dhcp-relay-docker/](dhcp-relay-docker/) runs dnsmasq as a relay only. Each relay waits for a global address on `HOST_LAN_IFACE`, and reports unhealthy while it waits or when the address it relays from is not `HOST_LAN_IP` (IPv4) or inside the `/64` of `HOST_LAN_IP6`, because Pi-hole drops those requests.
- **DoH:** [doh-docker/](doh-docker/) runs two doh-proxy processes, one per address family, each forwarding to Pi-hole over the same family. Each process has its own ODoH key, so nginx sends every Oblivious DoH request to the IPv4 one. The image downloads a pinned `doh-proxy` release (`DOH_PROXY_VERSION` in `doh-docker/Dockerfile`, checked against the `DOH_PROXY_SHA256_*` next to it; update all three together) for **x86_64** or **aarch64** only; 32-bit ARM is not supported (see `doh-docker/install-doh-proxy.sh`).
- **WireGuard:** [wireguard-docker/](wireguard-docker/) holds the server config template, the client script and the container firewall; see [WireGuard](#wireguard).
- **nginx:** [nginx-docker/](nginx-docker/) holds the templates under `conf/templates/` (processed at container start), shared includes under `conf/common.d/`, the DoT stream proxy under `conf/stream.d/`, and the static site under `html/`. Every HTTPS response carries HSTS with `includeSubDomains; preload`, so once a browser has visited, it refuses plain HTTP for a year on **every** subdomain of `HOST_SERVER_HOSTNAME`, including ones this stack does not serve. Optional subdomain reverse-proxy samples live under `nginx-docker/examples/` (copy into `nginx-docker/conf/templates/` as `*.conf.template` and rebuild; they are not loaded until you do).
- **Host automation:** [host-scripts/](host-scripts/) holds the firewall, certificate renewal, Pi-hole TLS renewal, and the optional [Hostinger DNS](#hostinger-dns-optional) helpers (`DNS_API`).

### Landing page

**Home Assistant and Kodi are placeholders only** in this repository: the compose stack does **not** run those apps, and **no** nginx vhosts for `home-assistant.*` or `kodi.*` are enabled until you add your own `*.conf.template` (see `nginx-docker/examples/`) and something listening behind `proxy_pass`. The landing page tiles stay **disabled** until those subdomains respond. **Pi-hole** is the dashboard wired for typical use once DNS and TLS are in place. Unknown paths on the main site show the landing page. The page loads Bootstrap’s stylesheet from jsDelivr (pinned with a Subresource Integrity hash), so visitors’ browsers also contact `cdn.jsdelivr.net`.

## Network and ports

These are the **published** mappings from [docker-compose.yaml](docker-compose.yaml). **Publishing in Compose only binds ports on the host; it does not mean every published port must be reachable from the public internet.** Use the **host firewall** and **router port forwarding** to match your threat model.

| Host port | Proto | Service | Role |
|-----------|-------|---------|------|
| **53** | TCP, UDP | Pi-hole | Standard DNS (DHCP clients and LAN resolvers use this). |
| **67** / **547** | UDP | DHCP relays | `network_mode: host`; relay LAN DHCPv4 / DHCPv6 to Pi-hole on the Docker network. |
| **80** | TCP | nginx | HTTP: redirect to HTTPS and the ACME HTTP-01 webroot. |
| **443** | TCP, UDP | nginx | HTTPS and HTTP/3 for the main site and vhosts (see `nginx-docker/conf/templates/`), including the Pi-hole web UI at `pi-hole.<hostname>`. |
| **853** | TCP | nginx → Pi-hole | **DNS-over-TLS** (stream proxy to Pi-hole’s DNS on the bridge). |
| **8443** | TCP, UDP | nginx → DoH | **DNS-over-HTTPS** and **Oblivious DoH** at `https://<hostname>:8443/<DOH_PATH>` (ODoH keys at `/.well-known/odohconfigs`); nginx forwards to the `doh` service. |
| **51820** | UDP | WireGuard | VPN listen port (default **ListenPort** in the WireGuard config). |

The backends are **not published** at all and are only reachable on the Docker network (see [Services](#services)): Unbound (**5335**), doh-proxy (**3000**) and Pi-hole’s own HTTPS port (**44353**, proxied by nginx).

nginx answers on **80**, **443** and **8443** for any name, but redirects every name it does not serve (a bare IP address or an unknown subdomain, for example) to `https://<hostname>`.

**Conflicts:** If something else on the host already binds **53** (systemd-resolved, another DNS, etc.), Pi-hole’s publish will fail until that is moved or disabled. The same goes for a DHCP server or relay already running on the host (**67** / **547**).

### Exposure patterns

Pick what matches you:

- **WireGuard only:** forward only WireGuard (**51820**) and reach the rest through the tunnel (see [WireGuard](#wireguard) for what each client may reach). Trusted LAN clients still use **53** and local HTTPS without the [WAN rate limits](#wan-rate-limits).
- **Full public edge (reference setup for this repo):** WireGuard **plus** **DNS (53)**, **HTTP/HTTPS (80, 443)**, **DoT (853)**, and **DoH (8443)** on the WAN. Aimed at a small trusted group (for example you and a few remote users), not an open public resolver. It **widens your attack surface**—keep the host patched, keep the nftables rate limits, and treat the Pi-hole admin (`pi-hole.<hostname>`) as sensitive.

**Router port forwarding for the full public edge:** forward **53** (TCP+UDP), **80**, **443** (TCP+UDP), **853**, **8443** (TCP+UDP), and WireGuard (**51820**/UDP) to the Pi.

On IPv6 the router opens firewall pinholes instead of forwarding ports: open only the ports above to the Pi, never all of them.

## Firewall and rate limits

### Host firewall

[host-scripts/firewall-rules.sh](host-scripts/firewall-rules.sh) installs [host-scripts/nftables.conf](host-scripts/nftables.conf) as `/etc/nftables.conf` and loads it; `nftables.service` loads that file again early at boot (see [Quick start](#quick-start)). The script validates the ruleset before installing it and keeps the first `/etc/nftables.conf` it replaces as `/etc/nftables.conf.bak`. The ruleset only replaces its own table, `inet pi4d_filter`, so Docker’s rules are left alone.

- **Trusted prefixes:** `TRUSTED_PREFIX` (default `192.168.0.0/16`) and `TRUSTED_PREFIX6` (default `fd00::/8`) from `.env`, plus IPv6 link-local. They get SSH and unlimited HTTP/HTTPS/DNS/DoH/DoT. An invalid entry is skipped with a warning; if none is valid, the Pi’s own LAN subnets are trusted instead.
- **Containers:** they may reach the Pi’s own services except SSH, which only `wireguard` (full access clients) may use. Unbound and doh get no TCP or UDP to the Pi at all, and no container may reach it from an IPv6 link-local address (`[FIREWALL-CONTAINER]`). Pi-hole’s web server only answers nginx and itself.
- **Other ports:** untrusted sources may only reach the ports above. Publishing another port in the compose file also needs rules in `nftables.conf` (in `forward` for a Docker-published port, in `input` for one the host serves itself).
- **Logging:** dropped packets are logged with a `[FIREWALL-*]` prefix, at most **10/minute** (burst **5**) per rule, so a flood cannot fill the journal. Broadcast and multicast to the Pi (mDNS, SSDP, NetBIOS, …) are dropped without a log line.

### WAN rate limits

Limits are **per source** (an IPv4 address, or an IPv6 **/64**), in separate IPv4/IPv6 dynamic sets of up to **16384** entries each; idle entries expire after **5m**. Docker-published ports are limited in the `forward` chain, the host’s own services in `input`. `ct state established,related` is accepted **before** these chains, so limits apply mainly to **new** traffic:

- **TCP** (53, 80, 443, 853, 8443): mostly **new connections** (SYNs). Data on an open session does not re-hit the limiter.
- **UDP 53:** each query often uses a new ephemeral port → effectively a **per-query** cap for plain DNS.
- **UDP 443 / 8443 (HTTP/3):** mostly new QUIC connections.
- **UDP 51820:** mostly **new WireGuard handshakes**; tunnel data after that is established and bypasses the limiter.

Each limit has a **burst**: a short spike allowance (token bucket) so a browser opening many connections or a DNS burst at page load is not dropped immediately. Defaults are sized for a handful of remote users (about **3–5** people), not a public open resolver:

| Chain | Ports | Per-source limit | Burst | What it throttles in practice |
|-------|-------|------------------|-------|------------------------------|
| `protection_dns` | **53** TCP/UDP, **853**, **8443** TCP/UDP | **300/minute** | **100** | UDP DNS ≈ queries/min; DoH/DoT ≈ new TLS sessions/min (loose if clients keep connections open). |
| `protection_ddos` | **80**, **443** TCP/UDP | **10/second** | **20** | New HTTP(S) connections/sec; burst covers parallel browser tabs/assets. |
| `protection_wireguard` | **51820** | **30/minute** | **10** | New handshake attempts/min (reconnect storms / scanners). |
| `protection_ping` | ICMP / ICMPv6 echo | **5/second** | **10** | Ping floods. |

DHCP from the LAN (**67**/**68**, **546**/**547**) has its own overall cap in `protection_dhcp`: **20/second**, burst **120**, shared by all clients.

### Service limits

nginx and Pi-hole add their own per-client limits on top of the firewall. They apply to every client, trusted LAN included; nginx answers **429** when one is hit, and counts an IPv6 client per **/64** like the firewall.

| Where | Limit |
|-------|-------|
| nginx, HTTP, HTTPS and DoH | **64** open connections |
| nginx, DoT (**853**) | **32** open connections |
| nginx, DoH (**8443**) | **20** requests/second, burst **120** |
| nginx, Pi-hole web interface | **30** requests/second, burst **60**; login (`POST /api/auth`) **10**/minute, burst **5**, and **30**/minute, burst **10**, for all clients together |
| Pi-hole DNS | **12000** queries/minute (`FTLCONF_dns_rateLimit_count`) |

WireGuard clients reach nginx and Pi-hole as `172.28.0.5` / `fd28::5`, and DoT clients reach Pi-hole as nginx, so each of those groups shares one budget. DoH clients count on their own: `doh` passes each client’s address to Pi-hole, which also shows it in the query log.

## WireGuard

On first start the container creates `/etc/wireguard/wg0.conf` from [wireguard-docker/wg0.conf.template](wireguard-docker/wg0.conf.template) with a new server key. The tunnel uses `10.13.13.0/24` and `fd13:13:13::/64`; the server is `.1`. Every `wg*.conf` in `/etc/wireguard` is brought up as its own interface, and each needs an IPv4 (`/24` or shorter) and an IPv6 (`/64` or shorter) `Address`.

### Adding a client

Run on the host:

```bash
sudo sh /etc/wireguard/create-client.sh
```

The container installs the script there and writes the settings it reads (`wg-firewall.env`) at every start, and the script runs `wg` inside the container, so the host needs no WireGuard tools. It asks which server to use when there is more than one `wg*.conf`, then for a name (letters, digits, `_` and `-`; names starting with `wg` are reserved for server configs) and an access type. It writes the device config to `/etc/wireguard/<name>.conf` and adds the peer to the running server. Every client sends all its traffic through the tunnel and uses Pi-hole for DNS.

### Removing a client

Delete its `# <name> (…)` comment and `[Peer]` block from `/etc/wireguard/wg0.conf`, delete `/etc/wireguard/<name>.conf`, and restart the container.

### Access types

| Access | Addresses | Can reach |
|--------|-----------|-----------|
| **Full access** | `10.13.13.2`–`.15`, `fd13:13:13::2`–`::f` (14 clients) | Everything: the internet, the Pi and the LAN, SSH included. |
| **Internet only** | `10.13.13.16`–`.254`, `fd13:13:13::10`–`::fe` | The internet, Pi-hole DNS and nginx (websites, DoH, DoT). Not the LAN, no other service on the Pi, and no other WireGuard client. |

- The script refuses a new full access client when all 14 addresses are taken. A new internet only client gets the first free address above the highest one in use.
- Opening your hostname takes internet only clients to nginx and full access clients to the Pi itself. The container looks up the hostname’s public addresses when it starts, so restart it (`sudo docker compose restart wireguard`) after they change. If the IPv6 lookup fails, internet only clients get no IPv6 internet until that restart, because the LAN prefix to block is unknown.
- The full access pool is `WG_FULL_ACCESS_MASK` in [docker-compose.yaml](docker-compose.yaml): `28` is 16 addresses, minus the network address and the server.
- `WG_ALLOWLIST` in `.env` lists the addresses internet only clients may reach besides the internet and DNS; the default is nginx.
- The `wireguard` container enforces all of this: its traffic is masqueraded, so the host sees every client as `172.28.0.5` / `fd28::5`.

## Certificates

### nginx (Let’s Encrypt)

nginx serves the Let’s Encrypt certificate for `HOST_SERVER_HOSTNAME`, copied from `/etc/letsencrypt/live/<hostname>/` when the container starts. Until one exists it serves a self-signed placeholder valid for 14 days and reports unhealthy. It also reports unhealthy once the certificate it serves is within 7 days of expiry.

[host-scripts/certbot-renew.sh](host-scripts/certbot-renew.sh) runs `certbot renew` and, when the host certificate differs from the one nginx serves, copies it into the container, checks the config with `nginx -t` and reloads nginx. The systemd unit runs it at boot. To set up certificates on the **host**:

1. Link the script as a Certbot deploy hook, so Certbot runs it after every renewal between boots (a **symlink**, so it still finds `.env`). Certbot only runs hooks that are executable; git keeps the bit, so `chmod +x` the host scripts only if your checkout lost it.

   ```bash
   sudo ln -s /opt/Pi4-Docker/host-scripts/certbot-renew.sh /etc/letsencrypt/renewal-hooks/deploy/pi4-docker.sh
   ```

2. Issue the certificate:
   - **HTTP-01:** `certbot certonly --webroot -w /var/www/certbot --cert-name <hostname> -d <hostname> -d pi-hole.<hostname>` while nginx is running.
   - **DNS-01 through Hostinger** (needed for the wildcard): see [DNS-01 through Hostinger](#dns-01-through-hostinger).
   - Keep `--cert-name <hostname>`: nginx and the deploy hook only read `/etc/letsencrypt/live/<hostname>/`. Without it, a later run with other names (switching to DNS-01, for example) is saved as `<hostname>-0001` and never deployed.

3. Certbot 3.2.0 and later run the hook for the first certificate too, so nginx switches to it right away. Older Certbot (Raspberry Pi OS bookworm ships 2.1) does not; run the script once yourself:

   ```bash
   sudo sh /opt/Pi4-Docker/host-scripts/certbot-renew.sh
   ```

### Pi-hole’s internal certificate

Pi-hole generates its own certificate for the link from nginx (`/etc/pihole/tls.pem`, valid for a year). [host-scripts/pihole-tls-renew.sh](host-scripts/pihole-tls-renew.sh) deletes it once it is within 7 days of expiry and restarts Pi-hole if it is running, so Pi-hole creates a new one; see [systemd service](#systemd-service).

## Hostinger DNS (optional)

The core stack (Unbound, Pi-hole, DoH, nginx, WireGuard) runs without Hostinger. Use this section only if your domain’s DNS is on Hostinger and you want **dynamic DNS** and/or the **DNS-01** Certbot hook. Other certificate methods (HTTP-01, another DNS provider, manual certs) do not need it.

The scripts talk to Hostinger’s **public DNS API** at `https://developers.hostinger.com` using a **Bearer token**. They are written for a domain whose **DNS zone is managed in Hostinger** (same account as the token).

### API token

1. Log in to [Hostinger hPanel](https://hpanel.hostinger.com/).
2. Open the **API** section (hPanel sidebar; search for “API” if needed).
3. **Generate a new token**, name it, set an expiry if you want, then **copy the token once** and store it safely.

Official overview: [What is Hostinger API?](https://support.hostinger.com/en/articles/10840865-what-is-hostinger-public-api)

### Settings in `.env`

- **`HOST_SERVER_HOSTNAME`** is required for the stack anyway (TLS, DoH, Pi-hole web domain, WireGuard endpoint). For Hostinger it must also match the **DNS zone name** in Hostinger (e.g. `example.com`) so `/api/dns/v1/zones/${HOST_SERVER_HOSTNAME}` is correct.
- **`DNS_API`** is your Hostinger API token. **Omit it entirely** if you are not using Hostinger.

```bash
HOST_SERVER_HOSTNAME=example.com
# Optional — only for Hostinger scripts / DNS-01 hook:
# DNS_API=your_hostinger_api_token_here
```

`DNS_API` is never passed to a container. The host scripts take it from the environment or, failing that, read it from the `.env` in the repository, so they also work when Certbot’s own timer runs them.

### Dynamic DNS

Script: [host-scripts/ddns-hostinger.sh](host-scripts/ddns-hostinger.sh). It points the `@` and `*` records at the host’s public IPv4 and IPv6.

- If **`DNS_API` is unset**, the script **exits successfully** and does nothing (safe for hosts without Hostinger).
- If set, it detects the host’s public IPv4 (two of the lookup services must agree on it) and its stable global IPv6 (never a temporary or non-global address, and only one that is on the Pi), reads the zone from the API, then **creates or updates** the **`A` and `AAAA` records for `@` and `*`** (TTL 3600). It waits up to a minute for the host to get a global IPv6, which can lag behind IPv4 at boot; without one it exits with an error and changes nothing.
- The token needs permission to read and update that zone.

[services-docker.service](services-docker.service) runs this script as **`ExecStartPre`** before `docker compose up -d`, so each boot refreshes DNS before services start; a failure there does not stop the stack. Nothing runs it between boots: after your public IPv4 or IPv6 changes, run it again and restart `wireguard` (see [WireGuard](#wireguard)).

```bash
sudo sh /opt/Pi4-Docker/host-scripts/ddns-hostinger.sh
```

### DNS-01 through Hostinger

Script: [host-scripts/certbot-dns-hostinger.sh](host-scripts/certbot-dns-hostinger.sh). Use it to issue certificates with Certbot through **DNS-01**, which the wildcard needs.

- Implements Certbot **manual** hooks: `auth` creates `_acme-challenge.<domain>` **TXT** records; `cleanup` removes them.
- **`DNS_API` and `HOST_SERVER_HOSTNAME` are required** (from the environment or `.env`; the script exits with an error if missing). The records go in the `HOST_SERVER_HOSTNAME` zone, so every `-d` name must be that domain, its wildcard or one of its subdomains.
- Certbot sets **`CERTBOT_DOMAIN`** and **`CERTBOT_VALIDATION`**; the hook checks public DNS (Google / Cloudflare DNS-over-HTTPS) until the TXT is visible, and fails after **45 s** without it.

**Example — first certificate** (run on the host as root, with `certbot`, `curl`, `dig` and this repo at `/opt/Pi4-Docker`):

```bash
certbot certonly \
  --manual \
  --preferred-challenges dns \
  --manual-auth-hook "/opt/Pi4-Docker/host-scripts/certbot-dns-hostinger.sh auth" \
  --manual-cleanup-hook "/opt/Pi4-Docker/host-scripts/certbot-dns-hostinger.sh cleanup" \
  --cert-name "example.com" \
  -d "example.com" \
  -d "*.example.com"
```

Certbot stores the hooks in the certificate’s renewal configuration (under `/etc/letsencrypt/renewal/`), so `certbot renew` keeps using DNS-01. Set up the deploy hook from [Certificates](#nginx-lets-encrypt) as well, so nginx picks up each renewal.

## systemd service

[services-docker.service](services-docker.service) brings the stack up at boot. Before `docker compose up -d --remove-orphans` it runs, in order:

1. [firewall-rules.sh](host-scripts/firewall-rules.sh): applies the firewall.
2. [ddns-hostinger.sh](host-scripts/ddns-hostinger.sh): updates the Hostinger records when `DNS_API` is set. A failure here does not stop the stack.
3. [certbot-renew.sh](host-scripts/certbot-renew.sh): renews the certificate and deploys it into nginx.
4. [pihole-tls-renew.sh](host-scripts/pihole-tls-renew.sh): deletes Pi-hole’s TLS certificate when it is within 7 days of expiry, so Pi-hole creates a new one. Pi-hole only does that when it starts, so the script restarts it if it is already running (after a power cut, for example, Docker restarts it before the unit runs).

It assumes the project lives at **`/opt/Pi4-Docker`** and loads **`/opt/Pi4-Docker/.env`**. To use it elsewhere, either:

- Copy or symlink the repo to that path, **or**
- Edit `WorkingDirectory=`, `EnvironmentFile=`, and every `ExecStartPre=` / `ExecStart=` path in the unit file to match your install.

Then install and enable the unit:

```bash
sudo cp /opt/Pi4-Docker/services-docker.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable services-docker.service
```

If a step fails (for example the network is not up yet), systemd retries every 30 seconds. Stopping the unit runs `docker compose down`.

## Maintenance

### Logs

Every container logs to the systemd journal, tagged with its name, and `docker logs` still works. The firewall logs to the kernel log with a `[FIREWALL-*]` prefix.

```bash
journalctl -t pihole -f
```

```bash
journalctl -k -g FIREWALL
```

### Updating

The systemd unit only builds images that are missing, so after pulling changes rebuild the local images yourself, and re-apply the firewall if `host-scripts/nftables.conf` changed:

```bash
sudo git pull
```

```bash
sudo docker compose up -d --build
```

```bash
sudo sh host-scripts/firewall-rules.sh
```

### Image versions

Published images and base images are **pinned to specific tags** in `docker-compose.yaml` and Dockerfiles; Dependabot ([.github/dependabot.yml](.github/dependabot.yml)) proposes daily updates. Upgrade deliberately (check upstream release notes), then update tags and test. The Alpine packages inside the local images are whatever the repositories carry at build time (each Dockerfile runs `apk upgrade`), and Unbound comes from Alpine **edge** until the base image is Alpine 3.25 (see [unbound-docker/Dockerfile](unbound-docker/Dockerfile)). To pick up new packages without a tag change, rebuild without the cache:

```bash
sudo docker compose build --no-cache
```

```bash
sudo docker compose up -d
```

To confirm what is newest on Docker Hub, use each image’s tags API (for example `https://hub.docker.com/v2/repositories/pihole/pihole/tags?ordering=last_updated`) or the Hub UI. **Pi-hole:** the highest `YYYY.MM.N` tag on Hub is normally the same image as `latest`; compare digests to be sure. **nginx:** the highest `X.Y.Z-alpine-slim` tag can trail `mainline-alpine-slim`; when they match digest, the semver tag is still “current mainline.”

## Troubleshooting

`sudo docker compose ps` shows which container is unhealthy, and its journal (`journalctl -t <container>`) says why.

- **IPv6 works on the host but not in containers:** Docker’s IPv6 NAT is off (`"ip6tables": true`, see [Requirements](#requirements)).
- **Pi-hole does not start, port 53 in use:** something else on the host binds **53** (see [Network and ports](#network-and-ports)).
- **Unbound unhealthy, “Quad9 unreachable over DNS-over-TLS”:** the Pi has no internet, or something blocks TCP **853** to Quad9. Names Unbound has not cached fail until it is back, since there is no fallback.
- **`dhcpv6-relay` unhealthy, waiting for an address:** the Pi has no global IPv6 on `HOST_LAN_IFACE` (`ip -6 addr show scope global`). Check `accept_ra=2` (see [Requirements](#requirements)).
- **A relay unhealthy, “Pi-hole drops every request”:** it relays from an address that is not `HOST_LAN_IP`, or not inside the `/64` of `HOST_LAN_IP6`. Fix those in `.env`, or set `DHCP_LOCAL_IP` / `DHCP_LOCAL_IP6`.
- **nginx unhealthy:** it serves the self-signed placeholder or a certificate within 7 days of expiry (see [Certificates](#certificates)).
- **`wireguard` fails with “Unknown device type”:** load the `wireguard` module at boot (see [Requirements](#requirements)).
- **Internet only WireGuard clients have no IPv6:** the hostname’s AAAA lookup failed when the container started; restart it (see [WireGuard](#wireguard)).
- **HTTP errors from Hostinger:** wrong token, token without DNS access, or **`HOST_SERVER_HOSTNAME` not matching** the zone name in Hostinger.
- **Certbot TXT “not visible”:** nameservers for the domain must point at Hostinger’s DNS for the API-written records to be what the public internet resolves; propagation can take a few minutes.

## Security

This stack’s reference posture is the **full public edge** (DNS **53** + DoH **8443** + DoT **853**, plus HTTPS and WireGuard). WAN abuse controls are **per-source** nftables rate limits on **new** flows (see [Firewall and rate limits](#firewall-and-rate-limits)). Review [host-scripts/nftables.conf](host-scripts/nftables.conf) and your **router forwards** (see [Network and ports](#network-and-ports)) so exposure matches. Only full access WireGuard clients can reach the LAN (see [WireGuard](#wireguard)). If you set **`DNS_API`**, treat it like any other **secret** (Hostinger token). WireGuard keys are secrets too. Do not commit `.env`.

To **report a vulnerability in this project** (this repo’s compose, scripts, or shipped integration defaults), follow [SECURITY.md](SECURITY.md).

## Support and disclaimer

This repository is **reference configuration** for self-hosting: **no warranty**, **not a security audit**, and **not a supported product**. Operators are responsible for updates, firewall posture, and exposure to the internet. Issues and pull requests are welcome; response time is **best effort** only.

### Contributing

Contributions are welcome under GPLv3. There is no separate contributor agreement; by contributing you agree your work is licensed under the same terms as this repository.

### Trademarks

This project may reference or display logos for **Pi-hole**, **Home Assistant**, **Kodi**, and similar projects. Those marks belong to their respective owners. This project is **not** affiliated with or endorsed by them.
