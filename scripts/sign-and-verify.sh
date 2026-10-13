#!/usr/bin/env bash
set -uo pipefail
cd /Users/ds-anxing/GitHub/rock-lab
DIGEST=$(docker inspect --format '{{index .RepoDigests 0}}' localhost:5050/fastapi-hello:0.1 | cut -d@ -f2)
REF="localhost:5050/fastapi-hello@$DIGEST"
echo "$REF" > reports/signed-ref.txt
cosign() {
  docker run --rm --network host -v "$PWD":/w -w /w -e COSIGN_PASSWORD= \
    ghcr.io/sigstore/cosign/cosign:v2.4.1 "$@"
}
[ -f keys/cosign.key ] || cosign generate-key-pair --output-key-prefix keys/cosign >/dev/null 2>&1
ls keys
echo '== sign'
cosign sign --key keys/cosign.key --tlog-upload=false --allow-insecure-registry -y "$REF" 2>&1 | tail -2
echo '== attest SBOM'
cosign attest --key keys/cosign.key --tlog-upload=false --allow-insecure-registry -y \
  --type spdxjson --predicate reports/sbom-rock.spdx.json "$REF" 2>&1 | tail -2
echo '== verify signature'
cosign verify --key keys/cosign.pub --insecure-ignore-tlog --allow-insecure-registry "$REF" 2>&1 | grep -vE '^\[' | head -5
echo '== verify attestation'
cosign verify-attestation --key keys/cosign.pub --insecure-ignore-tlog --allow-insecure-registry \
  --type spdxjson "$REF" 2>/dev/null | python3 -c "
import sys,json,base64
e=json.loads(sys.stdin.readline()); p=json.loads(base64.b64decode(e['payload']))
print('predicateType:', p['predicateType']); print('packages in SBOM:', len(p['predicate'].get('packages',[])))"
echo '== tamper test: verify with a different key'
cosign generate-key-pair --output-key-prefix keys/other >/dev/null 2>&1 </dev/null
cosign verify --key keys/other.pub --insecure-ignore-tlog --allow-insecure-registry "$REF" 2>&1 | grep -iE 'error|no matching' | head -2
echo '== registry tags'
docker run --rm --network rocknet curlimages/curl:8.11.1 -s http://reg:5000/v2/fastapi-hello/tags/list
