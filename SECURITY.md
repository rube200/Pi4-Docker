# Security policy

## Reporting a vulnerability

If you believe you have found a security vulnerability in **this repository** (compose layout, scripts, or container configuration shipped here), please report it **privately** so it can be addressed before public disclosure.

**Preferred:** use GitHub **private vulnerability reporting** for this repository: open the repo on GitHub, go to **Security**, then **Report a vulnerability**. If that option is not available, open a **draft security advisory** from the same **Security** tab, or contact the maintainers through a non-public channel you already use with them.

Please include enough detail to reproduce or understand the issue (affected paths, versions or image tags if relevant, and impact). Do not post exploit details in public issues.

## Scope and expectations

This project is a **self-hosted reference stack**. It wires together upstream software (Pi-hole, Unbound, Nginx, WireGuard, etc.). Vulnerabilities in **upstream images or products** should be reported to those projects’ own security contacts; fixes here are limited to updating pins, defaults, or integration glue when appropriate.

There is **no bug bounty** and **no SLA** for triage or fixes. Reports are handled on a best-effort basis.

## After publication

Keep production hosts patched, rotate secrets if they may have been exposed, and review firewall and exposure (WAN vs LAN) against your threat model.
