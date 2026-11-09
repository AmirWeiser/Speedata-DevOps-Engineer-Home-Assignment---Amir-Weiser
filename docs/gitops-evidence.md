# GitOps Evidence

Sections 1-6: local k3d cluster (Stage 1E). [Section 7](#7-aws-deployment-2026-11-09): AWS EC2 cluster.

Sections 1-6 ran against the local k3d cluster (K3s v1.37.2, 1 tainted server + 2 workers) with Argo CD v3.5.5.
"Full path" requests go browser -> frontend NodePort -> backend -> Open-Meteo, once per second.

## 1. Bootstrap and adoption

- `scripts/bootstrap-argocd.sh` on the existing cluster: Application `skywatch` **Synced/Healthy** at `e048b0f`.
- Adoption of the previously Helm-installed resources: **identical pod UIDs** before and after (no restarts).
- Namespace label `pod-security.kubernetes.io/enforce=restricted` applied by Argo CD from Git.

## 2. Application change -> running in the cluster (no manual commands)

Commit `2a166c3` "feat(frontend): credit Open-Meteo in the page subtitle",
[CI run 42205195222](https://github.com/AmirWeiser/Speedata-DevOps-Engineer-Home-Assignment---Amir-Weiser/actions/runs/42205195222):

| Time | Event |
|---|---|
| +0 s | push |
| +105 s | tests, build/scan/smoke/publish (both images), `update image tags`: all success |
| +108 s | `2c3c889` by github-actions[bot]: `deploy: images 2a166c3 [skip ci]` (2-line tag diff) |
| +127 s | workflow runs started by `2c3c889`: **0** |
| +128-143 s | Argo CD synced `2c3c889`; rolling updates complete; **Synced/Healthy** |

- All 4 pods run `:2a166c397cbad3a45cb709bfd417a84035da5acd`, the tag in `values.yaml`; one frontend and one backend per worker.
- Full-path requests during the whole flow: **121, non-200: 0**.
- Page now reads "Current weather for any city, powered by Open-Meteo."

## 3. A failed CI run promotes nothing

Commit `036abb0` broke one backend test on `main`,
[CI run 42205548960](https://github.com/AmirWeiser/Speedata-DevOps-Engineer-Home-Assignment---Amir-Weiser/actions/runs/42205548960):
`test (backend)` failure; `image` and `update image tags` **skipped**; `values.yaml` unchanged. After 225 s (longer than
Argo CD's polling interval) all pods still ran `2a166c3`.

Reverted by `2c18aa3` ([CI run 42206076668](https://github.com/AmirWeiser/Speedata-DevOps-Engineer-Home-Assignment---Amir-Weiser/actions/runs/42206076668)):
success, tag commit `5792053`, 0 runs for the tag commit, Argo CD synced and rolled all 4 pods to `2c18aa3`
(Synced/Healthy, 0 non-200 responses observed).

## 4. Stale tag updates are refused

Re-ran only the `update image tags` job of the older run 42205195222 (commit `2a166c3`) after `values.yaml` pointed to
the newer `2c18aa3`. Log: `values.yaml points to 2c18aa3..., which is newer than 2a166c3...; skipping stale update`.
`main` unchanged.

## 5. Self-heal

| Manual change | Reverted after |
|---|---|
| `kubectl scale deploy/skywatch-backend --replicas=3` | 7 s |
| `kubectl patch cm skywatch-backend` (`UPSTREAM_READ_TIMEOUT` 4 -> 99) | 3 s |
| `kubectl delete svc skywatch-backend` | 10 s (recreated) |

## 6. Reproducible from scratch

Fresh cluster `skywatch-repro` from `infra/local/k3d.yaml` (name/port changed) + `scripts/bootstrap-argocd.sh` only:
Synced/Healthy in 349 s total, no Helm release for the app, restricted label present, 2+2 pods spread across workers on
`2c18aa3` (= `values.yaml`), page served with the new subtitle. Cluster deleted afterwards.

## 7. AWS deployment (2026-11-09)

Cluster: 3 EC2 instances in `us-east-1a` (`skywatch-cp` t3.small, tainted; `skywatch-worker-1/2` t3.medium), K3s
`v1.37.2+k3s1` installed by Ansible, Argo CD v3.5.5. All times UTC.

### 7.1 Provisioning

| Step | Result |
|---|---|
| `terraform plan` | `26 to add, 0 to change, 0 to destroy`; only external ingress CIDR = the admin /32 |
| `terraform apply` | 26 resources created. The bootstrap failed twice: an operator shell without `~/.local/bin` on `PATH`, then a GitHub 504 on one worker's K3s download ([problems](problems.md#aws-deployment)). Only `terraform_data.bootstrap` was tainted; the third apply (`1 added, 1 destroyed`, about 3 min) completed K3s and Argo CD |
| Drift check | `terraform plan -detailed-exitcode` -> `No changes` (exit 0) |
| Ansible idempotency | Second `ansible-playbook site.yml` on the running cluster: `changed=0 failed=0` on `localhost`, `skywatch-cp`, `skywatch-worker-1`, `skywatch-worker-2` (43 s) |

### 7.2 Validation

| Check | Result |
|---|---|
| EC2 | 3/3 `running`, instance, system and EBS status checks `ok` |
| Nodes | 3/3 Ready; `skywatch-cp` has `node-role.kubernetes.io/control-plane:NoSchedule`, workers untainted |
| Pods | 2 frontend + 2 backend Ready, one of each per worker, 0 restarts |
| Helm settings live | backend ClusterIP 8000, frontend NodePort 30080; 2 ready endpoints each; PDBs `minAvailable 1`; probes on `/healthz`; requests 50m/64Mi, limits 500m/128Mi; UID 10001, read-only root FS, all capabilities dropped, seccomp RuntimeDefault; `preStop` sleep 5 s; spread `DoNotSchedule` + `nodeTaintsPolicy: Honor` |
| Pod Security | namespace label `pod-security.kubernetes.io/enforce=restricted` (set by Argo CD) |
| Argo CD | Synced / Healthy, `operationState` Succeeded |
| App | `/healthz` 200 on both workers; `?city=Haifa` shows Open-Meteo data (temperature, conditions, humidity, wind) |
| Errors | 200-char city -> 400 "must be at most 100 characters"; unknown city -> 404 "city '...' not found"; `<script>` in input is HTML-escaped. Backend JSON in-cluster: 200 / 404 / 400 |
| Exposure | backend Service is ClusterIP; from the admin IP, ports 8000, 8080, 10250 on a worker and 30080, 8000, 10250 on the control plane are closed |
| AWS security | SG ingress: 22/6443 (control plane) and 22/30080 (workers) from the admin /32 only; 6443, 10250, 8472/udp node-to-node only; egress 80/443 + intra-cluster; default SG empty. EBS gp3 encrypted; IMDSv2 `required`, hop limit 1; no instance profile |
| Rolling restart | `kubectl rollout restart` of both Deployments under load: **197/197** full-path requests 200, done in 14 s, pods respread one per worker, Argo CD stayed Synced |
| Metrics | metrics-server v0.9.0 (bundled with K3s) Available; `kubectl top`: nodes 27-58m CPU, app pods 1m CPU and 43-48Mi each |

### 7.3 GitOps rollouts on AWS

**Frontend change** `cf2762c` "feat(frontend): update homepage title for AWS demo" (pushed by the developer),
[CI run 42588865133](https://github.com/AmirWeiser/Speedata-DevOps-Engineer-Home-Assignment---Amir-Weiser/actions/runs/42588865133):

| Time | Event |
|---|---|
| 08:50:29 | CI run started (push) |
| 08:50:45 | `test (backend)`, `test (frontend)` success |
| 08:51:37 | `image (backend)`, `image (frontend)` success (build, Trivy, smoke test, publish) |
| 08:51:43 | `ed01374` by github-actions[bot]: `deploy: images cf2762c [skip ci]`; 0 workflow runs for it |
| 08:51:57 | Argo CD deployed `ed01374` (automated sync policy, from Argo CD history) |

**Image change** `e91567c` "fix(images): disable the unused gunicorn control socket",
[CI run 42590193441](https://github.com/AmirWeiser/Speedata-DevOps-Engineer-Home-Assignment---Amir-Weiser/actions/runs/42590193441),
measured from the push with one full-path request per second against the AWS NodePort:

| Time | Event |
|---|---|
| +0 s (09:01:26) | push |
| +84 s | CI success: tests, both images, `update image tags` |
| +87 s | `d6563b7` by github-actions[bot]: `deploy: images e91567c [skip ci]` (two-line diff); 0 workflow runs for it |
| +234 s | Argo CD deployed `d6563b7` (automated sync policy) |
| +256 s | AWS: all 4 pods on `e91567ce152c1884f2d21d37984483fac13adbf7`, Synced/Healthy |
| +258 s | local k3d: same revision and images, Synced/Healthy |

- Full-path requests on AWS during the flow: **152, non-200: 0**.
- New pods log no `Control server error` (0 lines; the previous image logged one per pod start).
- Screenshots: [CI run](images/ci-run.png), [tag commit](images/ci-tag-commit.png),
  [Argo CD tree](images/argocd-tree.png), [Argo CD history](images/argocd-history.png),
  [application on AWS](images/app-aws-haifa.png).

### 7.4 Not tested on AWS

Deliberately not done (would disrupt the running environment): node drain, worker replacement
(`terraform apply -replace`), control-plane failure, self-heal tests (done on k3d, section 5).
