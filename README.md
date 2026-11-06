# SkyWatch: DevOps Home Assignment (SpeedData)

A small weather-query app (Flask frontend -> Flask backend -> Open-Meteo), built, shipped and run with
Terraform, Ansible, K3s, Helm, GitHub Actions, GHCR and ArgoCD.

> **Status:** work in progress. Application, CI (GHCR), Helm chart and the Argo CD GitOps flow are complete and
> validated end to end on a local k3d cluster. Next: AWS (Terraform + Ansible).

## Chosen path

The assignment's Path A topology (3 Ubuntu VMs, K3s installed by Ansible, 1 control plane + 2 workers)
**deployed on AWS EC2**, which the assignment lists as a bonus. See [ADR-001](docs/decisions.md).

## Workstation prerequisites

All tooling runs inside **WSL2 Ubuntu 24.04** ([ADR-002](docs/decisions.md)), with the repository on the Linux
filesystem. Docker is provided by Docker Desktop's WSL integration.

| Tool | Version |
|---|---|
| Terraform | 1.17.1 |
| ansible-core | 2.21.6 |
| kubectl | v1.37 |
| Helm | v4.3.1 |
| AWS CLI | v2 |
| gh, git, Python 3.12, Docker | current |

## Application

```
Browser ──GET /?city=Haifa──▶ frontend :8080 ──GET /api/weather?city=Haifa──▶ backend :8000 ──▶ Open-Meteo
                              (HTML page)        BACKEND_URL                   (JSON API)       geocoding + forecast
```

| Service | Endpoints | Configuration (env) |
|---|---|---|
| backend | `GET /api/weather?city=` → 200 / 400 invalid input / 404 unknown city / 502 upstream error / 504 upstream timeout; `GET /healthz` | `GEOCODING_URL`, `FORECAST_URL`, `UPSTREAM_CONNECT_TIMEOUT` (2), `UPSTREAM_READ_TIMEOUT` (4) |
| frontend | `GET /` (form), `GET /?city=` (result or error page); `GET /healthz` | `BACKEND_URL` (`http://localhost:8000`), `BACKEND_TIMEOUT` (15) |

`/healthz` never calls a dependency ([ADR-004](docs/decisions.md)). Errors are JSON `{"error": "..."}` on the
backend and a friendly message on the frontend; internal details are logged, not returned.

### Run locally

```bash
docker compose up --build        # http://localhost:8080
docker compose down
```

The backend has no published port (internal only, as in Kubernetes). Containers run as UID 10001 with a
read-only root filesystem and all capabilities dropped.

### Tests and lint

```bash
python3 -m venv .venv
.venv/bin/pip install --require-hashes -r app/backend/requirements.txt
.venv/bin/pip install --require-hashes -r app/frontend/requirements.txt
.venv/bin/pip install -r requirements-dev.txt

.venv/bin/ruff check app && .venv/bin/ruff format --check app
(cd app/backend && ../../.venv/bin/python -m pytest)
(cd app/frontend && ../../.venv/bin/python -m pytest)
```

Tests run per service (`python -m pytest` from the service directory) because both services have an `app`
module.

### Updating dependencies

Edit `requirements.in`, then regenerate the hash-locked `requirements.txt` in the same image the service runs on:

```bash
cd app/backend   # or app/frontend
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD:/w" -w /w python:3.12-slim-trixie sh -c \
  'pip install -q --user pip-tools==7.6.2 && /tmp/.local/bin/pip-compile -q --generate-hashes --strip-extras --no-emit-index-url -o requirements.txt requirements.in'
```

## CI: GitHub Actions -> GHCR

Workflows: [`ci.yml`](.github/workflows/ci.yml) (app) and [`chart.yml`](.github/workflows/chart.yml) (Helm lint).

```
test (backend, frontend)     image (backend, frontend)                    update image tags (push to main)
  ruff lint + format check     build once -> image.tar                      verify both SHA tags exist in GHCR
  pytest                       Trivy: vulnerabilities + Dockerfile config   write SHA into helm/skywatch/values.yaml
                               smoke test: read-only, /healthz, UID 10001   (forward-only), commit + push
                               [push to main] skopeo push, verify digest    -> Argo CD deploys it
```

| Event | `ci.yml` | `chart.yml` |
|---|---|---|
| Pull request to `main` | Always (tests, build, scan, smoke; publishes nothing) | Always |
| Push to `main` changing application code or workflows | Full run: publish images + update Helm tags | If chart/Argo CD files changed |
| Push to `main` changing only `docs/**`, `**.md`, `helm/**`, `argocd/**`, `infra/**` | Skipped (images unaffected) | If chart/Argo CD files changed |
| CI's own tag commit (`deploy: images <sha> [skip ci]`) | Not triggered (pushed with `GITHUB_TOKEN`) | Not triggered |

Note: a commit message containing `[skip ci]` anywhere skips every workflow for that push.

Images: `ghcr.io/amirweiser/skywatch-backend` and `ghcr.io/amirweiser/skywatch-frontend`, tagged with the
**full commit SHA** (no `latest`). The run summary records the tag and the digest. An existing SHA tag is never
overwritten. Design rationale: [ADR-007](docs/decisions.md).

## Kubernetes: Helm chart

Chart: [`helm/skywatch`](helm/skywatch). Design rationale: [ADR-008](docs/decisions.md).

```
NodePort 30080 ─▶ Service skywatch-frontend ─▶ frontend (2 pods, one per worker)
                                                  │ BACKEND_URL=http://skywatch-backend:8000 (ConfigMap)
                  Service skywatch-backend  ◀─────┘ ClusterIP, internal only
                          │
                  backend (2 pods, one per worker) ─▶ Open-Meteo
```

| Resource | Purpose |
|---|---|
| `backend-deployment`, `frontend-deployment` | Probes on `/healthz`, requests/limits, restricted security context, `preStop` sleep, `maxUnavailable: 0` |
| `backend-service` (ClusterIP), `frontend-service` (NodePort) | Backend is internal only; frontend is reachable from the host |
| `backend-configmap`, `frontend-configmap` | App settings as env vars; a `checksum/config` annotation rolls pods when they change |
| `backend-pdb`, `frontend-pdb` | A node drain always leaves one pod of each component serving |
| `tests/test-connection` | `helm test` for manual Helm installs (Argo CD does not run Helm test hooks) |

Render or lint locally without a cluster: `helm template skywatch helm/skywatch -n skywatch`,
`helm lint --strict helm/skywatch`.

## GitOps: Argo CD

Git is the only deployment interface. CI never talks to the cluster; it records in Git which images to run.

```
developer push (app code) ─▶ CI: test ─▶ build/scan/smoke ─▶ publish to GHCR ─▶ commit SHA into values.yaml
                                                                                        │
cluster ◀── rolling update ◀── Argo CD auto-sync (polls main every ~2-3 min) ◀───────────┘
```

| Piece | What it does |
|---|---|
| [`scripts/bootstrap-argocd.sh`](scripts/bootstrap-argocd.sh) | One-time, idempotent: installs Argo CD (chart 10.10.5 = v3.5.5, [`argocd/values.yaml`](argocd/values.yaml)) and applies the Application |
| [`argocd/skywatch-application.yaml`](argocd/skywatch-application.yaml) | Deploys `helm/skywatch` from `main`; automated sync with **prune** and **self-heal**; creates the namespace with the `restricted` Pod Security label |
| `update image tags` job in `ci.yml` | After both images are published, commits the commit SHA into `values.yaml` (never moves backwards) |

Design rationale and trade-offs: [ADR-009](docs/decisions.md). Evidence: [docs/gitops-evidence.md](docs/gitops-evidence.md).

### Bring up the local environment from scratch

[`infra/local/k3d.yaml`](infra/local/k3d.yaml) mirrors the AWS topology: 1 tainted control plane + 2 workers,
K3s v1.37.2, Traefik disabled, images pulled from GHCR. Requires Docker, k3d v5.9+, kubectl and Helm.

```bash
k3d cluster create --config infra/local/k3d.yaml
scripts/bootstrap-argocd.sh          # waits until the app is Synced and Healthy (~5 min on a laptop)
# App: http://localhost:8081/?city=Haifa   (8081 so it never collides with docker compose on 8080)
k3d cluster delete skywatch          # tear down
```

### Day-to-day workflow

1. Change application code, push to `main` (or open a PR first: it runs every check without publishing).
2. CI publishes images and pushes `deploy: images <sha> [skip ci]` to `main`. **Run `git pull` before your next
   commit**, since CI now commits too.
3. Argo CD rolls the cluster forward within a few minutes. Rollback = `git revert` the tag commit.

Never `kubectl edit`/`helm upgrade` managed resources: self-heal reverts manual changes within seconds.

### Inspecting Argo CD and the deployment

```bash
kubectl -n argocd get application skywatch                     # SYNC STATUS / HEALTH STATUS
kubectl -n argocd get application skywatch -o jsonpath='{.status.operationState.phase} {.status.operationState.syncResult.revision}{"\n"}'
kubectl -n argocd port-forward svc/argocd-server 8443:443      # UI: https://localhost:8443 (self-signed cert), user admin
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl get nodes                                              # server tainted, 2 workers
kubectl -n skywatch get pods -o wide                           # one frontend + one backend per worker
kubectl -n skywatch get deploy -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image'
kubectl -n skywatch get svc,endpointslices,pdb
kubectl -n skywatch top pods
kubectl -n skywatch logs -l app.kubernetes.io/name=backend -f  # access logs from both replicas
```

## Documentation

- [Architecture decisions](docs/decisions.md)
- [Problems and solutions](docs/problems.md)
- [CI evidence](docs/ci-evidence.md), [GitOps evidence](docs/gitops-evidence.md)
