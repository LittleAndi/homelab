# ADR-0003: Retire Motherboard Firmware RAID; Rely on Azure Backup

**Status:** Accepted
**Date:** 2026-08-18

## Context

Two existing HDDs are members of an AMD RaidXpert2 (motherboard-managed)
RAID array. Moving to Linux (ADR-0002) means this firmware RAID format won't
be natively usable — Linux has no clean support for reading/assembling AMD's
RaidXpert2 array metadata. The existing contents of the HDDs are already
backed up to Azure via rclone.

## Decision

Abandon the existing firmware RAID array. The two HDDs will be reformatted
and repurposed for the new Linux storage layout (ADR-0004). Data will be
restored from the Azure rclone backup after the new storage pool is built.

## Alternatives considered

- **Migrating/preserving the RAID array under Linux** — rejected as
  impractical given the lack of native OS support for the array format.

## Consequences

- Both HDDs need to be reformatted (e.g. ext4/XFS) before joining the new
  mergerfs pool.
- A restore step (rclone pull from Azure) is required after the pool exists
  and before/while the Nextcloud data directory is populated.
- The rclone remote/config should be checked for validity (expired tokens,
  etc.) before performing the restore.

## Update 2026-09-21

The decision to retire the firmware RAID still stands. Under ADR-0008 (proposed), the two 2TB HDDs would become a ZFS mirror (`hddmirror`) instead of joining a mergerfs pool. The Azure restore step is unchanged.
