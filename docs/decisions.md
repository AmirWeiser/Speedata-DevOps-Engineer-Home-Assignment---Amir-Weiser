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
