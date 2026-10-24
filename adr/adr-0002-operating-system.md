# ADR-0002: Operating System — Linux over Windows

**Status:** Accepted — distro question closed by ADR-0008
**Date:** 2026-08-18

## Context

The motherboard's existing RAID array was set up and used under Windows. For
the server build, the decision was made to run Linux instead.

## Decision

Run a Linux distribution as the server OS. The specific distro (e.g. a
general-purpose distro like Debian/Ubuntu Server, configured manually, vs. a
NAS-oriented distro) has not yet been chosen.

## Alternatives considered

- **Windows / Windows Server** — not selected; no longer under consideration
  for this build.

## Consequences

- AMD RaidXpert2 firmware RAID metadata is not natively readable by Linux —
  this directly informed ADR-0003 (retiring the firmware RAID array).
- The container platform decision (ADR-0006, Podman) assumes a Linux host.

## Open questions

- Specific distro selection is still pending.

## Update 2026-09-21

If ADR-0008 is accepted, the bare-metal OS becomes Proxmox VE (Debian-based) and the guest VMs run Ubuntu 26.04 from a cloud-init template. That would close the open distro question.

## Update 2026-09-21: closed by ADR-0008

ADR-0008 is accepted and deployed. The bare-metal OS is **Proxmox VE 9.2**
(Debian trixie based, kernel 7.0). The cluster VMs run **Ubuntu 26.04 LTS**
from a cloud-init template (VMID 9000). The open distro question is closed.
