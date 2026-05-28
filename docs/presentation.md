---
marp: true
theme: default
paginate: true
style: |
  section {
    padding: 20px 40px;
    font-size: 22px;
  }
  section.lead {
    text-align: center;
    justify-content: center;
  }
  section.lead h1 {
    font-size: 1.8em;
  }
  section.lead h2 {
    font-size: 1.0em;
    color: #555;
    font-weight: normal;
  }
  h1 { font-size: 1.3em; margin-bottom: 8px; }
  h2 { font-size: 1.05em; margin-bottom: 6px; }
  ul, ol { margin: 4px 0; padding-left: 1.2em; }
  li { margin: 3px 0; }
  pre { font-size: 0.6em; margin: 4px 0; }
  code { font-size: 0.8em; }
  table { font-size: 0.8em; width: 100%; }
  th { background: #e8e8e8; }
  blockquote { border-left: 4px solid #aaa; padding-left: 12px; color: #555; margin: 6px 0; }
  .columns { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; }
---

<!-- _class: lead -->

# Progressive Rollout for GCP HCP
## Exploring gitops-promoter as a candidate solution
### GCP-539 — Tooling spike · May 2026

---

# The Problem (GCP-537)

As we scale to multiple regions, we need to propagate changes safely across environments:

- **No automated promotion pipeline** — changes land directly per environment
- **No enforced ordering** — stage can drift behind or ahead of production
- **No pluggable gating** — CI is branch-level, not change-level
- **ArgoCD runs independently on each cluster** — no cross-cluster API access
- **GitOps constraint** — all promotion must work via Git and external APIs only

> *"Before committing to an implementation, we need to study the landscape of available tools"* — GCP-539

---

# What We Need (GCP-537 Requirements)

- **Environment progression**: integration → stage → production
- **Sectors within environments**: canary sector first, then broader rollout
- **Pluggable gates**: CI checks, health checks, soak timers, manual approval
- **Both promotion models**: individual component bumps and full bundle promotion
- **Observability**: what version is deployed where, promotion history, current readiness
- **Git as source of truth**: all promotion actions result in git commits (auditable, revertable)
- **No cross-cluster API access**: verification via Git and external APIs only

---

# gitops-promoter: What It Is

A Kubernetes controller by **argoproj-labs** that manages promotion via branches and PRs.

- **Source of truth**: a DRY `main` branch; a hydrator renders it per environment
- **Proposed branches** (`env/X-next`): rendered output waiting to be promoted
- **Active branches** (`env/X`): what is currently deployed
- **PRs**: gitops-promoter opens them, gates them with commit statuses, auto-merges (or waits for manual merge)
- **PromotionStrategy CRD**: one resource declares the entire pipeline

Promotion is **declarative** and **auditable** — every promotion is a merged PR with a full CI trail in GitHub.

---

# How It Works

```
main (DRY)
  │
  └─► hydrate.yaml ─────────────────────────────────────────────────────────►
        │                                                                      │
        ▼ (push all 5 simultaneously)                                          │
  env/integration/main-next ──► PR ──[ci-check ✓]──► env/integration/main    │
                                                            │                  │
                                                [ci-check ✓ · deploy ✓]       │
                                                            ▼                  │
  env/stage/main-next        ──► PR ──[ci-check ✓]──► env/stage/main         │
                                                            │                  │
                                               [ci-check ✓ · deploy ✓ · ⏱2m] │
                                                            ▼                  │
  env/production/prod-1-next ──► PR ──[ci-check ✓]──► env/production/prod-1  │
                                         MANUAL                │               │
                                                   [ci-check ✓ · deploy ✓]    │
                                                               ▼               │
  env/production/prod-2-next ──► PR ──[ci-check ✓]──► env/production/prod-2  │
  env/production/prod-3-next ──► PR ──[ci-check ✓]──► env/production/prod-3 ◄┘
```

**Proposed** commit statuses gate PR merge · **Active** commit statuses gate the *next* environment

---

# Demo Pipeline

This POC mirrors the gcp-hcp-infra repo structure across **5 sectors**:

| Sector | Regions | Merge |
|--------|---------|-------|
| integration/main | us-central1 | auto |
| stage/main | us-central1 | auto + **2m soak** |
| production/prod-1 | us-central1 | **MANUAL** |
| production/prod-2 | us-central1 · europe-west1 | auto |
| production/prod-3 | us-central1 | auto |

**What's promoted each cycle:**
- 15 ArgoCD Applications (3 management-cluster + 12 region apps), built with kustomize, packaged as Helm charts
- Terraform configs (platform module + per-sector/region tfvars)
- Per-environment overlays via layered kustomize patches

---

# Gating: Commit Statuses

| Status | Type | Set by | What it gates |
|--------|------|--------|---------------|
| `ci-check` | WebRequestCommitStatus | GitHub Actions (YAML lint, `terraform validate`) | PR merge (proposed) |
| `deploy` | WebRequestCommitStatus | GitHub Actions (fake deploy on active branch) | Next sector's PR merge |
| `timer` | TimedCommitStatus | gitops-promoter (2-min soak on stage) | prod-1 PR merge |

All commit statuses are **standard GitHub commit statuses** — visible on every PR, queriable via API.

`WebRequestCommitStatus` polls **any HTTP endpoint** — the real implementation would call
E2E test results, health check APIs, deployment verification endpoints.

---

# The PromotionStrategy CRD

```yaml
apiVersion: promoter.argoproj.io/v1alpha1
kind: PromotionStrategy
metadata:
  name: gcp-hcp-demo
spec:
  gitRepositoryRef:
    name: gcp-hcp-gitops-promoter-demo
  activeCommitStatuses:       # gates applied to ALL environments
    - key: ci-check
    - key: deploy
  environments:
    - branch: environment/integration/main
    - branch: environment/stage/main
      activeCommitStatuses:
        - key: timer           # 2-min soak before prod-1 unlocks
    - branch: environment/production/prod-1
      autoMerge: false         # requires human approval
    - branch: environment/production/prod-2
    - branch: environment/production/prod-3
```

The controller handles the rest: opens PRs, checks statuses, merges, cascades.

---

<!-- _class: lead -->

# Live Demo

## Push a version bump — watch the cascade

**Terminal panes:**
- `watch -n5 promoter/status.sh`
- `watch kubectl -n promoter-system get promotionstrategy,commitstatuses,timedcommitstatuses,webrequestcommitstatus,pullrequest`

**Browser:** promoter dashboard · GitHub Actions

---

# What We Just Saw

1. Version bump pushed to `main`
2. Hydration workflow built all 5 proposed branches **simultaneously**
3. Integration PR auto-merged once `ci-check` passed
4. Stage PR merged, then **2-minute soak timer** ran before prod-1 unlocked
5. Prod-1 PR required **manual approval** — enforced by the controller
6. Prod-2 and prod-3 **auto-cascaded** after prod-1 merged
7. All 5 sectors now on the same version — every step is a merged PR in Git

---

# Coverage vs GCP-537 Requirements

| Requirement | Covered? |
|-------------|----------|
| Environment progression (int → stage → prod) | ✅ |
| Sectors with ordered rollout | ✅ |
| Pluggable gates (CI, soak timer, HTTP endpoint) | ✅ |
| Manual approval gate | ✅ |
| Git as source of truth, all via git commits | ✅ |
| Component-level promotion | ✅ (this demo) |
| Bundle / platform-level promotion | ⬜ (design needed) |
| Freeze / halt | ⬜ (not in controller today) |
| Fast track path | ⬜ (not in controller today) |
| Full observability dashboard | ⬜ (basic dashboard only) |

**Next:** decision document comparing gitops-promoter with other candidates (Kargo, Telefonistka, ...)
→ [github.com/patjlm/gcp-hcp-gitops-promoter-demo](https://github.com/patjlm/gcp-hcp-gitops-promoter-demo)
→ [argoproj-labs/gitops-promoter](https://github.com/argoproj-labs/gitops-promoter)
