# devops-lab notes

Personal learning lab. Sections 1-6 (2026-10-13) cover Canonical Rocks and the image supply chain; they were written when the repo was called `rock-lab`, and the rock files now live in `rock/`. Phase 2 (sections 7+) adds Kubernetes, Terraform, and more CI. Everything runs on a laptop; nothing here is production.

Host: macOS (Apple Silicon), OrbStack 2.2.3. Phase 1 built in the OrbStack Ubuntu 24.04 arm64 VM `rocklab`.

## 1. Build and run (2026-10-13)

- `rockcraft init --profile fastapi-framework`, `base: bare`, `build-base: ubuntu@24.04`, arm64.
- LXD build inside OrbStack: an interrupted run left the instance stuck in a "create" operation. Switched to `rockcraft pack --destructive-mode` (VM matches build-base).
- Building on the macOS-shared path failed at staging (`Failed to copy .../install/bin/python: no such file or directory`). Building on the VM's own filesystem (`~/rock-lab`) succeeded.
- Rock to Docker: `rockcraft.skopeo copy oci-archive:X.rock docker-archive:/tmp/fh.tar:fastapi-hello:0.1`, then `docker load`.
- `/healthz` and `/` both respond. Pebble runs the `fastapi` service; image runs as user 584792 (`_daemon_`).

## 2. Rock vs python:3.12-slim

| | rock (app + deps) | python:3.12-slim (no app) |
|---|---|---|
| Image size | 97.3 MB | 145 MB |
| OCI archive | 36 MB | — |
| apt / dpkg | absent | present |
| bash / sh | present (`bash_bins`, sh -> bash) | present |
| syft packages | 29 | 90 |
| trivy findings | 19 (pip 6, Pebble Go stdlib 13), OS: none detected | 172 (44 HIGH), OS: debian |

## 3. What the fastapi-framework extension expands to

`rockcraft expand-extensions` (see `expanded.yaml`):

- `fastapi-framework/dependencies`: python plugin, slice `python3.12-venv_ensurepip`, plus `uvicorn` and `requirements.txt`.
- `fastapi-framework/install-app`: dump plugin, `app.py` -> `/app/app.py`, owned by 584792.
- `fastapi-framework/runtime`: slices `bash_bins`, `coreutils_bins`, `ca-certificates_data`; creates `/tmp` and links `sh` -> `bash`.
- `fastapi-framework/logging`: empty promtail dirs.
- Pebble service: `/bin/python3 -m uvicorn app:app`, `UVICORN_HOST=0.0.0.0`, user `_daemon_`, working dir `/app`.

## 4. SBOM / CVE scanning gap (key finding)

- The default rock has no `/var/lib/dpkg/status` and no chisel manifest, so trivy 0.58.1 reports `OS: None` and scans no Ubuntu packages. Zero OS CVEs here means "not scanned", not "clean".
- Adding a part with slice `base-files_chisel` creates `/var/lib/chisel/manifest.wall`, but it lists only that part's slices (`base-files_*`). Slices from the extension's parts (python3.12, bash, coreutils, ca-certificates) are not listed.
- Neither syft 1.18.1 nor trivy 0.58.1 changed results after the manifest was added.
- Open questions: how to get one manifest that covers every part's slices, and which scanner versions read `manifest.wall`.

Reports: `reports/` (SPDX SBOM, syft tables, trivy JSON, decoded manifest source).

## 5. Signing and SBOM attestation with cosign (local registry)

Script: `scripts/sign-and-verify.sh` (cosign v2.4.1 in a container, `registry:2` on `localhost:5050`). Keys live in `keys/` (gitignored).

- Key-based signing with `--tlog-upload=false`: nothing goes to the public Rekor log. Verification therefore needs `--insecure-ignore-tlog`.
- Signed by digest, not by tag: `localhost:5050/fastapi-hello@sha256:d442391e...`.
- `cosign attest --type spdxjson` attaches the syft SPDX SBOM as an in-toto attestation; `verify-attestation` returns predicate type `https://spdx.dev/Document` with 30 SPDX packages.
- Verifying with a different public key fails: `invalid signature when validating ASN.1 encoded signature`.
- The registry now holds tags `0.1`, `sha256-<digest>.sig`, and `sha256-<digest>.att`: cosign stores signatures and attestations as OCI artifacts next to the image.
- Gotcha: cosign treats only `localhost` as plain-HTTP. A registry reached as `reg:5000` on a Docker network fails with "server gave HTTP response to HTTPS client" even with `--allow-insecure-registry`.

## 6. CI: multi-arch build, scan, keyless signing (GitHub Actions)

Workflow: `.github/workflows/rock.yml`. First green run: 38396156513 (2026-10-13).

- `pack` matrix builds amd64 on `ubuntu-24.04` and arm64 on `ubuntu-24.04-arm` (native runners, no QEMU) with `canonical/craft-actions/rockcraft-pack`, then pushes `:<sha>-<arch>` to GHCR with `rockcraft.skopeo`.
- `publish` joins both into one manifest list (`linux/amd64`, `linux/arm64`) with `docker buildx imagetools create`, tagged `:<sha>` and `:latest`.
- Trivy on the published image: Python packages 6 (5 MEDIUM, 1 LOW), Pebble Go binary 13 (3 HIGH). Same OS-package blind spot as section 4.
- syft SPDX SBOM, then `cosign sign` and `cosign attest --type spdxjson` keyless through GitHub OIDC (Fulcio certificate, Rekor entry). `cosign verify` and `verify-attestation` pin the certificate identity to the workflow ref and the issuer `token.actions.githubusercontent.com`.
- Gotcha: `aquasecurity/trivy-action` tags start with `v` (`v0.36.0`); `@0.36.0` fails at job setup.

## 7. Kubernetes: hardened deployment and signature admission (2026-10-15)

Cluster: OrbStack built-in Kubernetes, single node, `v1.35.6+orb1` (k3s-based, Docker runtime, arm64). Tools: kubectl, Helm 4.3.1, cosign 3.1.3, kubeconform 0.8.0.

### Repo rename and re-signing

- `gh repo rename devops-lab`. The keyless certificate identity contains the repo name, so the existing image (`sha256:c3db2314...`) is signed as `https://github.com/darkstar1227/rock-lab/.github/workflows/rock.yml@refs/heads/main`.
- Re-ran CI on main (`gh workflow run`, run 38753005081, success). New index digest `sha256:f3f15cb9...`, signed as `.../devops-lab/.github/workflows/rock.yml@refs/heads/main`. `cosign verify` with the devops-lab regexp passes on the new digest and fails on the old one with `expected SAN value to match regex ... got ".../rock-lab/..."`.
- Rock files moved to `rock/`; CI `rockcraft-pack` now gets `path: rock`. Not yet run in CI with the new layout (pending push).

### Manifests (`k8s/app/`, applied with `kubectl apply -k`)

- Namespace `hello`, labels `policy.sigstore.dev/include=true` and Pod Security Admission `enforce: restricted`.
- Deployment: 2 replicas, image pinned by digest, `runAsNonRoot`, uid/gid 584792 (`_daemon_`), `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, drop ALL capabilities, seccomp `RuntimeDefault`, no service-account token. HTTP readiness and liveness probes on `/healthz`. Requests 50m/64Mi, limits 250m/192Mi.
- NetworkPolicies: default deny ingress and egress for the namespace; app ingress on port 8000 only from pods labelled `hello-client=true` and from namespace `monitoring`; pods labelled `role=client` may reach DNS and the app.

Gotcha: Pebble will not start on a read-only root filesystem (`cannot run daemon: directory "/var/lib/pebble/default" not writable`). `PEBBLE_PERSIST=never` and `PEBBLE_SOCKET` did not help. Fix: an init container (same image, `cp -r /var/lib/pebble/default/layers`) copies the layer files into an emptyDir that is mounted over `/var/lib/pebble/default`; `/tmp` is another emptyDir. Tested first with `docker run --read-only --cap-drop ALL`.

Checked that OrbStack enforces NetworkPolicy before relying on it: in a scratch namespace, a busybox `wget` to nginx went from allowed to blocked after a deny policy.

### Signature admission: Sigstore policy-controller (not Kyverno)

Why policy-controller: the only goal here is "reject images without a valid keyless cosign signature". policy-controller is maintained by the Sigstore project for exactly that, is one small webhook, and is opt-in per namespace by label. Kyverno would also work and adds general policies, but that is more than this lab needs, and Pod Security Admission already covers the pod-hardening rules.

- Helm chart `sigstore/policy-controller` 0.10.8 (app 0.13.1), `no-match-policy: deny` (`k8s/policy/values.yaml`).
- `ClusterImagePolicy` for `ghcr.io/darkstar1227/**`: keyless, issuer `https://token.actions.githubusercontent.com`, subject pinned to `^https://github\.com/darkstar1227/devops-lab/\.github/workflows/rock\.yml@refs/heads/main$`, Rekor ctlog.
- Gotcha: the first policy denied the correctly signed image with `no signatures found`. CI's cosign is v3.0.6 (installer v4.1.2); cosign v3 stores signatures as Sigstore bundles in OCI referrers (`cosign tree` shows `https://sigstore.dev/cosign/sign/v1 artifacts via OCI referrer`), not as `.sig` tags. policy-controller 0.13.1 reads bundles only through its attestation path. Workaround (sigstore/policy-controller issue 1899): `signatureFormat: bundle` plus an attestation with predicate type `https://sigstore.dev/cosign/sign/v1`. The policy also requires the SPDX SBOM attestation (`https://spdx.dev/Document`) that CI already produces.

Admission results (`kubectl -n hello create deployment ... --dry-run=server`):

| Image | Result |
|---|---|
| `fastapi-hello@sha256:f3f15cb9...` (signed by devops-lab CI) | admitted |
| `fastapi-hello@sha256:eca0f5b6...` (per-arch arm64 manifest from the same build; CI signs only the index, so this digest has no signature) | denied: `no valid bundles exist in registry` |
| `nginx:1.27-alpine` (no policy matches) | denied: `no matching policies` |
| `fastapi-hello@sha256:c3db2314...` (signed, but as rock-lab) | denied: `no matching CertificateIdentity found ... got ".../rock-lab/..."` |

Pod Security Admission also rejected a bare `kubectl run` of the signed image: `violates PodSecurity "restricted:latest"`.

### Smoke test (`k8s/smoke-test.sh`, exit 0 on OrbStack)

```
PASS: 2/2 replicas ready
PASS: labelled client reached /healthz: {"status":"ok"}
PASS: client without hello-client=true blocked by ingress NetworkPolicy
PASS: PID 1 (pebble) runs as uid 584792
PASS: app egress to 1.1.1.1 blocked
PASS: root filesystem is read-only
```

- Clients are pods built from the app image (it has python3), so they pass the signature policy and Pod Security `restricted`.
- Gotcha 1: the first run failed with `Connection refused` for the allowed client. The namespace default deny also blocks the client's own egress (DNS included), so the "blocked" result for the unlabelled client proved nothing. Added the `client-egress` policy; now both clients have egress, and only the ingress rule separates them.
- Gotcha 2: a brand-new pod was sometimes refused for its first requests until the network policy controller had programmed rules for its IP. The client retries for up to 10 s.
- `grep` is not in the chiselled image; the UID check reads `/proc/1/status` with bash builtins.

### Manifest validation

- `kubectl kustomize k8s/app | kubeconform -strict -kubernetes-version 1.35.0`: 6 valid.
- The community CRDs-catalog schema for `ClusterImagePolicy` v1beta1 rejects `signatureFormat`, but the live CRD accepts it (catalog out of date). `k8s/schemas/generate.py` builds strict schemas from the chart's own CRDs (`helm template ... | python3 k8s/schemas/generate.py`). With them the policy validates, and a typo (`signatureFormt`) is caught as `additional properties ... not allowed`.

### Not verified

- Liveness probe restarts were not exercised. Pebble restarts a crashed uvicorn itself, so the probe would only fire on a hang.
- Single node, so spreading replicas across nodes and disruption budgets were not tested.
- policy-controller is installed by hand (README commands), not by Terraform.

## Next

- Close the OS-package gap: one chisel manifest covering every part, and check which scanner versions read it.
- Optional: a minimal .deb package.
