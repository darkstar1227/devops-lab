# devops-lab

A personal learning lab (renamed from `rock-lab` on 2026-10-15). One FastAPI hello-world app is carried through the delivery chain: image build and supply chain, Kubernetes, Terraform, and CI. It runs on a laptop; nothing here is production.

| Directory | What it practises |
|---|---|
| [`rock/`](rock/) | Chiselled Ubuntu [rock](https://documentation.ubuntu.com/rockcraft/) built with Rockcraft; Pebble runs the app as non-root. syft SBOM, Trivy scan, cosign signing. |
| [`k8s/`](k8s/) | Deployment, Service and NetworkPolicy with a hardened pod spec; Sigstore policy-controller rejects images without a valid keyless signature. |
| [`terraform/`](terraform/) | kubernetes + helm providers (local state): the app from `k8s/app`, kube-prometheus-stack, a blackbox `/healthz` probe and a Grafana dashboard. |
| [`.github/workflows/`](.github/workflows/) | `rock.yml`: multi-arch build on native runners, push to GHCR, scan, keyless signing through GitHub OIDC. `deploy.yml`: terraform fmt/validate, kubeconform, then a kind cluster running `k8s/kind-e2e.sh`. |

Findings, numbers, commands, and gotchas are in [NOTES.md](NOTES.md).

## Build the rock locally

```bash
cd rock
rockcraft pack
rockcraft.skopeo --insecure-policy copy oci-archive:fastapi-hello_0.1_arm64.rock \
  docker-daemon:fastapi-hello:0.1
docker run --rm -p 8000:8000 fastapi-hello:0.1
```

## Verify a published image

```bash
cosign verify ghcr.io/darkstar1227/fastapi-hello:latest \
  --certificate-identity-regexp '^https://github.com/darkstar1227/devops-lab/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## Deploy to a local cluster (OrbStack Kubernetes)

```bash
helm repo add sigstore https://sigstore.github.io/helm-charts
helm upgrade --install policy-controller sigstore/policy-controller --version 0.10.8 \
  -n cosign-system --create-namespace -f k8s/policy/values.yaml --wait
kubectl apply -f k8s/policy/clusterimagepolicy.yaml
kubectl apply -k k8s/app          # or, with monitoring, the Terraform below
k8s/smoke-test.sh
```

## Deploy with Terraform (app + monitoring)

Assumes the policy-controller step above (Terraform does not manage it).

```bash
cd terraform
terraform init
terraform apply
terraform output -raw grafana_admin_password
kubectl -n monitoring port-forward svc/kps-grafana 3000:80   # dashboard: fastapi-hello
terraform destroy
```
