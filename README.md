# Velero DR Lab on kind (Docker Desktop, Apple Silicon)

**Learn and demo Kubernetes disaster recovery with Velero, using two local kind clusters and an S3-compatible bucket. No cloud account needed.**

- 📖 Technical review of Velero (v1.18): architecture, data paths, restore semantics, risks, alternatives
- 🛠️ Scripts that build the whole lab from a clean Mac: two kind clusters, SeaweedFS S3, Velero + Kopia
- 🎬 Five scripted DR flows with byte-level data verification, measured RTO/RPO, and presenter tooling
- 🧭 In-depth walkthrough: [`docs/demo-flows-explained.md`](docs/demo-flows-explained.md)

> ⚠️ Lab only: credentials in `scripts/env.sh` are throwaway demo values. Don't reuse this layout for production backups as-is.

```bash
git clone https://github.com/simonjday/velero-kind-dr-lab.git && cd velero-kind-dr-lab
./scripts/up.sh && ./demo/flow-1-namespace-restore.sh
```

Versions verified 2026-11-05 · Target: MacBook Pro M3, Docker Desktop, zsh

---

## 0. TL;DR

| Item | Choice | Why |
|---|---|---|
| Velero | **v1.18.4** (`velero/velero:v1.18.4`) | Latest stable release. The project is now a CNCF Sandbox project under `github.com/velero-io` |
| Object store plugin | **velero-plugin-for-aws v1.14.4** | Plugin v1.14.x is the documented pairing for Velero v1.18.x |
| Kubernetes | **kind v0.33.0, `kindest/node:v1.35.8`** (digest pinned) | Velero 1.18 is tested on 1.33.7, 1.34.1 and 1.35.0. The kind 0.33 default (1.37) is outside that tested range |
| "S3 bucket" | **SeaweedFS 4.45** S3 gateway as a plain Docker container on the `kind` network | No cloud account is needed. It sits **outside both clusters**, so it survives the loss of either one. MinIO community edition is archived and no longer ships images |
| Volume data path | **File System Backup (FSB) with Kopia** through the node-agent | kind has no snapshot-capable CSI driver. Restic backups are disabled in 1.17 and 1.18 |
| Topology | 2 clusters, `velero-primary` (BSL ReadWrite) and `velero-dr` (BSL **ReadOnly** until failover) | A real two-site DR pattern, and the setup Velero's migration guide recommends |

```
 ┌──────────────── Docker Desktop (Apple M3) · docker network "kind" ────────────────┐
 │                                                                                   │
 │  ┌─ kind: velero-primary ─┐                         ┌─ kind: velero-dr ─────────┐ │
 │  │ velero + node-agent    │   backups (RW)          │ velero + node-agent       │ │
 │  │ BSL: ReadWrite         │ ──────────┐   ┌──────── │ BSL: ReadOnly → RW on DR  │ │
 │  │ ns dr-demo (pg + web)  │           ▼   ▼  sync   │ ns dr-demo (restored)     │ │
 │  └────────────────────────┘     ┌──────────────┐    └───────────────────────────┘ │
 │                                 │  seaweedfs   │  container, named volume       │
 │                                 │  S3 :8333    │  velero-seaweedfs-data          │
 │                                 └──────┬───────┘                                 │
 └────────────────────────────────────────┼─────────────────────────────────────────┘
                                          │ 127.0.0.1:8333 (publicUrl for CLI logs/describe)
                                       your Mac
```

---

## 1. Technical review: Velero

### 1.1 What it is, and its status in late 2026

Velero backs up and restores Kubernetes **API objects** and **persistent volume data**. It also migrates them between clusters. It works at the Kubernetes API layer, not the hypervisor or storage layer. Backups are tarballs of JSON manifests plus volume data, written to object storage.

- **Governance:** Broadcom contributed Velero to the **CNCF Sandbox**, announced at KubeCon EU 2026 (Amsterdam). The repository now lives at `github.com/velero-io/velero`, and the old `vmware-tanzu/*` URLs redirect. Maintainers come from Broadcom, Red Hat and Microsoft.
- **Releases:** The v1.18 line is current, with v1.18.4 released on 28 Sep 2026. The v1.19 documentation is already published, so plan an upgrade path.
- **Downstreams:** Red Hat **OADP** (OpenShift API for Data Protection) is Velero packaged as an operator. That makes this lab directly relevant to OpenShift and RHACM estates.

### 1.2 Architecture

| Component | Role |
|---|---|
| `velero` Deployment | The controller manager. It reconciles the Velero CRDs and runs plugins as gRPC sub-processes (object store, volume snapshotter, backup and restore item actions) |
| `node-agent` DaemonSet | Optional. Hosts the FSB and data-mover controllers. It mounts `/var/lib/kubelet/pods` to read pod volumes |
| **BackupStorageLocation (BSL)** | The bucket and prefix, plus provider config. **The bucket is the source of truth.** Velero syncs Backup CRs from the bucket into any cluster that points at it. The default sync interval is 1 minute |
| VolumeSnapshotLocation (VSL) | Native cloud-disk snapshots (EBS, Azure Disk and similar). Not used in this lab |
| Backup / Restore / Schedule | Operational CRs. A Schedule is a cron (or `@every`) template that stamps out Backups with a TTL |
| PodVolumeBackup / PodVolumeRestore | Per-volume FSB work items |
| DataUpload / DataDownload | Per-volume CSI snapshot data-mover work items |
| BackupRepository | Kopia repository per (namespace, BSL). Maintenance runs as Jobs |

### 1.3 Ways to protect volume data

| Method | How | Portable across clusters/clouds? | Crash consistency | Lab fit |
|---|---|---|---|---|
| Native snapshots (VSL) | Cloud API snapshot of the disk | ❌ Same provider and region only | Point-in-time | ❌ None on kind |
| CSI snapshots | `VolumeSnapshot` through the CSI driver | ❌ The snapshot stays on the storage system | Point-in-time | ⚠️ Needs a CSI hostpath driver |
| **CSI snapshot data mover** | Snapshot, then mount it, then Kopia uploads it to the BSL | ✅ | Point-in-time | ⚠️ Possible extension (§5) |
| **File System Backup (Kopia)** | node-agent reads the **live** mounted volume and uploads it to the BSL | ✅ | **Not point-in-time.** Use hooks | ✅ **Used here** |

FSB facts that matter for this lab (Velero v1.18 docs):

- **Opt-in vs opt-out.** By default you opt in with the pod annotation `backup.velero.io/backup-volumes`. Opt-out mode means `--default-volumes-to-fs-backup` plus the exclusion annotation `backup.velero.io/backup-volumes-excludes`. The lab installs in opt-out mode so that no volume is silently missed.
- **Restic is being retired.** Restic-path backups are disabled in 1.17 and 1.18, though old restic backups can still be restored. In 1.19, restic backups and restores are both disabled. **Kopia is the only uploader for new backups.**
- **`hostPath` volumes are not supported. `local` PVs are.** This trap catches kind users: kind's default `standard` StorageClass (local-path-provisioner) creates **hostPath** PVs. The lab adds a `local-fsb` StorageClass with the `defaultVolumeType: local` annotation, so the PVs are `spec.local` and kubelet bind-mounts them where the node-agent can see them. `01-clusters.sh` checks this with a probe PVC.
- **How a restore works.** Velero injects an init container into each restored pod. The pod waits until every PodVolumeRestore has written its marker file into `.velero/` in the volume. The default FSB restore timeout is 4 hours (`--fs-backup-timeout`).

### 1.4 Backup and restore semantics

- **Additive, non-destructive restores.** Existing resources are **skipped** by default (`--existing-resource-policy=none`); ServiceAccounts are the exception and get merged. `update` patches existing objects. Velero **never rewinds a live PVC**: to roll back data, delete it or restore elsewhere and cut over.
- **Restore order is fixed and sensible.** The order is CRDs, Namespaces, StorageClasses, snapshot objects, PVs, PVCs, RBAC, Secrets, ConfigMaps, then Pods and the rest. You can tune it with `--restore-resource-priorities`.
- **Status and NodePorts.** `status` is stripped, and auto-assigned NodePorts are dropped unless you pass `--preserve-nodeports`.
- **Mutation on restore.** Use `--namespace-mappings`, the storage-class mapping ConfigMap (labels `velero.io/plugin-config: ""` and `velero.io/change-storage-class: RestoreItemAction`), label selectors, include/exclude filters and resource modifiers.
- **Version direction.** Velero does not support restoring into a cluster with a **lower** Kubernetes version than the source.
- **Cross-region.** The AWS and Azure plugins do not migrate snapshot data between regions. Use FSB or the data mover to make data portable.

### 1.5 Consistency: hooks

FSB copies a live filesystem. For databases, use **pre-backup exec hooks** (pod annotations `pre.hook.backup.velero.io/{container,command,on-error,timeout}`). Options include `CHECKPOINT`, `fsfreeze`, quiescing writers or taking a logical dump to the volume. Post-restore hooks (`post.hook.restore.velero.io/*`) or init-container hooks handle re-seeding. The lab's Postgres runs `CHECKPOINT` before backup. For production databases, prefer the database's own PITR (WAL archiving, CloudNativePG backups and so on). Treat Velero as the **namespace and config envelope**, not the DB backup tool.

### 1.6 Strengths

- The de facto open standard. It is portable, provider-agnostic and has a large plugin ecosystem, and it sits under neutral (CNCF) governance.
- The bucket-as-source-of-truth design makes **cross-cluster DR and migration** a natural, first-class flow.
- Fine-grained scope (namespaces, labels, resource types), restore-time mutation and hooks.
- Kopia gives deduplicated, incremental, encrypted repositories in any S3-compatible store.
- It is the engine behind OADP, so skills transfer directly to OpenShift.

### 1.7 Weaknesses and risks

| Risk | Impact | Mitigation |
|---|---|---|
| FSB is not point-in-time | Torn database pages or inconsistent multi-volume apps | Hooks. CSI snapshots plus the data mover where a CSI driver supports them. App-native backup for databases |
| Restore skips existing objects | "Restore did nothing" surprises; stale state survives | Delete first, or use `--existing-resource-policy=update`, or restore into a new namespace and cut over |
| Two RW clusters on one BSL | Split-brain: a revived old primary pushes stale backups, or GC deletes the other site's backups | **Make the standby BSL ReadOnly**. Fence the revived primary (Flow 5 does both) |
| GitOps controllers fight restores | ArgoCD self-heals or prunes restored objects, or vice versa | Decide who owns what: Argo owns stateless config, Velero owns state and non-Git objects. Pause Argo apps during a restore. Exclude Argo tracking labels if needed |
| Credentials | The BSL secret is plaintext in `velero install --dry-run` output | SealedSecrets or ESO. Least-privilege bucket policy. Bucket object-lock or versioning against ransomware |
| No control-plane backup | etcd, certificates and the cluster itself are out of scope | Rebuild the cluster from IaC or GitOps, then restore the workload. Back up etcd separately |
| Repo maintenance | Deleted backups don't free space until Kopia maintenance runs | Monitor the maintenance Jobs. Size the bucket accordingly |
| Scale | Very large namespaces or file counts make FSB slow | Data mover concurrency, node-agent resources, and splitting backups by namespace or label |

### 1.8 Alternatives (brief)

- **Red Hat OADP:** Velero as an operator for OpenShift. The default choice on OCP/RHACM.
- **Veeam Kasten K10:** Commercial. Policy UI, application-aware blueprints, broad CSI integration.
- **Trilio, CloudCasa, Portworx PX-Backup:** Commercial, often storage-integrated.
- **KubeStash (formerly Stash):** Open-core, restic- and kopia-based.
- **GitOps alone:** Restores stateless config only. It does not cover state, Secrets outside Git, or runtime-created objects. Use it alongside Velero, not instead of it.

### 1.9 Recommendations

1. **Lab and learning:** this repository: FSB with Kopia, an off-cluster S3, and two clusters.
2. **Enterprise OpenShift:** OADP with **CSI snapshots and the data mover** on ODF. A ReadOnly BSL on DR clusters. Velero CRs and BSLs managed through GitOps; Backups and Restores run as operational actions under change control. Run quarterly **restore tests with recorded RTO and RPO**. Flow 2 prints both.
3. **Databases:** use database-native PITR, and let Velero carry the namespace around it.
4. **Bucket hardening:** versioning and object-lock (WORM), a separate account or tenant, and least-privilege keys.

---

## 2. Object storage without S3: why SeaweedFS

- **MinIO community edition:** stopped shipping binaries and images in Oct 2025, went into maintenance mode in Dec 2025, and its repository was archived on 25 Apr 2026. **Not recommended for new labs.**
- **SeaweedFS:** the longest track record of the self-hosted options. One container provides master, volume, filer and S3 (`weed server -s3`), configured with an identities JSON file (`-s3.config`). S3 listens on port 8333.
- **Alternatives:** Garage (single binary, small footprint) and RustFS (newer, still at release-candidate stage). Velero only needs basic S3 plus path-style addressing.
- **Placement:** run it **outside** kind, on the `kind` Docker network:
  - Pods reach it as `http://seaweedfs:8333`. kind's DNS forwards to Docker's embedded resolver. The script checks this and falls back to the container IP if needed.
  - The Mac reaches it at `http://127.0.0.1:8333`. That address is set as `publicUrl`, so `velero backup logs` and `velero backup describe --details` work from the host.
  - Data lives in a named volume, so it survives `kind delete` (and `teardown.sh` without `--purge`).
- **Checksums:** the AWS plugin uses AWS SDK v2 flexible checksums. Some S3-compatible stores reject them, and the plugin README documents `checksumAlgorithm=""` for Ceph and B2. The lab sets it on the BSL as a harmless precaution.

---

## 3. Lab build

### 3.1 From a clean Mac (Apple Silicon)

This section assumes nothing is installed apart from macOS. Skip any step whose check already passes.

**Step 1: Xcode Command Line Tools** (provides `git`, `python3` and `make`)

```bash
xcode-select -p >/dev/null 2>&1 || xcode-select --install
```

**Step 2: Homebrew**

```bash
command -v brew >/dev/null || /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
# Apple Silicon installs to /opt/homebrew - add it to zsh
grep -q 'brew shellenv' ~/.zprofile 2>/dev/null || echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"
```

**Step 3: Docker Desktop**

```bash
brew install --cask docker-desktop      # cask was renamed from 'docker'
open -a Docker                          # first launch: accept the licence and grant the privileged helper
until docker info >/dev/null 2>&1; do sleep 3; done; echo "Docker Desktop is up"
```

Docker Desktop → **Settings → Resources → Advanced**:

| Setting | Minimum | Comfortable |
|---|---|---|
| CPUs | 4 | 6 |
| Memory | 8 GiB | 12 GiB |
| Disk | 40 GiB | 64 GiB |

Click **Apply & restart**. Two two-node clusters, Postgres and SeaweedFS together use about 5–6 GiB.

If Podman is also installed (it is in the main lab), point the Docker CLI back at Docker Desktop for this shell:

```bash
unset DOCKER_HOST
docker context use desktop-linux
docker info --format '{{.OperatingSystem}}'   # must print: Docker Desktop
```

**Step 4: CLI tools**

```bash
brew install kind kubectl jq
kind version && kubectl version --client && jq --version
```

The Velero CLI is **not** installed with brew. `00-prereqs.sh` downloads the pinned version, checks its sha256 against the release `CHECKSUM` file and installs it into `./bin`. That keeps it matched to the server version.

**Step 5: Get the lab files**

```bash
mkdir -p ~/labs && cd ~/labs
git clone https://github.com/simonjday/velero-kind-dr-lab.git
cd velero-kind-dr-lab
chmod +x scripts/*.sh demo/*.sh     # git preserves this, but harmless
```

**Step 6: Build the lab**

Either one command:

```bash
./scripts/up.sh          # ~5-8 min first run (mostly image pulls)
source scripts/env.sh    # puts ./bin/velero on PATH + exports names/versions
./scripts/status.sh
```

or one step at a time, so you can see each stage. The walkthrough is in §3.2.

### 3.2 Manual walkthrough: what each script does

Each script is idempotent and safe to re-run. The commands shown are the **key** ones; the full scripts in this repo add waits and checks around them.

**`00-prereqs.sh`: verify tools and install the Velero CLI**

```bash
docker info --format '{{.OperatingSystem}}'          # must be Docker Desktop
curl -fsSLO https://github.com/velero-io/velero/releases/download/v1.18.4/velero-v1.18.4-darwin-arm64.tar.gz
curl -fsSLO https://github.com/velero-io/velero/releases/download/v1.18.4/CHECKSUM
grep darwin-arm64 CHECKSUM; shasum -a 256 velero-v1.18.4-darwin-arm64.tar.gz   # must match
tar xzf velero-v1.18.4-darwin-arm64.tar.gz && install -m 0755 velero-v1.18.4-darwin-arm64/velero ./bin/velero
```

Check: `./bin/velero version --client-only` prints `v1.18.4`.

**`01-clusters.sh`: create the two kind clusters**

```bash
export KIND_EXPERIMENTAL_PROVIDER=docker
IMG='kindest/node:v1.35.8@sha256:07b2536e30b803ed61d1677a79df6115f798ce64c80f9e22f6ed45afd09323c0'
kind create cluster --name velero-primary --image "$IMG" --config config/kind-cluster.yaml --wait 120s
kind create cluster --name velero-dr      --image "$IMG" --config config/kind-cluster.yaml --wait 120s

# per cluster: FSB-compatible default StorageClass
kubectl --context kind-velero-primary apply -f k8s/storageclass-local-fsb.yaml
kubectl --context kind-velero-primary patch storageclass standard \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
# (repeat for kind-velero-dr)

# probe: PV must be spec.local, not hostPath
kubectl --context kind-velero-primary apply -f k8s/pv-probe.yaml
kubectl --context kind-velero-primary get pv -o jsonpath='{.items[0].spec.local.path}'
```

Checks:
- `kind get clusters` lists both clusters.
- `docker ps` shows four node containers.
- `kubectl --context kind-velero-primary get sc` marks `local-fsb (default)`.
- The script prints `PV is type 'local'`.

**`02-object-store.sh`: start the off-cluster S3 and create the bucket**

```bash
docker volume create velero-seaweedfs-data
docker run -d --name seaweedfs --restart unless-stopped --network kind \
  -p 127.0.0.1:8333:8333 -p 127.0.0.1:8888:8888 \
  -v velero-seaweedfs-data:/data -v "$PWD/.state/s3.json:/etc/seaweedfs/s3.json:ro" \
  chrislusf/seaweedfs:4.45 server -dir=/data -s3 -s3.config=/etc/seaweedfs/s3.json -master.volumeSizeLimitMB=1024

docker run --rm --network kind -e AWS_ACCESS_KEY_ID=velero -e AWS_SECRET_ACCESS_KEY=velero-lab-secret \
  -e AWS_DEFAULT_REGION=us-east-1 amazon/aws-cli:2.22.0 --endpoint-url http://seaweedfs:8333 s3 mb s3://velero

# can pods reach it by container name?
kubectl --context kind-velero-primary run s3-probe --rm -i --restart=Never \
  --image=curlimages/curl:8.11.1 -- -s -o /dev/null -w '%{http_code}' http://seaweedfs:8333/
```

Checks:
- `docker ps` shows `seaweedfs`.
- The probe prints an HTTP code, not `000`.
- `.state/s3url` holds the URL that worked.
- Optionally, browse the filer UI at <http://127.0.0.1:8888>.

**`03-install-velero.sh primary` and `03-install-velero.sh dr`: install Velero, node-agent and Kopia**

```bash
velero --kubecontext kind-velero-primary install \
  --provider aws \
  --image velero/velero:v1.18.4 \
  --plugins velero/velero-plugin-for-aws:v1.14.4 \
  --bucket velero \
  --secret-file .state/credentials-velero \
  --backup-location-config region=us-east-1,s3ForcePathStyle=true,s3Url=http://seaweedfs:8333,publicUrl=http://localhost:8333 \
  --use-volume-snapshots=false --use-node-agent --uploader-type kopia --default-volumes-to-fs-backup --wait

kubectl --context kind-velero-primary -n velero patch backupstoragelocation default --type merge \
  -p '{"spec":{"config":{"checksumAlgorithm":""}}}'
# same install on kind-velero-dr, then make the standby read-only:
kubectl --context kind-velero-dr -n velero patch backupstoragelocation default --type merge \
  -p '{"spec":{"accessMode":"ReadOnly"}}'
```

Check: `velero --kubecontext kind-velero-primary backup-location get` shows `Available`, and does the same on `kind-velero-dr`, where it shows `ReadOnly`.

**`04-deploy-demo-app.sh primary`: deploy the workload and seed data**

```bash
kubectl --context kind-velero-primary apply -f k8s/demo-app.yaml
kubectl --context kind-velero-primary -n dr-demo wait --for=condition=Ready pod/postgres-0 --timeout=180s
kubectl --context kind-velero-primary -n dr-demo exec postgres-0 -c postgres -- psql -U postgres -d demo -c \
  "CREATE TABLE IF NOT EXISTS orders(id serial PRIMARY KEY, item text NOT NULL, created_at timestamptz NOT NULL DEFAULT now());
   INSERT INTO orders(item) SELECT 'seed-' || g FROM generate_series(1,1000) g;"
```

Check: the script prints a fingerprint such as `1000:3f2a…`. Every demo flow compares against that value.

**Done.** `./scripts/status.sh` should show:
- both BSLs `Available` (primary `ReadWrite`, DR `ReadOnly`)
- no backups yet
- the `dr-demo` fingerprint on the primary

Continue with §4.

**Reset to the starting state**

Pick the lightest option that does the job:

| Situation | Command | Time | What it does |
|---|---|---|---|
| After any demo run (including Flow 2 with `stop` or `delete`) | `./scripts/reset.sh` | 2–4 min | Brings the primary back (starting stopped nodes, or rebuilding it if it was deleted). Deletes all schedules, restores and backups. Removes `dr-demo`, `dr-demo-clone` and `dr-demo-web` from both clusters. Sets the primary BSL to RW and DR to RO, makes the primary active, and redeploys and reseeds `dr-demo` on the primary with the writer off |
| Same, but keep the backup history | `./scripts/reset.sh --keep-backups` | 1–2 min | As above, but the backups stay in the bucket and both clusters keep listing them |
| Something is broken or you've been experimenting | `./scripts/teardown.sh --purge && ./scripts/up.sh` | 5–8 min | Full rebuild from nothing |
| Free Docker Desktop resources and keep the backups | `./scripts/teardown.sh` … later `./scripts/up.sh` | — | Clusters and the S3 container are removed, but the data volume stays. Backups re-sync into the rebuilt clusters within about 1 minute |

How `reset.sh` deletes backups: it deletes them **once, from the primary**. That clears the shared bucket, and DR's BSL sync then drops its own copies of the Backup CRs. Deleting from both sites would mean two writers racing on one bucket. Velero also removes each backup's Kopia snapshot, and Kopia maintenance reclaims the space later.

Check the result:

```bash
./scripts/status.sh        # primary RW / dr RO, no backups, dr-demo fingerprint on primary only
cat .state/active          # primary
```

### 3.3 Repository layout

```
velero-kind-dr-lab/
├── scripts/
│   ├── env.sh                  # all version pins & names
│   ├── lib.sh                  # helpers (bash 3.2-safe)
│   ├── 00-prereqs.sh           # tool checks + pinned, checksum-verified velero CLI → ./bin
│   ├── 01-clusters.sh          # kind clusters + local-fsb StorageClass + PV-type probe
│   ├── 02-object-store.sh      # SeaweedFS container, bucket, in-cluster reachability probe
│   ├── 03-install-velero.sh    # velero install (+ GitOps render) per cluster, BSL RW/RO
│   ├── 04-deploy-demo-app.sh   # Postgres + nginx, seeded data
│   ├── up.sh                   # all of the above
│   ├── status.sh               # BSLs, backups, PVBs, bucket, fingerprints
│   ├── reset.sh                # back to post-up.sh state without rebuilding
│   └── teardown.sh             # --purge also deletes backup data
├── demo/
│   ├── flow-1-namespace-restore.sh
│   ├── flow-2-cluster-dr.sh
│   ├── flow-3-schedules.sh
│   ├── flow-4-clone-and-selective.sh
│   ├── flow-5-failback.sh
│   ├── run-all.sh
│   ├── live-writes.sh          # order-writer on/off (1 insert/s) - makes RPO visible
│   ├── watch.sh                # live per-cluster dashboard for presenting
│   ├── presenter.sh            # tmux layout: primary | dr | driver
│   └── inspect-backup.sh       # open a backup: bucket objects, tarball, Kopia repo
├── docs/demo-flows-explained.md   # in-depth walkthrough + presenter guide
├── config/kind-cluster.yaml
├── k8s/{storageclass-local-fsb,pv-probe,demo-app}.yaml
├── jq/{backup-summary,podvolume-summary,bsl-summary}.jq
└── gitops/argocd-velero-primary.yaml   (+ rendered gitops/<role>/velero-install.yaml)
```

### 3.4 Notes

> **GitOps note:** the bootstrap is imperative, so the lab stays self-contained. `03-install-velero.sh` also renders `gitops/<role>/velero-install.yaml` with `velero install --dry-run -o yaml`. Commit that to Gitea and use `gitops/argocd-velero-primary.yaml` to put the Velero install under ArgoCD. Move the `cloud-credentials` Secret to SealedSecrets or ESO first. The Application ignores `/spec/accessMode` on the BSL, because failover flips it.
>
> The scripts pass `--context`/`-n` explicitly because they drive two clusters at once. Nothing depends on your current context.

---

## 4. Demo flows

> For a step-by-step account of what happens to every app object, what Velero does underneath, screen layout, talking points and diagrams, see **[`docs/demo-flows-explained.md`](docs/demo-flows-explained.md)**.

| Flow | Scenario | What it proves | Key Velero features |
|---|---|---|---|
| 1 | Namespace deleted by mistake | Operational restore, byte-identical data | `backup create --wait`, FSB/Kopia, pre-hook, restore init container |
| 2 | **Primary site lost** | Cross-cluster DR with measured **RTO and RPO** | Shared BSL, backup sync, ReadOnly standby, promotion |
| 3 | Ongoing protection | Schedules, TTL retention, pause and unpause, ad-hoc run from a schedule | `schedule create/pause`, `--from-schedule` |
| 4 | DR test or forensics without touching prod | Clone into a new namespace, selective restore, drift repair | `--namespace-mappings`, `--selector`, `--existing-resource-policy=update` |
| 5 | **Failback** | Fencing the revived primary, planned near-zero-RPO return | BSL mode swaps, schedule pause, stale-state handling |

Run them interactively (each step pauses) or end to end:

```bash
./demo/flow-1-namespace-restore.sh
./demo/flow-3-schedules.sh
./demo/flow-4-clone-and-selective.sh
DISASTER_MODE=stop ./demo/flow-2-cluster-dr.sh     # or DISASTER_MODE=delete for true loss
./demo/flow-5-failback.sh

DEMO_AUTO=1 ./demo/run-all.sh                     # everything, unattended

# Presenting: dashboards + visible data loss
./demo/presenter.sh                               # tmux: watch primary | watch dr | driver
./demo/live-writes.sh on                          # then run flow 2 to show lost writes = real RPO
```

Every flow checks its result with a **data fingerprint**: the row count plus an md5 over every row of `orders`, compared before and after.

### Suggested demo narrative (about 20 minutes)

1. Show the architecture diagram. Point out that the bucket sits outside both clusters.
2. Run `status.sh`. Show the BSLs: primary ReadWrite, DR ReadOnly. Show the empty backup list.
3. **Flow 1.** Delete the namespace, then restore it. Point out the injected restore init container.
4. **Flow 2** with `DISASTER_MODE=delete`. Read out the RPO and RTO the script prints.
5. **Flow 5.** Bring the primary back. Explain fencing: why a revived primary must not write.
6. Close on §1.7, the risks, and how this maps to OADP on OpenShift.

---

## 5. Extensions

- **CSI snapshot data mover:** install `csi-driver-host-path` with the external-snapshotter CRDs and controller, plus a `VolumeSnapshotClass` labelled `velero.io/csi-volumesnapshot-class: "true"`. Then back up with `--snapshot-move-data`. Compare the DataUpload CRs with PodVolumeBackups, and compare consistency.
- **Storage-class remap on restore:** give the DR cluster a different StorageClass name and add the `change-storage-class` ConfigMap (§1.4).
- **Resource modifiers:** a JSON-patch ConfigMap applied at restore, for example to rewrite an image registry or ingress host for the DR site.
- **Observability:** Velero exposes Prometheus metrics on `:8085/metrics`. Add a ServiceMonitor and alert on `velero_backup_failure_total` and on the time since the last successful backup.
- **Kyverno guardrail:** a CEL `ValidatingPolicy` that requires a `backup.velero.io/backup-volumes` or `-excludes` annotation on any pod that mounts a PVC.
- **Ransomware drill:** turn on bucket versioning or object-lock, then delete a backup from the primary and show it can still be recovered.

---

## 6. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| BSL `Unavailable` | Pods can't reach `seaweedfs:8333`, or the credentials are wrong | `02-object-store.sh` writes the working URL to `.state/s3url`. Check `kubectl -n velero logs deploy/velero \| grep -i backupstoragelocation` |
| PodVolumeBackup missing, or "hostPath volumes are not supported" | The PVC used `standard` (hostPath) | Use `local-fsb`. Run `01-clusters.sh` again and check the probe output |
| `XAmzContentSHA256Mismatch` or checksum errors | SDK v2 flexible checksums | BSL `config.checksumAlgorithm: ""` (already set) |
| `velero backup logs` hangs from the Mac | `publicUrl` not reachable | Port 8333 must be published on 127.0.0.1. Check `docker ps` |
| Restore `PartiallyFailed`, pod stuck in Init | PodVolumeRestore still running or failed | `kubectl -n velero get podvolumerestores`, then `velero restore logs <name>` |
| DR cluster doesn't list the backup | Sync interval, or a different prefix or bucket | Wait about 1 minute. Both BSLs must use the same bucket and prefix |
| kind created clusters in Podman | Shell exports `KIND_EXPERIMENTAL_PROVIDER=podman` | `env.sh` overrides it to `docker` |

---

## 7. Verification log

| Check | Method | Result |
|---|---|---|
| Velero v1.18.4 is the latest stable release | GitHub releases page | ✅ 28 Sep 2026 |
| darwin-arm64 asset name and the `CHECKSUM` file | Downloaded `CHECKSUM` from the v1.18.4 release | ✅ `velero-v1.18.4-darwin-arm64.tar.gz` listed (sha256 `e51ce875…`) |
| Tarball layout `velero-vX-os-arch/velero` | Downloaded and verified the linux-amd64 tarball (`sha256sum -c` OK) | ✅ |
| Every `velero install` flag and the BSL config | `velero install … --dry-run -o yaml` with the exact lab flags, then parsed | ✅ BSL config, server args `--default-volumes-to-fs-backup=true --uploader-type=kopia`, node-agent mounts `/var/lib/kubelet/pods` |
| Every other Velero CLI flag used in the flows | Checked against `--help` for each subcommand (v1.18.4) | ✅ 22/22 present, including `schedule pause --all` and `@every` syntax |
| Plugin pairing v1.14.x ↔ Velero 1.18.x | Plugin README compatibility table | ✅ |
| k8s 1.35 within Velero 1.18's tested range | Velero README compatibility matrix | ✅ (1.33.7, 1.34.1, 1.35.0) |
| kind node image digest | kind v0.33.0 release notes | ✅ |
| local-path `defaultVolumeType: local` | local-path-provisioner README | ✅ (upstream marks it experimental; the lab probes it at runtime) |
| Shell scripts | `shellcheck -x` on all 13 scripts, plus `bash -n` | ✅ clean |
| YAML | `yamllint` (relaxed) | ✅ clean |
| jq filters | Run against sample Velero CR JSON | ✅ |
| **End-to-end run on Docker Desktop** | — | ⚠️ **Not executed.** The build sandbox could not pull from Docker Hub. The first `up.sh` run on your Mac is the integration test. It has self-checks: the PV-type probe, the S3 round-trip, the pod-to-S3 probe, BSL `Available`, and fingerprint asserts in every flow |

---

## 8. Sources

**Velero**
- Velero repo, compatibility matrix and CNCF Sandbox status: <https://github.com/velero-io/velero>
- Velero releases (v1.18.4): <https://github.com/velero-io/velero/releases>
- v1.18.4 release: <https://github.com/velero-io/velero/releases/tag/v1.18.4>
- v1.18.4 CHECKSUM: <https://github.com/velero-io/velero/releases/download/v1.18.4/CHECKSUM>
- Upgrade to 1.18 (plugin v1.14.0 pairing): <https://velero.io/docs/v1.18/upgrade-to-1.18>
- File System Backup (Kopia, restic deprecation, hostPath limitation, restore init container): <https://velero.io/docs/v1.18/file-system-backup>
- Restore reference (ordering, existing-resource-policy, namespace and storage-class mapping, FSB restore): <https://velero.io/docs/v1.18/restore-reference/>
- Cluster migration (shared bucket, `--access-mode=ReadOnly`, 1-minute sync, k8s version direction): <https://velero.io/docs/v1.18/migration-case/>
- Backup storage locations (dedicated bucket or prefix): <https://velero.io/docs/v1.18/locations/>
- CSI Snapshot Data Mover: <https://velero.io/docs/v1.18/csi-snapshot-data-movement>
- Repository maintenance: <https://velero.io/docs/v1.18/repository-maintenance>
- AWS plugin (compatibility table, `checksumAlgorithm` notes): <https://github.com/velero-io/velero-plugin-for-aws>
- AWS plugin releases (v1.14.4): <https://github.com/velero-io/velero-plugin-for-aws/releases>
- InfoQ, "Broadcom donates Velero to CNCF" (May 2026): <https://www.infoq.com/news/2026/05/broadcom-velero-cncf/>

**kind and storage**
- kind releases (v0.33.0, node image digests): <https://github.com/kubernetes-sigs/kind/releases>
- local-path-provisioner (`volumeType` / `defaultVolumeType`): <https://github.com/rancher/local-path-provisioner>

**Object storage**
- MinIO archival timeline and alternatives: <https://pinggy.io/blog/minio_archived_self_hosted_s3_alternatives/>
- SeaweedFS S3 API: <https://github.com/seaweedfs/seaweedfs/wiki/Amazon-S3-API>
- SeaweedFS S3 credentials (`-s3.config` identities JSON): <https://github.com/seaweedfs/seaweedfs/wiki/S3-Credentials>
- SeaweedFS Docker Compose for S3 (`chrislusf/seaweedfs`, port 8333, `weed server -s3 -s3.config`): <https://github.com/seaweedfs/seaweedfs/wiki/Docker-Compose-for-S3>
- SeaweedFS releases (4.45): <https://github.com/seaweedfs/seaweedfs/releases>

---

---

## Licence and author

MIT. See [LICENSE](LICENSE).

Written by Simon Day: [Medium @simonjday](https://medium.com/@simonjday) · [GitHub @simonjday](https://github.com/simonjday). Issues and PRs welcome.
