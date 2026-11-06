#!/usr/bin/env bash
# One-time GitOps bootstrap for the cluster in the current kubectl context:
# installs Argo CD and registers the SkyWatch Application. Idempotent (safe to re-run).
# After this, deployments happen only through Git: no kubectl/helm deploy commands.
set -euo pipefail
cd "$(dirname "$0")/.."

ARGOCD_CHART_VERSION=10.10.5 # Argo CD v3.5.5

echo "==> Installing Argo CD (chart ${ARGOCD_CHART_VERSION}) into context $(kubectl config current-context)"
helm upgrade --install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm --version "${ARGOCD_CHART_VERSION}" \
  --namespace argocd --create-namespace \
  --values argocd/values.yaml \
  --wait --timeout 10m

echo "==> Registering the SkyWatch Application"
kubectl apply -f argocd/skywatch-application.yaml

echo "==> Waiting for SkyWatch to be Synced and Healthy"
for _ in $(seq 1 60); do
  status=$(kubectl -n argocd get application skywatch \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)
  [ "${status}" = "Synced/Healthy" ] && { echo "skywatch: ${status}"; exit 0; }
  sleep 5
done
echo "skywatch did not become Synced/Healthy within 5 minutes (last: ${status:-unknown})" >&2
exit 1
