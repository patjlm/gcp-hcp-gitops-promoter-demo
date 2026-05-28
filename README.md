# gcp-hcp-gitops-promoter-demo

Demo repository for [gitops-promoter](https://github.com/argoproj-labs/gitops-promoter) showcasing environment promotion with patterns mirroring the `gcp-hcp-infra` repository (GCP-539).

## What this demos

- **Sector-based promotion**: Changes move through sectors as a single unit — integration → stage → production (3 sectors).
- **Multi-region sectors**: Production sectors can span multiple GCP regions (prod-2 covers `us-central1` + `europe-west1`).
- **ArgoCD rendered Helm charts**: ArgoCD Application manifests are built via Kustomize and packaged as Helm charts for ArgoCD to deploy.
- **Terraform promotion**: Infrastructure configs (terraform module + per-region tfvars) are promoted alongside ArgoCD configs.
- **Gating**: CI validation, fake deployment, and a 2-minute soak timer gate promotion through sectors.

## Repository layout

```
argocd/config/            # ArgoCD Application source templates (edited on main)
  region/                 # Apps for GKE region clusters
    values.yaml           # Helm values template (same shape across envs)
    {app}/
      kustomization.yaml  # Base Kustomize resource
      {app}.yaml          # ArgoCD Application manifest
      {env}/              # Optional Kustomize overlays for per-env patches
        kustomization.yaml
        {patch}.yaml
  management-cluster/     # Apps for GKE management clusters (hypershift control planes)
    values.yaml
    {app}/...

terraform/
  modules/platform/       # Reusable null_resource module (GCP-agnostic)
  config/                 # Per-sector/region configs invoking the module
    {env}/{sector}/{region}/
      main.tf
      terraform.tfvars

promoter/                 # gitops-promoter setup and K8s resources
  config.env              # Config template (copy to config.local.env)
  setup.sh                # Bootstrap: minikube + promoter + env branches
  teardown.sh
  reset-branches.sh
  status.sh               # Use with: watch -n5 promoter/status.sh
  webhook-tunnel.sh       # ngrok webhook tunnel
  build-from-pr.sh        # Build promoter from a GitHub PR
  scm-provider.yaml       # ScmProvider CRD
  git-repository.yaml     # GitRepository CRD
  promotion-strategy.yaml # Single PromotionStrategy (no activePath)
  commit-status/          # WebRequestCommitStatus + TimedCommitStatus gates

.github/workflows/
  hydrate.yaml            # On push to main: build kustomize, push to proposed branches
  ci-checks.yaml          # On env branch PRs/pushes: validate YAML + terraform
  deploy.yaml             # On env branch post-merge: fake deploy, set status
```

## Promotion pipeline

See [docs/promotion-flow.md](docs/promotion-flow.md) for the full annotated diagram.

```
integration/main (auto)
    ↓  ci-check ✓  deploy ✓
stage/main (auto + ⏱ 2m soak)
    ↓  ci-check ✓  deploy ✓  timer ✓
production/prod-1 (manual approval)
    ↓  ci-check ✓  deploy ✓
production/prod-2 (auto)  — us-central1, europe-west1
    ↓  ci-check ✓  deploy ✓
production/prod-3 (auto)  — us-central1
```

Each active branch (`environment/…`) is promoted from a proposed branch (`environment/…-next`) via a PR opened by gitops-promoter. Promotion is strictly sequential — prod-2 and prod-3 are not parallel.

## Components

### Region cluster (per region)
| App | Source |
|-----|--------|
| `hyperfleet-api` | External chart (openshift-hyperfleet) |
| `hyperfleet-api-gateway` | Internal Helm chart |
| `hyperfleet-cloud-resources` | Internal Helm chart |
| `hyperfleet-hc-adapter` | Internal Helm chart |
| `hyperfleet-nodepool-sentinel` | External chart |
| `hyperfleet-nodepool-vr-adapter` | Internal Helm chart |
| `hyperfleet-placement-adapter` | Internal Helm chart |
| `hyperfleet-sentinel` | External chart |
| `hyperfleet-version-resolution-adapter` | Internal Helm chart |
| `external-dns` | External Helm chart (kubernetes-sigs) |
| `maestro-server` | External chart (openshift-online/maestro) |
| `maestro-server-cloud-resources` | External chart (openshift-online/maestro) |

### Management cluster (per region)
| App | Source |
|-----|--------|
| `cert-manager` | External Helm chart (jetstack) |
| `hypershift` | Internal Kustomize |
| `maestro-agent` | External chart (openshift-online/maestro) |

## Hydration

On push to `main`, `.github/workflows/hydrate.yaml` builds a Helm chart for each sector:

1. For each cluster type and region in the sector:
   - Runs `kustomize build` on each app's most specific overlay
   - Packages output as `argocd/rendered/{cluster-type}/{region}/templates/{app}.yaml`
2. Copies terraform module + sector-specific configs
3. Writes `hydrator.metadata` (links hydrated commit back to source)
4. Pushes to the proposed branch (`environment/{env}/{sector}-next`)

## Quick start

```bash
# Prerequisites: minikube, kubectl, kustomize, GitHub App credentials

cd promoter/
cp config.env config.local.env
# Edit config.local.env with your GitHub App credentials

./setup.sh
```

Then push a change to `main` to trigger the promotion pipeline. Monitor with:

```bash
watch -n5 promoter/status.sh
```
