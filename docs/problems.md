# Problems and Solutions

Real issues encountered during the project, with root cause and fix.

## AWS deployment

### First apply: SSH timed out from a public Wi-Fi network
- **Symptom:** all 26 resources were created and the instances passed status checks, but Ansible could not reach port 22.
- **Root cause:** the network allowed outbound traffic only to 80/443/8080. Tested against portquiz.net and `github.com:22`: ports 22, 6443 and 30080 timed out.
- **Fix:** destroyed the environment and redeployed from a network that allows these ports. Preflight now includes an outbound check (`timeout 5 bash -c 'echo > /dev/tcp/portquiz.net/22'`).

### Bootstrap exit 127: `ansible-playbook` not found
- **Root cause:** `terraform apply` ran from a non-login shell, so `~/.local/bin` (where pipx installs Ansible) was not on `PATH`.
- **Fix:** run Terraform from a normal login shell. Only `terraform_data.bootstrap` was tainted; no instance was recreated.

### One worker failed to install K3s: `[ERROR] Download failed`
- **Symptom:** `skywatch-worker-2` failed in 0.14 s; the control plane then timed out waiting for 3 Ready nodes.
- **Root cause:** GitHub release downloads returned HTTP 504 from every network (home and EC2) during a GitHub incident ("increased timeouts due to surge in anonymous users"). The other nodes had downloaded just before.
- **Fix:** the K3s installer task retries 5 times, 30 s apart, in both roles. Safe to repeat: the script installs only after the binary's checksum verifies. ansible-lint production profile clean; the next apply completed.

### `Control server error: Read-only file system: '/home/app'` at every pod start
- **Root cause:** gunicorn 26 opens a runtime control socket under `$HOME` by default; the root filesystem is read-only. Harmless (the app served normally) but noisy, and present since the gunicorn 26 upgrade.
- **Fix:** `--no-control-socket`. Nothing uses the control interface (Kubernetes manages the process), so disabling it is smaller than adding a writable path. Verified with `docker run --read-only --cap-drop ALL` and on both clusters after the GitOps rollout (0 occurrences).

## Pre-apply review (Stage 2)

### Bootstrap could start before the security group rules existed
- **Root cause:** `aws_instance` depends on its security groups, but the rules are separate `aws_vpc_security_group_*_rule` resources created in parallel. `terraform_data.bootstrap` waited only for the instances, so Ansible could race the SSH, egress and K3s port rules (masked by the SSH retry, not prevented).
- **Fix:** explicit `depends_on` on every rule resource.

### A replaced worker could not rejoin
- **Root cause:** K3s protects node names with `kube-system/<node>.node-password.k3s` (verified on the local cluster). A new machine with the same node name presents a different password and is rejected.
- **Fix:** when a host has no K3s installed, the agent role deletes the old Node and its node-password secret (from the server) before installing. Never runs on a working node or during an upgrade.

### Argo CD bootstrap was "idempotent" only by suppressing change reporting
- **Root cause:** `changed_when: false` hid that every run executed `helm upgrade`, creating a new Helm revision.
- **Fix:** the script records `chart=<version> values=<sha>` as the release description and skips Helm when it matches; Ansible reports `changed` from the script's real output. Verified on a throwaway cluster: second run "unchanged", Helm revisions stayed at 1, Application "unchanged".

### Bootstrap could target the wrong cluster
- **Fix:** `EXPECTED_CONTEXT` guard (Ansible sets `skywatch-aws`); verified it refuses a mismatching context with exit 1.

### Transient chart download failure (HTTP 504 from GitHub Releases)
- **Symptom:** observed twice while testing: `failed to fetch .../argo-cd-10.10.5.tgz : 504 Gateway Time-out`.
- **Fix:** 3 attempts with backoff around `helm upgrade --install`. Partially verified: after a 504 the script continued to register the Application (the test was then stopped by host memory pressure).

### Executable bit lost when a script was rewritten from Windows
- **Symptom:** `scripts/bootstrap-argocd.sh: Permission denied` in testing after the file was rewritten through the `\\wsl.localhost` share (new file mode 0644).
- **Fix:** `chmod +x`; checked that git still records `100755` before committing. Would otherwise have failed the first AWS bootstrap.

### Secret scan did not block commits
- **Fix:** `.githooks/pre-commit` runs gitleaks (pinned by digest) on staged changes and exits non-zero on a finding. Verified: full history (16 commits) clean; a staged fake token is blocked; the Jinja `token:` expression that the old regex flagged passes.

## AWS code (Stage 2, found during static validation)

### ansible-lint production profile: unprefixed role variables
- **Finding:** `var-naming[no-role-prefix]` for a `set_fact` and three `register:` variables inside the roles.
- **Fix:** renamed to `k3s_server_*` / `k3s_agent_*` (the API path `/readyz` in the command was deliberately left untouched).

### Issues caught by review before any run
- `cloud-init status --wait` exits 2 when boot finished with recoverable warnings; accepted rc 0 or 2 instead of failing.
- `kubectl wait --for=condition=Ready node --all` only waits for nodes that already registered, so a slow agent could pass the check; replaced with a retry until every inventory host is Ready.
- The implicit `localhost` is not in inventory groups; the Argo CD play reads `kubeconfig_path` from the server's hostvars.
- `admin_cidr` was removed from the bootstrap triggers: an IP change only needs security group updates, not a K3s re-run.

### Trivy findings on Terraform
- CRITICAL AWS-0104 (unrestricted egress) on the 80/443 rules: accepted with an inline, commented `#trivy:ignore` (nodes must reach CDN-backed registries and APIs).
- MEDIUM AWS-0178 (no VPC Flow Logs): accepted for an ephemeral demo, listed as a production improvement.

## GitOps / Argo CD (Stage 1E)

### A push started no workflows: `[skip ci]` in the commit message body
- **Symptom:** commit `3bd3232` (the Argo CD + CI change) produced 0 workflow runs.
- **Root cause:** its message body described the loop guards and contained the literal text `[skip ci]`. GitHub skips push workflows if that marker appears anywhere in the message.
- **Fix:** none needed for the files (no history rewrite); the next application commit exercised the pipeline. Rule: never write the skip marker in a human commit message.

### Test harness declared success before Argo CD had synced
- **Symptom:** the watcher reported "synced", then found `OutOfSync` and old images.
- **Root cause:** `.status.sync.revision` is the revision Argo CD *compared against*; it moves to the new commit as soon as the commit is detected (that is what OutOfSync means). The sync itself is reported in `.status.operationState` (`phase`, `syncResult.revision`).
- **Fix:** wait for `operationState.phase=Succeeded` at the expected revision, then for the rollouts and Synced/Healthy. The auto-sync had in fact completed 16 s later.

### Handing an existing Helm release over to Argo CD
- Argo CD does not use Helm release records. Leaving them would show a stale `helm list` entry and invite a `helm upgrade` that fights Argo CD. Deleted the `sh.helm.release.v1.skywatch.*` Secrets only; Argo CD adopted the running resources with identical pod UIDs.

### Cosmetic: yq drops blank lines; finalizer warning
- The first CI tag commit removed the blank lines between top-level sections of `values.yaml` (comments are kept). The format is stable afterwards, so later tag commits are two-line diffs.
- Kubernetes 1.37 warns that `resources-finalizer.argocd.argoproj.io` has no `/`. It is still Argo CD's documented cascade-delete finalizer.

### Local `main` falls behind after every deployment
- CI pushes the tag commit to `main`, so a developer must `git pull` (fast-forward) before the next push; otherwise the push is rejected as non-fast-forward. Documented in the README workflow.

## Helm / Kubernetes (Stage 1D)

### k3d cluster creation failed: host port 8080 already allocated
- **Symptom:** every `kubectl` call failed with `the server could not find the requested resource`; `k3d cluster create` had actually failed and rolled back (`Bind for 127.0.0.1:8080 failed: port is already allocated`).
- **Root cause:** the Docker Compose frontend was still running on 8080. With no cluster there was no kubeconfig, so kubectl fell back to its legacy default `http://localhost:8080`, reached our Flask frontend and got its 404 page.
- **Fix:** the k3d cluster maps host port **8081**, so Compose and k3d can run side by side.

### `helm upgrade` silently kept a previous `--set` value
- **Symptom:** after `helm upgrade --set backend.config.UPSTREAM_READ_TIMEOUT=5`, a later plain `helm upgrade` (meant to restore `values.yaml`) left pods with `5`.
- **Root cause:** when `helm upgrade` gets no values flags at all, Helm reuses the previous release's values. `helm get values` showed the leftover `{"UPSTREAM_READ_TIMEOUT": 5}`.
- **Fix:** `helm upgrade --reset-values`. Lesson for GitOps: imperative Helm releases can hold state that is not in Git; ArgoCD renders from Git every time, which removes this class of drift.

### Node drain caused 2 failed requests (frontend single replica)
- **Symptom:** draining the worker that hosted the frontend produced 2 `curl` empty replies (exit 52) out of 18 requests.
- **Root cause (timestamped):** the only frontend pod was evicted; the frontend had 0 ready endpoints for ~5.6 s while the replacement started. The backend never dropped below 1 ready endpoint (PDB + spread worked). Most requests still succeeded because Kubernetes falls back to terminating endpoints when none are ready and the `preStop` sleep kept the old pod serving; failures occurred between gunicorn shutting down and the new pod becoming ready.
- **Fix:** frontend `replicas: 2`, the same one-per-worker spread as the backend, and a frontend PDB `minAvailable: 1`. Re-test under load: drain 0 of 23 failed (min 1 ready endpoint per Service), 3 rolling updates 0 of 83 failed.

### Misleading `kubectl top` right after a rollout
- **Symptom:** immediately after a rollout, `kubectl top` listed only 2 of 4 pods at ~210m CPU each.
- **Root cause:** the pods were seconds old; metrics-server had not scraped the others yet, and ~210m was Python's import spike at startup.
- **Fix:** measure after pods settle (idle 1-2m; ~3 req/s full path 5-31m; peak memory 48-55Mi).

### k3d checksum verification
- `checksums.txt` lists files as `_dist/k3d-linux-amd64`; the prefix is stripped before `sha256sum -c`.

## CI (Stage 1C)

Found by rehearsing every CI command locally before the first run:

### Trivy image not on GHCR
- **Symptom:** `ghcr.io/aquasecurity/trivy:0.76.1` -> `denied`.
- **Root cause:** Aqua publishes the Trivy image to Docker Hub, ECR Public and mirror.gcr.io (same digest everywhere), not to GHCR.
- **Fix:** `public.ecr.aws/aquasecurity/trivy:0.76.1@sha256:790fd66d...` (official source, digest-pinned, avoids Docker Hub's anonymous pull limits on CI runners).

### `docker load` rejected the OCI archive
- **Symptom:** `invalid archive: does not contain a manifest.json` for a buildx `type=oci` export.
- **Root cause:** This Docker engine loads only Docker-format archives.
- **Fix:** buildx `type=docker` export, which writes both `manifest.json` and an OCI layout (`index.json`, `oci-layout`) into one tar. Verified: skopeo reads it as `oci-archive:` with the same digest buildx reported, and a push with `--preserve-digests` keeps that digest.

## Application (Stage 1B)

### Open-Meteo returns HTTP 200 for an unknown city
- **Symptom (observed against the live API):** `?name=xqzvbnm` -> `200 {"generationtime_ms": 0.08}`; there is no 404 and no empty `results` list, the key is simply absent.
- **Fix:** The client treats a missing or empty `results` key as `CityNotFound` (-> 404); a unit test uses the exact captured payload.

### ruff sorted our own modules as third-party imports
- **Symptom:** `I001 Import block is un-sorted` on `from weather import ...` / `from app import ...`.
- **Root cause:** ruff decides what is first-party from its `src` setting (default: the repo root). The service modules live in `app/backend` and `app/frontend`, so ruff saw them as unknown third-party packages.
- **Fix:** `src = ["app/backend", "app/frontend"]` in `pyproject.toml`.

### Multi-stage build produced a larger image
- See ADR-006: 140 MB vs. 129 MB because the copied virtualenv duplicates pip/setuptools. Kept single-stage.

## Workstation (Stage 1A)

### Docker CLI returned HTTP 500 from the engine API
- **Symptom:** `docker version` -> `500 Internal Server Error ... dockerDesktopLinuxEngine`.
- **Root cause:** The Docker Desktop backend had been waiting 363 hours for its engine VM (`docker-desktop` WSL distro, state *Stopped*) to answer its control API (`still waiting for init control API to respond`). The original boot failure was no longer in the rotated logs. A graceful `docker desktop restart` timed out because the backend itself was hung.
- **Fix:** Force-stop the Docker Desktop processes, `wsl --shutdown`, start Docker Desktop. No settings change or factory reset.

### New WSL user created as UID 1001, WSL fell back to root
- **Symptom:** `wsl -d Ubuntu-24.04` logged in as root; WSL error `getpwuid(1000) failed`.
- **Root cause:** Docker's WSL integration was enabled *before* the first-launch user setup. Docker injected a `docker` group with GID 1000, so `adduser` created the user as 1001:1001, while WSL registered `DefaultUid=1000`, a UID that belongs to nobody.
- **Fix:** `/etc/wsl.conf` `[user] default=amirweiser` (read at distro boot) and `usermod -aG docker amirweiser`. Lesson: create the distro user before enabling Docker integration.

### `docker` fell back to the Windows binary inside WSL
- **Symptom:** `type docker` resolved to `/mnt/c/Program Files/Docker/.../docker` while the Linux symlink was broken.
- **Root cause:** WSL appends the Windows `PATH` by default, so any missing Linux tool silently resolves to a Windows `.exe` (same risk for terraform, kubectl, helm, aws, python).
- **Fix:** `/etc/wsl.conf` `[interop] appendWindowsPath=false`; only VS Code's path is added back in `~/.profile`.

### `kubectl` resolved to Docker Desktop's bundled v1.34 instead of the pinned v1.37
- **Symptom:** `command -v kubectl` -> `/usr/local/bin/kubectl` (v1.34.1), not apt's `/usr/bin/kubectl` (v1.37.2).
- **Root cause:** Docker Desktop's WSL integration creates `/usr/local/bin/kubectl` (a symlink into its own cli-tools) every time it attaches, and `/usr/local/bin` precedes `/usr/bin` in `PATH`. v1.34 vs. a v1.37 API server is outside kubectl's supported +/-1 minor skew.
- **Fix:** `ln -sfn /usr/bin/kubectl ~/.local/bin/kubectl`; `~/.local/bin` is first in `PATH`. Deleting Docker's symlink would not last, since Docker recreates it.

### Docker integration lost after restarting the Ubuntu distro
- **Symptom:** After `wsl --terminate Ubuntu-24.04`, `docker: command not found`; the Docker Desktop log shows `distro agent Ubuntu-24.04 exited unexpectedly`.
- **Root cause:** Terminating the distro kills Docker Desktop's in-distro proxy. Docker Desktop then reports an error and waits for the user ("Restart the WSL integration") instead of retrying.
- **Fix / rule:** Do not terminate the distro while Docker Desktop runs. Recover with `docker desktop restart` (or the dialog button). A clean sequence (`wsl --shutdown`, start Docker Desktop, open Ubuntu) works, which matches a normal reboot.
