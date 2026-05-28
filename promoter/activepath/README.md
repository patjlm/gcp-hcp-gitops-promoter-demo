# Step 2: activePath-based per-component promotion

This directory will contain gitops-promoter resources for per-component promotion using the `activePath` monorepo feature.

## Planned resources

Instead of promoting the entire sector as one unit, each component will have its own `PromotionStrategy` with an `activePath` scoping it to a subdirectory:

- `argocd-region` — `activePath: argocd/rendered/region`
- `argocd-mc` — `activePath: argocd/rendered/management-cluster`
- `terraform` — `activePath: terraform/config`

This enables independent promotion of ArgoCD and Terraform changes through integration and stage, allowing a Terraform change to advance independently of ArgoCD changes (and vice versa).

## Demo scenario

With activePath, the demo can show:

1. A change to `argocd/config/region/hyperfleet-api/` triggers only the `argocd-region` strategy.
2. Simultaneously, a Terraform change triggers only the `terraform` strategy.
3. Both promote independently — Terraform can be at staging while ArgoCD is still in integration.

## When activePath support is available

Requires gitops-promoter PR #1337 (activePath feature). See `promoter/build-from-pr.sh` to build it.

Use `promoter/setup.sh` with the `PROMOTER_INSTALL_URL` pointing to the activePath build, then `kubectl apply -f promoter/activepath/` to enable per-component promotion.
