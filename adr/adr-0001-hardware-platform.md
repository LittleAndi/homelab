# ADR-0001: Server Hardware Platform

**Status:** Accepted
**Date:** 2026-08-18

## Context

Building a new home server. Already own an Asrock B650M-HDV/M.2 motherboard,
currently in use in another machine with two HDDs attached as a
motherboard-managed (AMD RaidXpert2) RAID array. A new AMD Ryzen 7 7700 CPU
has been acquired for the server build. A case was needed with room to grow
storage well beyond the two initial HDDs.

## Decision

- Reuse the existing Asrock B650M-HDV/M.2 (mATX) motherboard for the server,
  carrying over the currently-attached HDDs.
- Pair it with the new AMD Ryzen 7 7700 CPU.
- House the build in a **Jonsbo N6** case: 9x 3.5" HDD/SSD hot-swap bays,
  supports mATX motherboards, and supports ATX (up to 220mm) or SFX (up to
  100mm) power supplies.

## Alternatives considered

- **New motherboard / full rebuild** — rejected as unnecessary; the existing
  board meets requirements and reuse avoids extra cost.

## Consequences

- The board's SATA port count (commonly 4 on this model) may cap the number
  of directly-attached drives before an HBA/expansion card is needed as the
  Jonsbo N6's 9 bays fill up.
- Drives connect through the N6's hot-swap backplane rather than direct
  motherboard SATA cables — separate data + power cabling to the backplane
  required.

## Update 2026-09-21

The SATA port limit noted above is addressed by ADR-0009 (LSI SAS 9211-8i HBA in IT mode).
