# SkyWatch: DevOps Home Assignment (SpeedData)

A small weather-query app (Flask frontend -> Flask backend -> Open-Meteo), built, shipped and run with
Terraform, Ansible, K3s, Helm, GitHub Actions, GHCR and ArgoCD.

> **Status:** work in progress. Stage 1A (workstation and repository setup) is complete.

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

## Documentation

- [Architecture decisions](docs/decisions.md)
- [Problems and solutions](docs/problems.md)
