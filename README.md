# rock-lab

A FastAPI hello-world app packaged as a chiselled Ubuntu [rock](https://documentation.ubuntu.com/rockcraft/) (`base: bare`), used to practise the container-image supply chain:

- Build with Rockcraft and the `fastapi-framework` extension; Pebble runs the service as a non-root user.
- Generate an SPDX SBOM with syft and scan for CVEs with Trivy.
- Sign the image and attest the SBOM with cosign.
- CI: GitHub Actions packs amd64 and arm64 rocks on native runners, publishes a multi-arch image to GHCR, scans it, and signs it keylessly through GitHub OIDC.

Findings, numbers, and gotchas are in [NOTES.md](NOTES.md).

## Run locally

```bash
rockcraft pack
rockcraft.skopeo --insecure-policy copy oci-archive:fastapi-hello_0.1_arm64.rock \
  docker-daemon:fastapi-hello:0.1
docker run --rm -p 8000:8000 fastapi-hello:0.1
```

## Verify a published image

```bash
cosign verify ghcr.io/darkstar1227/fastapi-hello:latest \
  --certificate-identity-regexp '^https://github.com/darkstar1227/rock-lab/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```
