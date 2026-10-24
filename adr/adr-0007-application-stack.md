# ADR-0007: Application Stack — Compose Deployment, Tailscale-integrated Reverse Proxy, Observability

**Status:** **Superseded by ADR-0010** (2026-09-22)
**Date:** 2026-08-18

## Context

Needed a way to run Nextcloud plus supporting services (database, cache,
reverse proxy, monitoring) on Podman (ADR-0006), with secure remote access
that doesn't require manually managing TLS certificates.

## Decision

- Deploy via a Compose-style stack (`nextcloud-db`, `nextcloud-app`,
  `caddy-proxy`, plus one-shot init containers `db-init` and `nc-init` that
  idempotently bootstrap the DB exporter user and the Nextcloud serverinfo
  token on every `up`).
- Use `ghcr.io/tailscale/caddy-tailscale`, which bundles Tailscale directly
  into Caddy — the reverse proxy joins the Tailscale network and obtains TLS
  certificates from Tailscale's own CA, avoiding a separate ACME/Let's
  Encrypt setup.
- Include a full observability stack: Prometheus (30-day retention) +
  node-exporter + cAdvisor + mysqld-exporter + nextcloud-exporter for
  metrics; Loki (24-hour retention) + Grafana Alloy for logs; Grafana for
  visualization. All internal-only — nothing in this layer is published to
  the host or the tailnet.

## Alternatives considered

- **Podman Quadlets** (systemd-native unit files) — discussed earlier as a
  simpler, more "Podman-native" path for a smaller stack. Superseded once
  the fuller compose file (with the observability stack and Tailscale
  integration already built out) was in place; kept as Compose since it
  already implements everything needed.
- **Manual Let's Encrypt/ACME reverse proxy** — unnecessary given the
  Tailscale-integrated Caddy image handles TLS.

## Consequences

- Remote access is tied to the Tailscale network (reached via `NC_DOMAIN` /
  Tailscale hostname) rather than a publicly resolvable domain.
- The observability stack adds meaningful resource overhead (9+ containers
  beyond the core Nextcloud stack) — acceptable given the server is a
  dedicated, single-purpose box.
- **Open dependency on ADR-0005**: the storage split (SSD for app/DB, HDD
  pool for user data) has not yet been applied to this compose file — see
  ADR-0005's open action item.

## Update 2026-09-21

If ADR-0008 is accepted, Nextcloud/MariaDB/Redis move into the MicroK8s cluster (Helm chart or raw manifests). That migration is not designed yet. The Tailscale+Caddy and observability choices here need to be re-evaluated for Kubernetes at that point.

## Update 2026-09-21: platform changed, stack not yet redesigned

ADR-0008 is accepted and the MicroK8s cluster is running, but nothing from
this stack is deployed on it yet. The Compose file itself won't be used.
What still needs deciding, in a new ADR for the Nextcloud deployment:

- Nextcloud/MariaDB/Redis as Helm chart or own manifests, using the
  storage split from ADR-0008 (MariaDB on `local-path`, user files on
  `nfs-client`, nightly `mariadb-dump` to the NFS share).
- Whether Tailscale + Caddy remains the way in, or a Kubernetes ingress with
  the Tailscale operator replaces it.
- How much of the observability stack to bring over, given the cluster's
  17 GB RAM budget.

This ADR stays the reference for the intent (Tailscale-only access, TLS
without manual certificates, internal-only monitoring) until that ADR
supersedes it.

## Update 2026-09-22: superseded

ADR-0010 (Proposed) replaces this stack with a Helm deployment on the
cluster, the Tailscale Kubernetes operator in place of `caddy-tailscale`,
and minimal observability for now. The Compose stack described above is
still what's actually running until ADR-0010's migration is done. Until
then this ADR describes the live system, but it's no longer the target
architecture.

Correction 2026-09-25: this note first said ADR-0010 was "accepted"; it
is still Proposed.
