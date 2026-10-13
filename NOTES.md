# rock-lab notes

Hands-on lab for Canonical Rocks (chiselled Ubuntu OCI images). Host: macOS, OrbStack Ubuntu 24.04 arm64 VM `rocklab`.

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

## Next

- Close the OS-package gap: one chisel manifest covering every part, and check which scanner versions read it.: multi-arch build, scan, sign.
- Optional: a minimal .deb package.
