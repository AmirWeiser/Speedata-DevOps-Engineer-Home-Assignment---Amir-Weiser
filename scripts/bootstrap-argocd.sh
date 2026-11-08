#!/usr/bin/env bash
# One-time GitOps bootstrap for the cluster in the current kubectl context:
# installs Argo CD and registers the SkyWatch Application. Idempotent: a re-run with the
# same chart version and values changes nothing. After this, deployments happen only
# through Git: no kubectl/helm deploy commands.
#   EXPECTED_CONTEXT=<name>  optional guard: refuse to run against any other context.
set -euo pipefail
cd "$(dirname "$0")/.."

ARGOCD_CHART_VERSION=10.10.5 # Argo CD v3.5.5

context=$(kubectl config current-context)
if [ -n "${EXPECTED_CONTEXT:-}" ] && [ "${context}" != "${EXPECTED_CONTEXT}" ]; then
  echo "Refusing to run: current context is '${context}', expected '${EXPECTED_CONTEXT}'" >&2
  exit 1
fi

# Recorded as the Helm release description; identical marker = nothing to upgrade.
marker="chart=${ARGOCD_CHART_VERSION} values=$(sha256sum argocd/values.yaml | cut -c1-12)"
deployed=$(helm -n argocd history argocd --max 1 -o json 2>/dev/null | jq -r '.[0].description // empty' || true)

if [ "${deployed}" = "${marker}" ]; then
  echo "==> Argo CD already installed and unchanged (${marker}) in context ${context}"
else
  echo "==> Installing Argo CD (${marker}) into context ${context}"
  # The chart is downloaded from GitHub Releases; retry transient failures (e.g. HTTP 504).
  for attempt in 1 2 3; do
    helm upgrade --install argocd argo-cd \
      --repo https://argoproj.github.io/argo-helm --version "${ARGOCD_CHART_VERSION}" \
      --namespace argocd --create-namespace \
      --values argocd/values.yaml \
      --description "${marker}" \
      --wait --timeout 10m && break
    [ "${attempt}" = 3 ] && { echo "Argo CD install failed after 3 attempts" >&2; exit 1; }
    echo "==> Helm attempt ${attempt} failed; retrying in $((attempt * 15))s"
    sleep $((attempt * 15))
  done
fi

echo "==> Registering the SkyWatch Application"
kubectl apply -f argocd/skywatch-application.yaml # prints created / configured / unchanged

echo "==> Waiting for SkyWatch to be Synced and Healthy"
for _ in $(seq 1 60); do
  status=$(kubectl -n argocd get application skywatch \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)
  [ "${status}" = "Synced/Healthy" ] && { echo "skywatch: ${status}"; exit 0; }
  sleep 5
done
echo "skywatch did not become Synced/Healthy within 5 minutes (last: ${status:-unknown})" >&2
exit 1
