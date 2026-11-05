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
