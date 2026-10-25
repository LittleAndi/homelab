# Proxmox MicroK8s cluster — setup order

This automates the 5-VM MicroK8s cluster (3 control-plane, 2 worker)
designed in [ADR-0008](../../adr/adr-0008-proxmox-zfs-microk8s.md), on the ZFS mirror + NFS storage decided alongside it.

It does **not** cover migrating Nextcloud/MariaDB/Redis into the cluster —
that's a separate step (Helm chart or raw manifests) once the cluster
itself is healthy.

## Run order

0. **On the Proxmox host** — prerequisites (verified missing 2026-09-21):
   - **Wired network + `vmbr0`.** The host currently runs on Wi-Fi
     (`wlp5s0`, 192.168.1.10) and `nic0` is unconfigured. Wi-Fi can't be
     bridged, so plug in Ethernet and, in *pve > System > Network*, create
     Linux Bridge `vmbr0` with port `nic0`, address `192.168.1.10/24`,
     gateway `192.168.1.1`; remove the static IP from `wlp5s0`. Do this from
     the console or over Tailscale, not over the LAN IP you're moving.
   - **Host DNS fallback.** Host resolvers are Tailscale-only
     (`100.100.100.100`). Add `192.168.1.1` so apt/wget still work if
     tailscaled is down.
   - **Terraform API token.** Only `root@pam` exists. Create
     `terraform@pve` + an API token with a role covering VM.*, Datastore.*,
     SDN.Use and Sys.Audit. Keep it in the password manager and pass it as
     `TF_VAR_proxmox_api_token`, never in `terraform.tfvars` (that file is
     copied to Nextcloud by `backup-local.sh`).

   Addressing: Proxmox host `.10`; servers use `.20–.63`
   (cp1–cp3 `.20–.22`, wk1–wk2 `.23–.24`).

1. **On the Proxmox host** — one-time template creation:
   ```
   scripts/00-create-ubuntu-template.sh
   ```

2. **On the Proxmox host** — dataset `hdd-mirror/k8s` + NFS export to the 5
   node IPs only (the mirror itself is already created and healthy):
   ```
   scripts/01-setup-zfs-nfs.sh
   ```

3. **From your workstation** — provision the 5 VMs:
   ```
   cd terraform
   cp terraform.tfvars.example terraform.tfvars   # fill in real values
   terraform init
   terraform plan     # read this before applying anything
   terraform apply
   ```

4. **On the Proxmox host** — give the 3 control-plane disks a hard ZFS
   reservation so a worker's disk usage can never starve dqlite's writes
   (Terraform doesn't manage this directly — it's a property of the
   storage backend, not the VM):
   ```
   scripts/02-reserve-cp-disk-space.sh
   ```

5. **From your workstation** — cluster MicroK8s across all 5 VMs (own
   playbook, only `ansible.builtin`; version pinned in `ansible/vars.yml`):
   ```
   cd ansible
   ansible-playbook -i inventory.ini playbook.yml
   ```
   Installs the pinned channel, holds snap auto-refresh, joins cp2/cp3 as
   control plane and wk1/wk2 with `--worker` (one at a time), enables only
   dns (→ 192.168.1.1), rbac, metrics-server, helm3 and keeps
   hostpath-storage/registry/dashboard off. Safe to re-run. If a node runs a
   different channel it stops; `-e microk8s_reset=true` purges and
   reinstalls instead. Upgrades are manual, node by node.

6. **SSH into any control-plane node** — StorageClasses `nfs-client`
   (default, HDD via NFS) and `local-path` (SSD, node-local, for MariaDB):
   ```
   scripts/03-setup-nfs-provisioner.sh   # run this ON cp1, not your workstation
   ```

After step 6 you have a healthy 5-node cluster with `nfs-client` as the
default StorageClass (ZFS mirror) and `local-path` for SSD-backed volumes.

**Storage rule:** VM OS disks always on `local-zfs` (SSD). `hdd-mirror` is
for bulk data only, one dataset + export per consumer (see script 01). Next step from there is
deploying Nextcloud itself — happy to build that out separately.

## Off-site backup to Azure (ADR-0011 §3)

`hdd-mirror/k8s` goes to its own storage account every night. Names come
from `site.env` (`AZURE_OFFSITE_*`, `CRYPT_OFFSITE_REMOTE`); nothing here
is a real value. Use the Linux `az` in WSL: the Windows one's `-o tsv`
output ends in `\r`, which rclone rejects.

1. **From your workstation**: storage account, container, policy, SAS
   (`az login` first). The SAS URL goes to the host over ssh stdin, never
   to the screen or shell history:
   ```bash
   cd ~/src/homelab && . ./site.env
   RG=pve LOC=<region> ACCT=$AZURE_OFFSITE_ACCOUNT CONT=$AZURE_OFFSITE_CONTAINER
   az group show -n $RG -o none 2>/dev/null || az group create -n $RG -l $LOC -o none
   az storage account create -n $ACCT -g $RG -l $LOC \
     --sku Standard_LRS --kind StorageV2 --access-tier Cool \
     --https-only true --min-tls-version TLS1_2 \
     --allow-blob-public-access false --enable-hierarchical-namespace false -o none
   KEY=$(az storage account keys list -g $RG -n $ACCT --query '[0].value' -o tsv)
   az storage container create -n $CONT --account-name $ACCT --account-key "$KEY" \
     --public-access off -o none
   az storage container policy create -c $CONT -n rclone-host \
     --account-name $ACCT --account-key "$KEY" \
     --permissions racwdl --start <today>T00:00Z --expiry <today+1y>T00:00Z -o none
   SAS=$(az storage container generate-sas -n $CONT --policy-name rclone-host \
     --account-name $ACCT --account-key "$KEY" -o tsv)
   printf 'https://%s.blob.core.windows.net/%s?%s\n' "$ACCT" "$CONT" "$SAS" \
     | ssh root@pve "read -r u; rclone config create $AZURE_OFFSITE_REMOTE azureblob sas_url \"\$u\" >/dev/null && echo 'remote created'"
   unset KEY SAS
   ssh root@pve "rclone lsf $AZURE_OFFSITE_REMOTE:$AZURE_OFFSITE_CONTAINER && echo 'access ok'"
   ```

2. **On the Proxmox host**: crypt remote with generated passwords
   (`--obscure`, output discarded). **Then store `rclone.conf` in the
   password manager**: without `password`/`password2` the Azure copy is
   unreadable.
   ```bash
   rclone config create "$CRYPT_OFFSITE_REMOTE" crypt \
     remote "$AZURE_OFFSITE_REMOTE:$AZURE_OFFSITE_CONTAINER" \
     filename_encryption standard directory_name_encryption true \
     password "$(openssl rand -base64 32)" password2 "$(openssl rand -base64 32)" \
     --obscure >/dev/null
   ```
   (Set the two variables in the host shell first, or pass them in from
   the workstation as for step 1.) To rebuild the host from the password
   manager instead, put the stored `rclone.conf` back at
   `/root/.config/rclone/rclone.conf` (mode 600).

3. **On the Proxmox host**: the rendered `scripts/04-setup-azure-sync.sh`
   (`scripts/render.sh` on the workstation, then copy
   `.rendered/infra/proxmox-microk8s/scripts/04-setup-azure-sync.sh`).
   Check with `DRY_RUN=1 /usr/local/sbin/azure-sync-k8s`, then
   `systemctl start --no-block azure-sync-k8s.service` for the first
   upload; `journalctl -fu azure-sync-k8s.service` to follow it.

**Renewing the SAS** before the policy expires:
`az storage container policy update -c $CONT -n rclone-host --account-name $ACCT --account-key "$KEY" --expiry <new date>`.
The SAS URL on the host keeps working, because the expiry is the policy's.
**Revoking it:** delete the policy (`az storage container policy delete …`).
