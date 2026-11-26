#!/usr/bin/env python3
"""Log every slow rpool txg sync to the journal with its wall-clock time.

Temporary diagnostic for the dqlite "database is locked" errors (ADR-0013
Update 2026-11-26): the VM disks are on rpool, and the txg metrics only give
a maximum per window, so they can't be lined up with journal timestamps.

Polls /proc/spl/kstat/zfs/<pool>/txgs (about 100 recent txgs, ~8 min at one
per 5 s) and prints one line per committed txg whose sync took at least
--threshold seconds. Times are UTC, like the node journals. A "gap" line
means txgs left the history unread, so silence there proves nothing.

The last txg handled is kept in --state, so a restart logs nothing twice.
`birth` in the kstat is CLOCK_MONOTONIC_RAW, not CLOCK_MONOTONIC.

    journalctl -u slow-txg-log -o cat
"""
import argparse
import datetime
import os
import time

KSTAT = "/proc/spl/kstat/zfs/{pool}/txgs"


def parse(text):
    """Return the kstat rows as dicts, oldest first."""
    lines = text.splitlines()
    header = lines[0].split()
    rows = []
    for line in lines[1:]:
        cols = line.split()
        if len(cols) != len(header):
            continue
        row = {k: v if k == "state" else int(v) for k, v in zip(header, cols)}
        rows.append(row)
    return rows


def utc(wall_ns):
    t = datetime.datetime.fromtimestamp(wall_ns / 1e9, datetime.timezone.utc)
    return t.strftime("%Y-%m-%dT%H:%M:%S.") + f"{t.microsecond // 1000:03d}Z"


def process(rows, last, pool, threshold, wall_ns, raw_ns):
    """Return (log lines, new last txg) for committed txgs newer than last."""
    out = []
    if rows and last is not None:
        if rows[-1]["txg"] < last:      # numbers went backwards: new history
            last = None
        elif rows[0]["txg"] > last + 1:
            out.append(f"gap pool={pool} first_missed={last + 1} "
                       f"missed={rows[0]['txg'] - last - 1}")
    for r in rows:
        if last is not None and r["txg"] <= last:
            continue
        if r["state"] != "C":           # txgs commit in order
            break
        last = r["txg"]
        if r["stime"] < threshold * 1e9:
            continue
        start = r["birth"] + r["otime"] + r["qtime"] + r["wtime"]
        out.append(
            f"slow pool={pool} txg={r['txg']} "
            f"sync_start={utc(wall_ns - (raw_ns - start))} "
            f"sync_end={utc(wall_ns - (raw_ns - start - r['stime']))} "
            f"sync_s={r['stime'] / 1e9:.3f} "
            f"open_s={r['otime'] / 1e9:.3f} "
            f"quiesce_s={r['qtime'] / 1e9:.3f} "
            f"wait_s={r['wtime'] / 1e9:.3f} "
            f"dirty_bytes={r['ndirty']} written_bytes={r['nwritten']} "
            f"writes={r['writes']}")
    return out, last


def load(path):
    try:
        with open(path) as f:
            return int(f.read())
    except (FileNotFoundError, ValueError):
        return None


def save(path, last):
    with open(path + ".tmp", "w") as f:
        f.write(str(last))
    os.replace(path + ".tmp", path)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--pool", default="rpool")
    ap.add_argument("--threshold", type=float, default=0.25,
                    help="log syncs of at least this many seconds")
    ap.add_argument("--interval", type=float, default=30,
                    help="seconds between reads of the history")
    ap.add_argument("--state", default="/run/slow-txg-log/last-txg")
    ap.add_argument("--once", action="store_true", help="one read, then exit")
    args = ap.parse_args()

    last = load(args.state)
    print(f"start pool={args.pool} threshold_s={args.threshold} "
          f"after_txg={last}", flush=True)
    while True:
        with open(KSTAT.format(pool=args.pool)) as f:
            rows = parse(f.read())
        lines, last = process(rows, last, args.pool, args.threshold,
                              time.time_ns(),
                              time.clock_gettime_ns(time.CLOCK_MONOTONIC_RAW))
        for line in lines:
            print(line, flush=True)
        if last is not None:
            save(args.state, last)
        if args.once:
            return
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
