# SkyWatch: DevOps Home Assignment (SpeedData)

A small weather-query app (Flask frontend -> Flask backend -> Open-Meteo), built, shipped and run with
Terraform, Ansible, K3s, Helm, GitHub Actions, GHCR and ArgoCD.

> **Status:** work in progress. The application and its containers are complete and tested locally.

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

## Documentation

- [Architecture decisions](docs/decisions.md)
- [Problems and solutions](docs/problems.md)
