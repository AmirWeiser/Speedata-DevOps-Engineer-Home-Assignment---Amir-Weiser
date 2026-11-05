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
