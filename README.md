# SkyWatch: DevOps Home Assignment (SpeedData)

A small weather-query app (Flask frontend -> Flask backend -> Open-Meteo), built, shipped and run with
Terraform, Ansible, K3s, Helm, GitHub Actions, GHCR and ArgoCD.

> **Status:** work in progress. Application, CI (GHCR) and Helm chart are complete and validated on a local
> k3d cluster. Next: ArgoCD/GitOps, then AWS.

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

Workflow: [`.github/workflows/ci.yml`](.github/workflows/ci.yml)

```
test (backend, frontend)          image (backend, frontend), after both tests pass
  ruff lint + format check          build once -> image.tar
  pytest                            Trivy: vulnerabilities (image.tar) + Dockerfile misconfig
                                    smoke test: run image.tar read-only, /healthz 200, UID 10001
                                    [push to main] skopeo push image.tar -> verify digest unchanged
```

| Event | Runs? | Publishes? |
|---|---|---|
| Pull request to `main` | Always (no path filter, so it can be a required check) | No |
| Push to `main` touching anything other than `**.md` / `docs/**` | Yes | Yes |
| Push to `main` touching only `**.md` / `docs/**` | Skipped | No |

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
| `tests/test-connection` | `helm test`: both Services reachable by DNS from inside the cluster |

### Local cluster (k3d)

[`infra/local/k3d.yaml`](infra/local/k3d.yaml) mirrors the AWS topology: 1 tainted control plane + 2 workers,
K3s v1.37.2, Traefik disabled, images pulled from GHCR. Requires k3d v5.9+.

```bash
k3d cluster create --config infra/local/k3d.yaml
kubectl create namespace skywatch
kubectl label namespace skywatch pod-security.kubernetes.io/enforce=restricted
helm install skywatch helm/skywatch -n skywatch --wait
helm test skywatch -n skywatch
# App: http://localhost:8081/?city=Haifa   (8081 so it never collides with docker compose on 8080)
k3d cluster delete skywatch
```

### Inspecting the deployment

```bash
kubectl get nodes                                              # server tainted, 2 workers
kubectl -n skywatch get pods -o wide                           # placement: backend on different workers
kubectl -n skywatch get svc,endpointslices                     # ClusterIP backend, NodePort frontend
kubectl -n skywatch describe deploy skywatch-backend           # probes, resources, strategy, spread
kubectl -n skywatch top pods                                   # live CPU / memory
kubectl -n skywatch logs -l app.kubernetes.io/name=backend -f  # access logs from both replicas
kubectl -n skywatch exec deploy/skywatch-backend -- id         # uid=10001
helm -n skywatch get values skywatch                           # values that differ from values.yaml (should be null)
```

## Documentation

- [Architecture decisions](docs/decisions.md)
- [Problems and solutions](docs/problems.md)
