#!/usr/bin/env bash
# End-to-end check on a throwaway cluster (kind in CI, or locally):
# signature admission, Terraform apply of app + monitoring, Prometheus
# scrape targets, then the smoke test. Needs kubectl, helm, terraform, python3.
# Usage: KUBE_CONTEXT=kind-devops-lab k8s/kind-e2e.sh
set -euo pipefail
CTX=${KUBE_CONTEXT:-kind-devops-lab}
cd "$(dirname "$0")/.."
k() { kubectl --context "$CTX" "$@"; }
fail=0
pass() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fail=1; }

echo "== policy-controller"
helm repo add sigstore https://sigstore.github.io/helm-charts --force-update >/dev/null
helm upgrade --install policy-controller sigstore/policy-controller --version 0.10.8 \
  --kube-context "$CTX" -n cosign-system --create-namespace \
  -f k8s/policy/values.yaml --wait --timeout 5m
k apply -f k8s/policy/clusterimagepolicy.yaml

echo "== terraform apply"
terraform -chdir=terraform init -input=false -no-color >/dev/null
# Separate state from the OrbStack deployment when run on a laptop.
terraform -chdir=terraform workspace select -or-create e2e >/dev/null
terraform -chdir=terraform apply -input=false -auto-approve -no-color \
  -var kube_context="$CTX" | grep -E 'Apply complete|Error'
# The Deployment above was admitted, so the signed image passed the policy.

echo "== admission denials"
deny() { # $1 = image, $2 = expected part of the denial message
  local out
  if out=$(k -n hello create deployment admission-check --image="$1" --dry-run=server 2>&1); then
    bad "$1 was admitted"
  elif [[ "$out" == *"$2"* ]]; then
    pass "$1 denied: $2"
  else
    bad "$1: $out"
  fi
}
deny nginx:1.27-alpine "no matching policies"
# Per-arch manifest from an earlier build; CI signs only the index digest.
deny ghcr.io/darkstar1227/fastapi-hello@sha256:eca0f5b63ce9b65749a6d6ff7029651a65327e4d6ecd8c550930df0d4068a13c \
  "no valid bundles"

echo "== prometheus targets"
k -n monitoring port-forward svc/kps-kube-prometheus-stack-prometheus 9090:9090 >/dev/null 2>&1 &
pf=$!
trap 'kill $pf 2>/dev/null || true' EXIT
if python3 - <<'EOF'
import json, time, urllib.request
mine = []
for _ in range(36):  # up to 6 minutes: first scrapes after Prometheus starts
    try:
        t = json.load(urllib.request.urlopen("http://127.0.0.1:9090/api/v1/targets?state=active", timeout=5))
        mine = [x for x in t["data"]["activeTargets"]
                if "fastapi-hello" in x["scrapePool"]]
        if len(mine) >= 3 and all(x["health"] == "up" for x in mine):
            for x in mine:
                print("  up:", x["scrapeUrl"])
            raise SystemExit(0)
    except (OSError, ValueError):
        pass
    time.sleep(10)
print("  targets:", [(x["scrapeUrl"], x["health"], x["lastError"]) for x in mine])
raise SystemExit(1)
EOF
then pass "app /metrics (2 pods) and blackbox /healthz probe scraped"
else bad "prometheus targets not all up"; fi

echo "== smoke test"
KUBE_CONTEXT="$CTX" k8s/smoke-test.sh || fail=1

exit $fail
