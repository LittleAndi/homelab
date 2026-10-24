# ADR-0006: Container Platform — Podman

**Status:** **Superseded by ADR-0008** (2026-09-21)
**Date:** 2026-08-18

## Context

The server is a single node, not a cluster. Candidates considered: MicroK8s,
k3s, Rancher (RKE2), and Podman.

## Decision

Use **Podman** as the container platform.

## Alternatives considered

- **k3s / MicroK8s / Rancher (RKE2)** — all Kubernetes-flavored. They add
  operational overhead (control plane, etcd/sqlite state, YAML manifest
  complexity, PersistentVolume/StorageClass abstraction) that isn't
  justified for a single-node file server. Worth reconsidering if the
  deployment grows into a multi-node cluster or Kubernetes-specific
  APIs/features become genuinely needed.

## Consequences

- Storage is mounted into containers via direct bind mounts — no
  PersistentVolume/StorageClass abstraction layer to manage.
- Deployment tooling narrows to Podman-compatible options (Quadlets,
  podman-compose, etc.) — see ADR-0007 for the specific approach chosen.

## Update 2026-09-21

ADR-0008 (proposed) moves to a 5-VM MicroK8s cluster on Proxmox VE. That is the "multi-node cluster" condition this ADR named as the reason to reconsider Kubernetes. Here the nodes are VMs on one host, chosen for learning/HA practice rather than hardware redundancy.

## Update 2026-09-21: superseded

ADR-0008 is accepted and deployed: a 5-node MicroK8s 1.35 cluster (3
control plane, 2 workers) on Proxmox VMs. Podman is not used. The
PersistentVolume/StorageClass layer this ADR avoided is now in place
(`nfs-client`, `local-path`).
