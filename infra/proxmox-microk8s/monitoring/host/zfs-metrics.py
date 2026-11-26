#!/usr/bin/env python3
"""ZFS metrics for node_exporter's textfile collector (ADR-0013).

Writes pool capacity and health, dataset usage/quota/reservation, and the
newest snapshot time per dataset, and txg sync times to
/var/lib/prometheus/node-exporter/zfs.prom. Run every minute by
zfs-metrics.timer.

Snapshot age in PromQL:
    time() - zfs_dataset_newest_snapshot_timestamp_seconds
Received snapshots keep their source creation time, so on hgst/backup/* the
same expression shows how far syncoid is behind.
"""
import glob
import os
import subprocess
import tempfile
import time
from collections import OrderedDict

OUT_DIR = "/var/lib/prometheus/node-exporter"
OUT_FILE = os.path.join(OUT_DIR, "zfs.prom")
HEALTH_STATES = ["ONLINE", "DEGRADED", "FAULTED", "OFFLINE",
                 "UNAVAIL", "REMOVED", "SUSPENDED"]
# Snapshots that aren't backups and shouldn't count for freshness.
IGNORED_SNAPSHOT_SUFFIXES = ("@__base__",)

families = OrderedDict()  # metric name -> (help, type, [sample lines])


def run(*args):
    return subprocess.run(args, check=True, capture_output=True,
                          text=True).stdout


def esc(value):
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def num(value):
    value = value.strip().rstrip("x%")
    return "NaN" if value in ("", "-") else value


def add(name, help_text, labels, value, mtype="gauge"):
    fam = families.setdefault(name, (help_text, mtype, []))
    lbl = ",".join(f'{k}="{esc(v)}"' for k, v in labels.items())
    fam[2].append(f"{name}{{{lbl}}} {value}")


def pools():
    out = run("zpool", "list", "-Hp", "-o",
              "name,size,alloc,free,frag,cap,health")
    for line in out.splitlines():
        name, size, alloc, free, frag, cap, health = line.split("\t")
        lbl = {"pool": name}
        add("zfs_pool_size_bytes", "Pool size in bytes.", lbl, num(size))
        add("zfs_pool_allocated_bytes", "Allocated space in bytes.", lbl, num(alloc))
        add("zfs_pool_free_bytes", "Free space in bytes.", lbl, num(free))
        add("zfs_pool_fragmentation_percent", "Free-space fragmentation.", lbl, num(frag))
        add("zfs_pool_capacity_percent", "Allocated share of pool size.", lbl, num(cap))
        for state in HEALTH_STATES:
            add("zfs_pool_health",
                "1 for the pool's current health state, 0 otherwise.",
                {"pool": name, "state": state},
                1 if health == state else 0)


def datasets():
    out = run("zfs", "list", "-Hp", "-t", "filesystem,volume", "-o",
              "name,type,used,avail,refer,usedbysnapshots,quota,refquota,"
              "reservation,refreservation,compressratio")
    for line in out.splitlines():
        (name, dtype, used, avail, refer, usedsnap, quota, refquota,
         resv, refresv, ratio) = line.split("\t")
        lbl = {"dataset": name, "type": dtype}
        add("zfs_dataset_used_bytes", "Space used incl. children and snapshots.", lbl, num(used))
        add("zfs_dataset_available_bytes", "Space available to the dataset.", lbl, num(avail))
        add("zfs_dataset_referenced_bytes", "Data referenced by the dataset.", lbl, num(refer))
        add("zfs_dataset_used_by_snapshots_bytes", "Space held only by snapshots.", lbl, num(usedsnap))
        add("zfs_dataset_quota_bytes", "quota (0 = none).", lbl, num(quota))
        add("zfs_dataset_refquota_bytes", "refquota (0 = none).", lbl, num(refquota))
        add("zfs_dataset_reservation_bytes", "reservation (0 = none).", lbl, num(resv))
        add("zfs_dataset_refreservation_bytes", "refreservation (0 = none).", lbl, num(refresv))
        add("zfs_dataset_compress_ratio", "Compression ratio.", lbl, num(ratio))


def snapshots():
    out = run("zfs", "list", "-Hp", "-t", "snapshot", "-o", "name,creation")
    newest, count = {}, {}
    for line in out.splitlines():
        name, creation = line.split("\t")
        if name.endswith(IGNORED_SNAPSHOT_SUFFIXES):
            continue
        ds = name.split("@", 1)[0]
        ts = int(creation)
        newest[ds] = max(newest.get(ds, 0), ts)
        count[ds] = count.get(ds, 0) + 1
    for ds in sorted(newest):
        lbl = {"dataset": ds}
        add("zfs_dataset_newest_snapshot_timestamp_seconds",
            "Creation time of the newest snapshot (Unix seconds).", lbl, newest[ds])
        add("zfs_dataset_snapshot_count", "Number of snapshots.", lbl, count[ds])


def txgs():
    """Sync/wait time of recently committed transaction groups.

    Snapshots, destroys and big flushes make ZFS sync a txg; while it syncs,
    writers (the VM disks on rpool, fsync) can stall. /proc/spl/kstat keeps
    ~100 recent txgs; `birth` is CLOCK_MONOTONIC_RAW in ns (not
    CLOCK_MONOTONIC: NTP slewing moves the two apart by seconds per day). We
    export the max per pool over txgs born in the last 80 s, so a short stall
    isn't averaged away by the scrape interval. Runs are 60-70 s apart and a
    txg is only counted once committed, hence the overlap (ADR-0013 Updates
    2026-11-25 and 2026-11-26).
    """
    now = time.clock_gettime_ns(time.CLOCK_MONOTONIC_RAW)
    for path in glob.glob("/proc/spl/kstat/zfs/*/txgs"):
        pool = path.split("/")[-2]
        sync = wait = dirty = n = 0
        with open(path) as f:
            next(f, None)  # header
            for line in f:
                c = line.split()
                if len(c) < 12 or c[2] != "C" or now - int(c[1]) > 80e9:
                    continue
                n += 1
                dirty = max(dirty, int(c[3]))
                wait = max(wait, (int(c[9]) + int(c[10])) / 1e9)  # qtime+wtime
                sync = max(sync, int(c[11]) / 1e9)                # stime
        lbl = {"pool": pool}
        add("zfs_pool_txg_sync_seconds_max",
            "Longest txg sync time among txgs born in the last 80 s.", lbl, sync)
        add("zfs_pool_txg_wait_seconds_max",
            "Longest txg queue+wait time among txgs born in the last 80 s.", lbl, wait)
        add("zfs_pool_txg_dirty_bytes_max",
            "Largest txg dirty data among txgs born in the last 80 s.", lbl, dirty)
        add("zfs_pool_txg_closed_count",
            "Committed txgs born in the last 80 s.", lbl, n)


def write():
    lines = []
    for name, (help_text, mtype, samples) in families.items():
        lines.append(f"# HELP {name} {help_text}")
        lines.append(f"# TYPE {name} {mtype}")
        lines.extend(samples)
    fd, tmp = tempfile.mkstemp(dir=OUT_DIR, prefix=".zfs.prom.")
    try:
        with os.fdopen(fd, "w") as f:
            f.write("\n".join(lines) + "\n")
        os.chmod(tmp, 0o644)
        os.replace(tmp, OUT_FILE)  # atomic: node_exporter never sees half a file
    except BaseException:
        os.unlink(tmp)
        raise


if __name__ == "__main__":
    pools()
    datasets()
    snapshots()
    txgs()
    write()
