# Nextcloud Podman → MicroK8s Migration Runbook

Companion to ADR-0010. Checked against the nextcloud Helm chart 9.3.0 on
2026-09-24.

**Approach:** a like-for-like move. The old install is carried over whole
(webroot with `config.php`, user data, database), so Nextcloud boots on the
cluster as the *same* instance: same `instanceid`/`secret`/`passwordsalt`,
same data path, same DB host name, same version (34.0.1), same hostname
(`nextcloud.{tailnet}.ts.net`). No fresh install, no config patching.
Upgrade to a newer 34.x afterwards, as a separate step.

**Downtime** is fine, so Part B simply stops the old stack. Part A can be
done any time while the old Nextcloud keeps running.

Files (all in `infra/proxmox-microk8s/nextcloud/`):
`storageclass-local-path-retain.yaml`, `pvcs.yaml`, `mariadb.yaml`,
`loader-pod.yaml`, `values.yaml`, `mariadb-dump-cronjob.yaml`.

Where commands run:

| Prompt | Machine |
|---|---|
| `PS>` | PowerShell on `{workstation}` (Podman runs from the Windows side) |
| `wsl$` | WSL on `{workstation}` (rsync/tar/ssh; `{old-stack-dir}` = `{old-stack-dir-wsl}`) |
| `k$` | anywhere with cluster access. On cp1: `ssh ubuntu@192.168.1.20`, then use `sudo microk8s kubectl` / `sudo microk8s helm3` for `kubectl` / `helm` |
| `pve#` | Proxmox host, `ssh root@pve` (192.168.1.10) |

## Inventory (done)

| | |
|---|---|
| Compose/config repo | `{old-stack-dir}\config` (`compose.yaml`, `.env`) |
| Nextcloud | `nextcloud:34-apache`, installed **34.0.1** |
| MariaDB | `mariadb:11.4`, DB and user both `nextcloud`, `dbhost` = `nextcloud-db` |
| Redis | none |
| Webroot | `{old-stack-dir}\data` → `/var/www/html` (code **and** data in one mount) |
| User data | `{old-stack-dir}\data\data` (`datadirectory` = `/var/www/html/data`) |
| Size | 209 GB, 237,761 files, 88,133 folders |
| Accounts | `{user}`, `{nc-admin}` |
| `instanceid` | `{nc-instanceid}` (`appdata_{nc-instanceid}`) |
| Third-party apps | none (`custom_apps` empty) |
| Skip when copying | `data/nextcloud.log` (594 MB log), webroot `nextcloud.log/` (a stray directory), `nextcloud-init-sync.lock` (the old container's entrypoint lock file, not needed) |

---

# Part A — preparation (old Nextcloud keeps running)

## A1. Tailscale operator

1. Tailnet policy file, add tag owners:
   ```json
   "tagOwners": {
     "tag:k8s-operator": [],
     "tag:k8s": ["tag:k8s-operator"]
   }
   ```
2. Admin console → Settings → OAuth clients → new client, tag
   `tag:k8s-operator`, with the write scopes the operator docs list
   (Devices Core and Auth Keys at minimum).
3. Install:
   ```bash
   k$ helm repo add tailscale https://pkgs.tailscale.com/helmcharts
   k$ helm repo update
   k$ helm install tailscale-operator tailscale/tailscale-operator \
        -n tailscale --create-namespace \
        --set-string oauth.clientId=<id> --set-string oauth.clientSecret=<secret>
   k$ kubectl get pods -n tailscale         # operator Running
   k$ kubectl get ingressclass              # "tailscale" listed
   ```
   HTTPS certificates and MagicDNS are already on in the tailnet (the Caddy
   setup uses them).

## A2. Namespace, StorageClass, Secrets

```bash
k$ kubectl create namespace nextcloud
k$ kubectl apply -f storageclass-local-path-retain.yaml
```

The DB Secret **reuses the current `MYSQL_PASSWORD`** from
`{old-stack-dir}\config\.env`. The migrated `config.php` already contains that
password, so it needs no edit. Rotate it later if you want. The root
password and the admin Secret are new (the admin one is never actually
used, because no fresh install runs):

```bash
k$ read -rs NC_DB_PW   # paste MYSQL_PASSWORD from the old .env
k$ kubectl -n nextcloud create secret generic nextcloud-db \
     --from-literal=db-username=nextcloud \
     --from-literal=db-password="$NC_DB_PW" \
     --from-literal=db-root-password="$(openssl rand -base64 24)"
k$ kubectl -n nextcloud create secret generic nextcloud-admin \
     --from-literal=nextcloud-username=admin \
     --from-literal=nextcloud-password="$(openssl rand -base64 24)"
k$ unset NC_DB_PW
```

## A3. Database and volumes

```bash
k$ kubectl apply -n nextcloud -f mariadb.yaml
k$ kubectl apply -n nextcloud -f pvcs.yaml
k$ kubectl -n nextcloud rollout status statefulset/nextcloud-db
k$ kubectl -n nextcloud get pvc      # nextcloud-data Bound; nextcloud-app Pending until step B4 (expected)
```

Find the NFS directory for `nextcloud-data` on the host:

```bash
pve# ls -d /hdd-mirror/k8s/nextcloud-nextcloud-data-*
```

Write it down; it's `<NFSDIR>` below.

## A4. Transfer tooling

```bash
pve# apt install -y rsync
wsl$ which rsync || sudo apt install -y rsync
wsl$ ssh root@pve true && ssh ubuntu@192.168.1.20 true   # both must work without a prompt
```

The NFS export only allows the five node IPs, so `{workstation}` can't mount it.
Data therefore goes to the host over SSH, straight into `<NFSDIR>`, which is
also faster than NFS.

## A5. (Optional) pre-copy the data

Step B3 works fine while Nextcloud is still running. Run it once now to
move the bulk of the 209 GB; the run during the window then only copies
the changes.

---

# Part B — migration window

## B1. Stop the old stack

Podman runs from the Windows side, so B1–B2 are PowerShell:

```powershell
PS> Set-Location {old-stack-dir}\config
PS> podman compose down        # no -v: the named volumes stay, for rollback
```

## B2. Dump the database

The dump is written inside the container and copied out with `podman cp`,
not redirected with `>`. Windows PowerShell 5.1 would write a `>`
redirect as UTF-16, which breaks the SQL file. The root password is
read from the container's own environment (set by compose), so `.env`
isn't parsed here.

```powershell
PS> Set-Location {old-stack-dir}\config
PS> podman compose up -d nextcloud-db
PS> do { Start-Sleep 3; podman exec nextcloud-db healthcheck.sh --connect --innodb_initialized *> $null } until ($LASTEXITCODE -eq 0)
PS> podman exec nextcloud-db sh -c 'mariadb-dump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines --triggers --result-file=/tmp/nextcloud-dump.sql nextcloud'
PS> podman cp nextcloud-db:/tmp/nextcloud-dump.sql {old-stack-dir}\nextcloud-dump.sql
PS> podman compose stop nextcloud-db
PS> (Get-Item {old-stack-dir}\nextcloud-dump.sql).Length / 1MB
PS> Get-Content {old-stack-dir}\nextcloud-dump.sql -Tail 1     # "-- Dump completed on ..."
```

The dump ends up at `{old-stack-dir}\nextcloud-dump.sql`
(`{old-stack-dir-wsl}/nextcloud-dump.sql` from WSL, which B5 reads).

## B3. Copy user data → HDD mirror

`--chown`/`--chmod` set the ownership Nextcloud needs (www-data = uid 33,
directory mode 0770). The files on the Windows drive have neither.

```bash
wsl$ rsync -rt --info=progress2 --delete \
       --exclude=/nextcloud.log \
       --chown=33:33 --chmod=D0770,F0660 \
       {old-stack-dir-wsl}/data/data/ root@pve:<NFSDIR>/data/
```

The chart mounts the `data/` subdirectory of the PVC, which is why the
target ends in `/data/`. If the transfer is interrupted, run the same
command again; it picks up where it stopped.

## B4. Copy the webroot (code + config.php + themes) → app volume

```bash
k$ kubectl apply -n nextcloud -f loader-pod.yaml
k$ kubectl -n nextcloud wait --for=condition=Ready pod/nc-loader
k$ kubectl -n nextcloud exec nc-loader -- mkdir -p /seed/html
```

Stream the webroot in, without `data/` and the three skip items:

```bash
wsl$ tar -C {old-stack-dir-wsl}/data \
       --exclude=./data --exclude=./nextcloud.log --exclude=./nextcloud-init-sync.lock \
       -cf - . \
     | ssh ubuntu@192.168.1.20 'sudo microk8s kubectl exec -i -n nextcloud nc-loader -- tar -C /seed/html -xf -'
```

Rearrange it into the chart's layout (it mounts `html/`, `config/`,
`custom_apps/`, `themes/`, `tmp/`, `root/` from this volume) and fix the
ownership:

```bash
k$ kubectl -n nextcloud exec nc-loader -- sh -c '
     set -e; cd /seed
     mv html/config config; mv html/themes themes; mv html/custom_apps custom_apps
     mkdir -p tmp root html/config html/themes html/custom_apps html/data
     chown -R 33:33 /seed
     grep -E "dbhost|datadirectory|instanceid|installed|version" config/config.php'
```

Expect `dbhost => 'nextcloud-db'`, `datadirectory => '/var/www/html/data'`,
`instanceid => '{nc-instanceid}'`, `installed => true`, `version => '34.0.1…'`.
Then:

```bash
k$ kubectl -n nextcloud delete pod nc-loader
```

## B5. Restore the database

```bash
wsl$ ssh ubuntu@192.168.1.20 \
       'sudo microk8s kubectl exec -i -n nextcloud nextcloud-db-0 -- sh -c "mariadb -u\$MARIADB_USER -p\$MARIADB_PASSWORD nextcloud"' \
     < {old-stack-dir-wsl}/nextcloud-dump.sql
k$ kubectl -n nextcloud exec nextcloud-db-0 -- sh -c \
     'mariadb -u$MARIADB_USER -p$MARIADB_PASSWORD nextcloud -e "select count(*) from oc_users; select count(*) from oc_filecache;"'
```

## B6. Free the hostname

Tailscale admin console → **Machines** → `nextcloud` → **Remove**. This is
the Caddy container's device. It's already offline since B1.

## B7. Install Nextcloud

```bash
k$ helm repo add nextcloud https://nextcloud.github.io/helm/
k$ helm repo update
k$ helm install nextcloud nextcloud/nextcloud -n nextcloud -f values.yaml
k$ kubectl -n nextcloud logs -f deploy/nextcloud -c nextcloud
```

If `ImagePullBackOff` says `34.0.1-apache` doesn't exist, use the nearest
34.0.x tag instead; the entrypoint then runs a normal patch upgrade, which
is fine ("Upgrading nextcloud from 34.0.1" in the log).

Otherwise, the log should **not** say "Initializing nextcloud" or "New nextcloud
instance". If it does, the webroot seed in B4 isn't where the chart expects
it: `helm uninstall`, fix it, and install again (the PVCs aren't owned by
the release and are left alone).

```bash
k$ kubectl -n nextcloud get ingress     # ADDRESS shows nextcloud.{tailnet}.ts.net
```

## B8. Post-start

```bash
k$ occ() { kubectl -n nextcloud exec deploy/nextcloud -c nextcloud -- su -s /bin/sh www-data -c "php occ $*"; }
k$ occ status                          # installed: true, version 34.0.1, maintenance: false
k$ occ background:cron                 # use the cron sidecar
k$ occ maintenance:data-fingerprint    # desktop/mobile clients re-check their state
k$ occ setupchecks                     # warnings only; review
```

`occ files:scan --all` isn't needed (same data path, and the file index came
over with the DB). Run it only if files look missing. It walks 237k files
over NFS, so it takes a while.

## B9. Verify

- [ ] `https://nextcloud.{tailnet}.ts.net` loads with a valid certificate
- [ ] Log in as `{user}` and `{nc-admin}`, open files in a few folders, check thumbnails
- [ ] Desktop/mobile sync clients reconnect without re-login (same instance)
- [ ] Upload a file, then delete it (write path + ownership OK)
- [ ] Admin → Overview has no data-directory permission or reverse-proxy warnings

## B10. DB backup job

```bash
k$ kubectl apply -n nextcloud -f mariadb-dump-cronjob.yaml
k$ kubectl -n nextcloud create job --from=cronjob/mariadb-dump dump-test
k$ kubectl -n nextcloud logs job/dump-test
pve# ls -lh <NFSDIR>/db-dumps/
```

## Rollback (any point before decommissioning)

Nothing in `{old-stack-dir}` is modified; B2–B4 only read from it.

```bash
k$ helm uninstall nextcloud -n nextcloud
```

Then create a new Tailscale auth key (the old device was removed), put it
in `TS_AUTHKEY` in the old `.env`, and `PS> podman compose up -d` in `{old-stack-dir}\config`.

## Afterwards

- A few stable days later: remove the Podman stack; keep `{old-stack-dir}` and
  `nextcloud-dump.sql` until the Azure backup covers `hdd-mirror/k8s`
  (ADR-0008 open item).
- Upgrade: set `image.tag` to the current 34.x (e.g. `34.0.4-apache`) in
  `values.yaml`, `helm upgrade`. The entrypoint runs `occ upgrade`.
