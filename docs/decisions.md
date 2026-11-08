# Architecture Decision Log

Short records of significant decisions: context, decision, consequences.

## ADR-001: Deploy on AWS (assignment bonus) with the Path A topology

- **Context:** The assignment's core targets a local cluster; AWS deployment is an explicit bonus.
- **Decision:** Run the Path A topology (3 Ubuntu VMs, K3s installed by Ansible, 1 control plane + 2 workers) on EC2 in `us-east-1`, provisioned by Terraform. Sizing: `t3.small` control plane, 2x `t3.medium` workers (configurable).
- **Consequences:** Real cloud networking and security groups; small hourly cost, so the environment is ephemeral (created, validated, destroyed). The README states this choice explicitly.

## ADR-002: Run the entire toolchain inside WSL2 Ubuntu 24.04

- **Context:** Ansible does not support Windows as a control node. Mixing Windows and Linux binaries breaks SSH key permissions (NTFS mounts show 0777) and Terraform `local-exec` paths.
- **Decision:** Terraform, Ansible, kubectl, Helm, AWS CLI and gh all run in WSL Ubuntu 24.04. The repo lives on the Linux filesystem (`~/projects/skywatch`). Windows `PATH` is not appended inside WSL (`appendWindowsPath=false`). Docker comes from Docker Desktop's WSL integration (no second engine).
- **Consequences:** One consistent Linux environment matching the EC2 nodes (Ubuntu 24.04). Windows tools are not reachable from WSL except VS Code, which is added explicitly.

## ADR-003: Pinned tool versions

| Tool | Version | Source |
|---|---|---|
| Terraform | 1.17.1 (apt-held) | HashiCorp apt repo |
| kubectl | v1.37.x (apt-held) | pkgs.k8s.io `v1.37` repo, matching K3s stable `v1.37.2+k3s1` |
| Helm | v4.3.1 | get.helm.sh tarball, sha256-verified |
| ansible-core | 2.21.6 | pipx (isolated venv) |
| AWS CLI | v2 | official installer, GPG-verified |
| gh | apt | GitHub CLI apt repo |

- **Why ansible-core 2.21 and not 2.22:** 2.22 requires Python >= 3.13 on the controller; Ubuntu 24.04 ships 3.12. 2.21.6 is the newest release supporting 3.12, avoiding a second Python installation.
- **Why kubectl v1.37:** kubectl supports +/-1 minor version skew against the API server; matching the K3s minor is simplest.

## ADR-004: Health endpoints check only the process, never dependencies

- **Context:** Kubernetes restarts containers that fail liveness and removes pods that fail readiness from Service endpoints.
- **Decision:** `/healthz` on both services returns 200 if the process can serve requests. It does not call Open-Meteo (backend) or the backend (frontend).
- **Consequences:** An Open-Meteo outage leaves all backend pods running and routable; users get a fast 502/504 with a clear message instead of a total outage or a restart loop. Dependency failures are visible through status codes and logs (and later, metrics), not through probes.

## ADR-005: Timeout budget and no retries

- **Decision:** Backend -> Open-Meteo: 2 s connect / 4 s read per call; two sequential calls, worst case ~12 s. Frontend -> backend: 15 s. Gunicorn worker timeout: 30 s. All configurable via environment variables.
- **Why:** Each layer times out after the layer beneath it, so the deepest failure is reported accurately (504 "timed out") instead of a confusing timeout one level up. No automatic retries: in a synchronous chain they multiply latency and upstream load; the user can resubmit.
- **Verified:** with an unroutable upstream the backend returns 504 after 2.06 s.

## ADR-006: Single-stage Dockerfiles, hash-locked dependencies

- **Measured:** single-stage 129 MB (+9.7 MB over `python:3.12-slim-trixie`) vs. multi-stage venv copy 140 MB (+20.8 MB). The copied venv carries its own pip/setuptools; there are no build-only tools to discard because every dependency is a prebuilt wheel.
- **Decision:** Single-stage. Revisit if a dependency ever needs compilation (gcc, headers), which is when multi-stage pays off.
- **Supply chain:** `requirements.in` (intent) -> `requirements.txt` locked with `pip-compile --generate-hashes`, installed with `--require-hashes`, so a modified or substituted package fails the build. The base image is pinned to Python minor + Debian release; digest pinning is a later improvement (it needs an automated updater to avoid stale, unpatched images).
- **Runtime:** numeric UID 10001, read-only root filesystem compatible (gunicorn `--worker-tmp-dir /dev/shm`), gunicorn gthread 1 worker x 4 threads (I/O-bound; scale with replicas).

## ADR-007: CI publishes the exact artifact that was tested

- **Context:** A common pipeline builds, scans, then rebuilds to push. The pushed image is then not provably the scanned one (base image tags and package indexes can change between builds).
- **Decision:** Build once with the buildx `docker` exporter to `image.tar`. That archive is both a Docker archive (`manifest.json`, so `docker load` works for the smoke test) and an OCI layout (`index.json`, so skopeo can push it). Trivy scans the archive, the smoke test runs it, and `skopeo copy --preserve-digests` pushes it unchanged. CI then compares the registry digest with the build digest and fails on mismatch.
- **Tags:** full commit SHA only; an existing tag is never overwritten (re-runs keep the original). The digest is the truly immutable reference and is recorded in the run summary.
- **Gate:** ruff, pytest, `--require-hashes`, Trivy vulnerabilities (HIGH/CRITICAL **with a fix available**), Trivy Dockerfile misconfig (HIGH/CRITICAL), smoke test (read-only FS, no capabilities, `/healthz`, UID 10001). `--ignore-unfixed` because the Debian base has ~46 HIGH CVEs with no upstream fix; blocking on them would keep CI red with nothing actionable.
- **Security:** `GITHUB_TOKEN` only (no stored secrets); `contents: read` globally, `packages: write` only on the image job; actions pinned to commit SHAs; checkout with `persist-credentials: false`; Trivy runs as a digest-pinned container instead of a third-party action, so no extra code runs with the job token.
- **Limitations (CI):** `skopeo` comes from the GitHub runner image (version not pinned by us). No image signing/SBOM attestation yet (cosign is a production improvement). Same-repo PRs run the image job with `packages: write` granted but unused, because permissions cannot be conditional per event.

## ADR-008: Helm chart design

- **Shape:** one chart, two explicit Deployments (no generic "component" template), per-service ConfigMaps via `envFrom`, ClusterIP backend, NodePort frontend, a backend PodDisruptionBudget and a `helm test` pod that reuses the backend image. `BACKEND_URL` is derived from the backend Service name in the template so the two cannot drift.
- **Config changes roll pods:** a `checksum/config` pod annotation; pods never reread a changed ConfigMap.
- **Backend spread, one replica per worker:** `topologySpreadConstraints` with `whenUnsatisfiable: DoNotSchedule`, `nodeTaintsPolicy: Honor`, `matchLabelKeys: [pod-template-hash]`.

  | Option | Normal | Worker lost / cordoned | Rolling update (`maxSurge 1`, `maxUnavailable 0`) |
  |---|---|---|---|
  | `ScheduleAnyway` | usually spread, not guaranteed | both on survivor | works, may end co-located |
  | required `podAntiAffinity` | spread | 2nd replica Pending | deadlocks (surge pod has no free node) |
  | **chosen** | spread | both on survivor (degraded, still 2 serving) | works, new revision spreads independently |

  `Honor` drops tainted nodes (the control plane, cordoned or unreachable workers) from the skew calculation; without it the unschedulable control plane counts as an empty domain. `matchLabelKeys` counts only pods of the same ReplicaSet, so old and new pods don't distort the spread mid-rollout. Accepted trade-off: if a worker is healthy but full, the second replica stays Pending instead of co-locating. Spread is evaluated only at scheduling, so after a worker returns a `rollout restart` rebalances.
- **Rollouts without errors:** `maxUnavailable: 0` plus a native `preStop: sleep 5s` so a terminating pod keeps serving until endpoint removal propagates; gunicorn then drains in-flight requests.
- **Security:** pod `runAsNonRoot`, UID/GID 10001, seccomp `RuntimeDefault`, no ServiceAccount token; container read-only root FS, no privilege escalation, all capabilities dropped. Verified against Pod Security Admission `restricted` (enforced on the namespace).
- **Resources (measured on k3d):** idle 2-3m CPU / 43-47Mi; full path at ~3 req/s 11-24m / 49Mi; peak memory 54Mi. Set requests 50m / 64Mi and limits 500m / 128Mi. A `/healthz` burst drove the frontend to 492m and it was throttled in 407 of 820 CFS periods: the CPU limit caps a noisy pod at the cost of latency under bursts (the assignment requires limits; without that requirement a CPU limit would be optional).
- **Frontend: 2 replicas + PDB, same spread policy.** With 1 replica, a node drain evicted the only frontend pod (evictions ignore `maxUnavailable`): ~5.6 s with no ready frontend endpoint, 2 of 18 requests failed. With 2 replicas + PDB `minAvailable: 1`: 0 of 23 failed during the drain, never fewer than 1 ready endpoint per Service. Cost: one more 64Mi pod.
- **Load distribution note:** kube-proxy balances connections, not requests. The frontend reuses keep-alive connections, so each frontend pod tends to stick to one backend pod (measured 5m vs 31m CPU under load). Expected L4 behaviour; per-request balancing would need an L7 proxy or service mesh.

## ADR-009: GitOps with Argo CD; CI writes image tags to Git

- **Ownership:** CI builds, verifies and publishes images, then records the image tag in Git. Argo CD is the only thing that changes the cluster. CI holds no cluster credentials, so a compromised pipeline cannot deploy arbitrary manifests, and every deployment is a Git commit (auditable, revertible).
- **Install:** `scripts/bootstrap-argocd.sh` runs `helm upgrade --install` of the pinned `argo-cd` chart (10.10.5 = v3.5.5; newest chart at least two weeks old) and applies the Application. Idempotent; on AWS the same two steps will run from Ansible. Argo CD does not manage itself (avoids a bootstrap chicken-and-egg); upgrading Argo CD = bump the pinned version and re-run.
- **Application:** source `helm/skywatch` on `main`, release name `skywatch`; `automated` with `prune` and `selfHeal`; `CreateNamespace` plus `managedNamespaceMetadata` so the Pod Security label lives in Git. Argo CD v3 tracks resources by annotation (`argocd.argoproj.io/tracking-id`), so it does not collide with the chart's `app.kubernetes.io/instance` selector label. Argo CD ignores Helm test hooks.
- **Detection:** polling (default 120 s + up to 60 s jitter). A GitHub webhook would be instant but needs the Argo CD server reachable from the internet, which a laptop cluster is not.
- **Tag update job:** runs only on push to `main`, only after both image jobs succeeded, re-checks both tags in GHCR, then edits `values.yaml` with `yq` and pushes with `GITHUB_TOKEN` (`contents: write` on this job only).
  - **No loops:** GitHub does not start workflows for `GITHUB_TOKEN` pushes; `[skip ci]` in the message and the `helm/**` path filter are extra guards. Verified: 0 runs for every tag commit.
  - **Concurrency / staleness:** main runs are serialized by the workflow concurrency group. In addition the job is forward-only: it updates only if the current tag is an ancestor of its own commit, so a slow or re-run job for an older commit cannot roll `main` back. It re-fetches and retries if `main` moved between commit and push. Verified by re-running an old job: skipped with a notice.
- **What a failed CI run means:** no image tags are written, so nothing new is deployed. Argo CD still syncs every commit on `main`, so a human commit that edits the chart or `values.yaml` deploys even if CI fails on that commit. The guard for that is branch protection with required PR checks (PR workflows have no path filters, so they can be made required).
- **Path filters:** image builds are skipped for docs, Helm, Argo CD and local-cluster-only pushes; `chart.yml` lints the chart on PRs and on chart pushes.
- **Handover from manual Helm:** on the existing cluster the Helm release records (`sh.helm.release.v1.skywatch.*` Secrets) were deleted, leaving resources in place; Argo CD adopted them with no pod restarts (same pod UIDs).

## ADR-010: AWS environment (Terraform + Ansible)

- **Topology:** dedicated VPC, one public subnet in one AZ, internet gateway; 1 K3s server (t3.small, tainted) + 2 agents (t3.medium). Single AZ because a single control plane gains nothing from a second AZ, and cross-AZ traffic would add cost.
- **No private subnets / NAT:** nodes need outbound access to GHCR, GitHub, Docker Hub and Open-Meteo; a NAT Gateway (~$0.045/h + data) would cost more than the workers. Each node has a public IPv4 ($0.005/h) and inbound access is controlled by security groups.
- **Security groups by role:** `cluster` (exact K3s node-to-node ports from the K3s documentation: 6443/tcp, 8472/udp, 10250/tcp; outbound 80/443), `control_plane` (22 and 6443 from `admin_cidr`), `workers` (22 from `admin_cidr`, NodePort 30080 from `app_cidrs`). The VPC default SG is emptied. Egress to `0.0.0.0/0` on 80/443 is an accepted Trivy finding (AWS-0104): destination filtering needs a proxy or firewall appliance.
- **Access:** SSH with a locally generated ED25519 key; Terraform only uploads the public key, so no private key is in state. SSM was rejected for complexity (S3 bucket, plugin, IAM role for Ansible). Host keys are trust-on-first-use in a per-deployment known_hosts file removed by `terraform destroy`.
- **Instances:** no IAM instance profile; IMDSv2 required with hop limit 1; encrypted gp3 root volumes deleted on termination; T3 unlimited (no throttling during load tests); latest Canonical Ubuntu 24.04 with `ignore_changes = [ami]`.
- **Terraform -> Ansible hand-off:** Terraform writes `ansible/inventory.generated.yml` (yamlencode, IPs only) and runs `ansible-playbook` from one `terraform_data` whose triggers are instance IDs/public IPs and the hash of the Ansible/Argo CD files. A failed run taints it, so the next `apply` retries; the playbook is idempotent. `run_ansible=false` separates the two steps. Terraform Helm/Kubernetes providers were rejected (they need a kubeconfig that only exists mid-apply).
- **Ansible:** K3s configured through `/etc/rancher/k3s/config.yaml` (template + restart handler), installed with the installer script from the pinned K3s tag only when the version differs (in-place upgrade, never uninstall). Agents join over the server's private IP with a token read from the server and held in memory only (`no_log`). Readiness: `/readyz`, then all inventory nodes Ready. The kubeconfig is rewritten to the public endpoint and context `skywatch-aws`, mode 0600, git-ignored. Argo CD is installed by the same script as locally, so both environments are bootstrapped identically.
- **State:** local and git-ignored (single operator, ephemeral environment). Teardown is complete because nothing inside Kubernetes creates AWS resources.
- **Pre-apply review changes:** the bootstrap waits explicitly for every security group rule (instances only depend on the groups, not the rule resources); a replaced worker's stale Node and node-password secret are removed before it joins under the same name; the Argo CD bootstrap is genuinely idempotent (chart version + values hash recorded as the Helm release description; unchanged = no upgrade), refuses any kube context other than `EXPECTED_CONTEXT`, and retries transient chart-download failures. Security groups re-checked against the official K3s inbound rules (6443/tcp, 8472/udp, 10250/tcp; VXLAN must not be public).
