# GitOps Evidence (Stage 1E)

All tests ran against the local k3d cluster (K3s v1.37.2, 1 tainted server + 2 workers) with Argo CD v3.5.5.
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
