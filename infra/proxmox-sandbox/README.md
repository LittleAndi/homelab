# Docker sandbox VM — setup order

Creates the sandbox VM designed in
[ADR-0016](../../adr/adr-0016-docker-sandbox-vm.md): a disposable Docker host,
started on demand, firewalled off the LAN and the tailnet. Plain host
scripts, no Terraform.

| | |
|---|---|
| VM | 111 `sandbox`, clone of 9000, 4 vCPU (`host`, `cpuunits` 25), 2 GB fixed + zram, 80 GB on `local-zfs` (I/O capped), `onboot=0` |
| IP | 192.168.1.26 (static via cloud-init), gateway/DNS 192.168.1.1 |
| In | SSH from `{workstation-ip}` on the LAN, or from members over the tailnet (`sandbox.{tailnet}.ts.net`) |
| Out | DNS to .1 and the internet; LAN, tailnet, multicast dropped; IPv6 off |

## Run order

1. **From the workstation** — render, copy the script and your public key:
   ```
   scripts/render.sh
   scp .rendered/infra/proxmox-sandbox/scripts/10-create-sandbox-vm.sh root@pve:/root/
   scp ~/.ssh/id_ed25519.pub root@pve:/root/sandbox.pub
   ```

2. **On the Proxmox host** — VM, firewall, start:
   ```
   SSH_KEY_FILE=/root/sandbox.pub bash /root/10-create-sandbox-vm.sh
   ```
   Stops if VMID 111 exists or .26 answers. Writes `host.fw` (`enable: 0`)
   *before* turning on the datacenter firewall. Afterwards check from the
   workstation that NFS, SMB, Grafana's host targets and `ssh root@pve` still
   work.

3. **From the workstation** — guest setup and isolation checks:
   ```
   ssh sandbox@192.168.1.26 'sudo bash -s' < infra/proxmox-sandbox/scripts/11-setup-sandbox-guest.sh
   ```
   Reboots the VM only if every check passes.

4. **Tailnet** — needs the policy from ADR-0016 (update 2026-10-27). Create
   an auth key: tag `tag:sandbox`, pre-approved, not reusable, not
   ephemeral, 1 day. Then, in your own terminal:
   ```
   scp infra/proxmox-sandbox/scripts/12-join-tailnet.sh sandbox@192.168.1.26:
   read -rs k; printf %s "$k" | ssh sandbox@192.168.1.26 'sudo bash 12-join-tailnet.sh'; unset k
   ```
   Rebuilding: remove the old `sandbox` device in the admin console first.

## Use

```
ssh root@pve qm start 111        # when needed
ssh sandbox@sandbox.{tailnet}.ts.net   # or sandbox@192.168.1.26 on the LAN
docker run --rm --memory 1g --cpus 2 --pids-limit 256 …   # always set limits
ssh root@pve qm shutdown 111     # when done
```

Copy results out (git, or SMB from the workstation); the VM disk is not
backed up.

## Notes

- Rebuild, don't repair: `qm stop 111 && qm destroy 111`, then steps 2–4.
  Script 10 leaves existing `host.fw`/`cluster.fw` alone if they're already
  set correctly, and rewrites `111.fw` and the nftables table.
- After any firewall change, rerun the checks (the end of script 11).
- Growing: `qm set 111 --memory 3072` (ADR-0016 first), or
  `qm disk resize 111 scsi0 +20G`.
