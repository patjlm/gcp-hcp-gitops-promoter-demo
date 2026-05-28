# Promotion flow

```mermaid
flowchart TD
    MAIN(["`**main**
    dry source`"])
    HYDRATE["`**hydrate.yaml**
    kustomize build each app → Helm chart
    copy terraform sector configs + hydrator.metadata`"]

    INT_NEXT(["`*int/main-next*`"])
    STG_NEXT(["`*stage/main-next*`"])
    P1_NEXT(["`*prod-1-next*`"])
    P2_NEXT(["`*prod-2-next*`"])
    P3_NEXT(["`*prod-3-next*`"])

    PR_INT{{"`**PR: int/main**
    auto-merge`"}}
    PR_STG{{"`**PR: stage/main**
    auto-merge`"}}
    PR_P1{{"`**PR: prod-1**
    MANUAL MERGE`"}}
    PR_P2{{"`**PR: prod-2**
    auto-merge`"}}
    PR_P3{{"`**PR: prod-3**
    auto-merge`"}}

    ACT_INT(["`**env/integration/main**
    us-central1`"])
    ACT_STG(["`**env/stage/main**
    us-central1`"])
    ACT_P1(["`**env/production/prod-1**
    us-central1`"])
    ACT_P2(["`**env/production/prod-2**
    us-central1 · europe-west1`"])
    ACT_P3(["`**env/production/prod-3**
    us-central1`"])

    MAIN --> HYDRATE

    HYDRATE -.->|"push all 5 simultaneously"| INT_NEXT
    HYDRATE -.-> STG_NEXT
    HYDRATE -.-> P1_NEXT
    HYDRATE -.-> P2_NEXT
    HYDRATE -.-> P3_NEXT

    INT_NEXT -->|opens PR| PR_INT
    STG_NEXT -->|opens PR| PR_STG
    P1_NEXT -->|opens PR| PR_P1
    P2_NEXT -->|opens PR| PR_P2
    P3_NEXT -->|opens PR| PR_P3

    PR_INT -->|"ci-check ✓"| ACT_INT
    PR_STG -->|"ci-check ✓"| ACT_STG
    PR_P1 -->|"ci-check ✓"| ACT_P1
    PR_P2 -->|"ci-check ✓"| ACT_P2
    PR_P3 -->|"ci-check ✓"| ACT_P3

    ACT_INT -->|"`gates PR merge:
    ci-check ✓  deploy ✓`"| PR_STG
    ACT_STG -->|"`gates PR merge:
    ci-check ✓  deploy ✓  ⏱ 2m`"| PR_P1
    ACT_P1 -->|"`gates PR merge:
    ci-check ✓  deploy ✓`"| PR_P2
    ACT_P2 -->|"`gates PR merge:
    ci-check ✓  deploy ✓`"| PR_P3

    classDef activeAuto fill:#22c55e,color:#fff,stroke:#16a34a,stroke-width:2px
    classDef activeManual fill:#f87171,color:#fff,stroke:#dc2626,stroke-width:2px
    classDef prAuto fill:#3b82f6,color:#fff,stroke:#2563eb,stroke-width:2px
    classDef prManual fill:#dc2626,color:#fff,stroke:#991b1b,stroke-width:3px
    classDef proposed fill:#e2e8f0,color:#1e293b,stroke:#94a3b8,stroke-dasharray:4 2

    class ACT_INT,ACT_STG,ACT_P2,ACT_P3 activeAuto
    class ACT_P1 activeManual
    class PR_INT,PR_STG,PR_P2,PR_P3 prAuto
    class PR_P1 prManual
    class INT_NEXT,STG_NEXT,P1_NEXT,P2_NEXT,P3_NEXT proposed
```

## How to read this diagram

- **Dotted arrows** from `hydrate.yaml`: content is pushed to **all 5 proposed branches simultaneously** on every push to `main`.
- **Solid arrows** from proposed branches: gitops-promoter opens a PR for each sector. The PR auto-merges once its own `ci-check` commit status is success.
- **Solid arrows** from active branches to PR nodes: the previous sector's `ci-check` and `deploy` commit statuses must be success before the next PR is allowed to merge. The ⏱ 2m on stage means a `TimedCommitStatus` enforces a soak period before prod-1 is unlocked.
- Promotion is **strictly sequential**: integration → stage → prod-1 → prod-2 → prod-3. prod-2 and prod-3 are not parallel — prod-3 is gated by prod-2.
- prod-1 requires **manual merge**; all others auto-merge once gates pass.

## Commit statuses

| Status | Set by | Checked by |
|--------|--------|------------|
| `ci-check` | `ci-checks.yaml` (YAML lint + `terraform validate`) | gitops-promoter as proposed commit status on each PR |
| `deploy` | `deploy.yaml` (fake deploy on active branch post-merge) | gitops-promoter as active commit status gating the next sector |
| `timer` | `TimedCommitStatus` CR (2-minute soak) | gitops-promoter as active commit status on stage only |
