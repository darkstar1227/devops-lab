#!/usr/bin/env bash
# Smoke test for the fastapi-hello deployment in namespace "hello".
# Used locally (OrbStack) and in CI (kind). Needs kubectl and a ready rollout.
set -euo pipefail

NS=${NS:-hello}
IMAGE=$(kubectl -n "$NS" get deploy fastapi-hello -o jsonpath='{.spec.template.spec.containers[0].image}')
fail=0
pass() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fail=1; }

# Retries because a brand-new pod can be rejected for a few seconds until the
# network policy controller has programmed rules for its IP.
PY='import time, urllib.request\nfor i in range(10):\n  try:\n    print(urllib.request.urlopen(\"http://fastapi-hello/healthz\", timeout=3).read().decode()); break\n  except Exception as e:\n    err = e; time.sleep(1)\nelse:\n  print(\"error:\", err); raise SystemExit(1)'

# Client pod built from the app image itself (it has python3), so it passes
# the signature policy and Pod Security "restricted".
client() { # $1 = name, $2 = extra label JSON or empty
  local labels='{"role":"client"'"${2:+,$2}"'}'
  kubectl -n "$NS" run "$1" --rm -i --restart=Never --image="$IMAGE" --quiet \
    --pod-running-timeout=2m --overrides='{
    "metadata": {"labels": '"$labels"'},
    "spec": {
      "automountServiceAccountToken": false,
      "securityContext": {"runAsNonRoot": true, "runAsUser": 584792, "seccompProfile": {"type": "RuntimeDefault"}},
      "containers": [{
        "name": "c", "image": "'"$IMAGE"'",
        "command": ["/bin/python3", "-c", "'"$PY"'"],
        "securityContext": {"allowPrivilegeEscalation": false, "readOnlyRootFilesystem": true, "capabilities": {"drop": ["ALL"]}}
      }]}}'
}

kubectl -n "$NS" rollout status deploy/fastapi-hello --timeout=180s

ready=$(kubectl -n "$NS" get deploy fastapi-hello -o jsonpath='{.status.readyReplicas}')
[ "$ready" = "2" ] && pass "2/2 replicas ready" || bad "ready replicas: ${ready:-0}"

out=$(client smoke-allowed '"hello-client":"true"' 2>&1 || true)
[[ "$out" == *'"status":"ok"'* ]] && pass "labelled client reached /healthz: $out" || bad "labelled client: $out"

out=$(client smoke-denied '' 2>&1 || true)
[[ "$out" == *'"status":"ok"'* ]] && bad "unlabelled client was NOT blocked by NetworkPolicy" || pass "client without hello-client=true blocked by ingress NetworkPolicy"

pod=$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=fastapi-hello -o jsonpath='{.items[0].metadata.name}')
uid=$(kubectl -n "$NS" exec "$pod" -c app -- /usr/bin/bash -c 'while read -r k u _; do [ "$k" = Uid: ] && echo "$u"; done < /proc/1/status; true')
[ "$uid" = "584792" ] && pass "PID 1 (pebble) runs as uid $uid" || bad "PID 1 uid: $uid"

egress=$(kubectl -n "$NS" exec "$pod" -c app -- /bin/python3 -c 'import urllib.request
try:
    urllib.request.urlopen("http://1.1.1.1", timeout=4); print("open")
except Exception:
    print("blocked")')
[ "$egress" = "blocked" ] && pass "app egress to 1.1.1.1 blocked" || bad "app egress is open"

if kubectl -n "$NS" exec "$pod" -c app -- /usr/bin/bash -c ': > /app/probe' 2>/dev/null; then
  bad "root filesystem is writable"
else
  pass "root filesystem is read-only"
fi

exit $fail
