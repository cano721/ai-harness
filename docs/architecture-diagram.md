# AI Harness - Architecture Visualization

> Generated: 2026-03-31

## 1. Three-Pillar Architecture (전체 개요)

```mermaid
graph TB
    subgraph Harness["🏗️ AI Harness v2.0"]
        direction TB

        subgraph Guard["🛡️ Guard (안전)"]
            G1[block-dangerous.sh]
            G2[secret-scanner.sh]
            G3[check-architecture.sh]
            G4[guardrails-check.sh]
            G5[infra-change-review.sh]
        end

        subgraph Guide["📐 Guide (컨벤션)"]
            GU1[Team CLAUDE.md]
            GU2[convention-*.md]
            GU3[catalog.yaml]
            GU4[context-map.md]
        end

        subgraph Optimize["⚡ Gear (AI 최적화)"]
            O1[Project-Aware Agents]
            O2[Domain Skills]
            O3[Task Workflows]
        end
    end

    User([Developer / Planner]) --> Runtime
    Runtime[Claude Code / Codex Runtime] --> Guard
    Runtime --> Guide
    Runtime --> Optimize

    Guard -->|Allow / Block| Result[Tool Execution]
    Guide -->|Context| Runtime
    Optimize -->|Specialized Work| Result

    style Guard fill:#fee2e2,stroke:#dc2626
    style Guide fill:#dbeafe,stroke:#2563eb
    style Optimize fill:#d1fae5,stroke:#059669
    style Harness fill:#f8fafc,stroke:#475569
```

## 2. Hook System (실행 흐름)

```mermaid
flowchart LR
    subgraph Trigger["트리거"]
        T1[PreToolUse]
        T2[PostToolUse]
    end

    subgraph Tools["대상 도구"]
        Bash[Bash]
        Write[Write]
        Edit[Edit]
    end

    subgraph GlobalHooks["Global Hooks (필수)"]
        H1["block-dangerous\n<small>rm -rf, DROP, force push</small>"]
        H2["secret-scanner\n<small>API keys, passwords</small>"]
        H3["check-architecture\n<small>레이어 방향 검증</small>"]
        H4["guardrails-check\n<small>파일 수, 실행 시간</small>"]
    end

    subgraph TeamHooks["Team Hooks (선택)"]
        TH1["sql-review"]
        TH2["api-compat"]
        TH3["entity-review"]
        TH4["coverage-check"]
        TH5["bundle-size"]
        TH6["lighthouse"]
    end

    T1 --> Bash & Write & Edit
    Bash --> H1 & H2
    Write --> H2 & H3 & H4
    Edit --> H2 & H3 & H4

    H1 & H2 & H3 & H4 -->|exit 0: Allow| Pass[✅ 실행 허용]
    H1 & H2 & H3 & H4 -->|exit 2: Block| Block[🚫 실행 차단]

    Bash --> TH1 & TH2
    Write --> TH3
    T2 --> TH4 & TH5 & TH6

    style GlobalHooks fill:#fee2e2,stroke:#dc2626
    style TeamHooks fill:#fef3c7,stroke:#d97706
```

## 3. Team Structure (팀 구성)

```mermaid
graph TB
    subgraph Teams["Teams"]
        direction LR

        subgraph BE["Backend ✅"]
            BE_H["Hooks (8)"]
            BE_S["Skills (5)"]
            BE_C["Conventions"]
        end

        subgraph FE["Frontend ✅"]
            FE_H["Hooks (8)"]
            FE_S["Skills (4)"]
            FE_C["Conventions"]
        end

        subgraph PL["Planning 🔵"]
            PL_A["Agents (16)"]
            PL_S["Skills (26+)"]
            PL_B["Bundle System"]
        end

        subgraph DS["Design ⏳"]
            DS_C["CLAUDE.md"]
        end

        subgraph DO["DevOps ⏳"]
            DO_H["Hooks (1)"]
            DO_S["Skills (prep)"]
        end

        subgraph QA["QA ⏳"]
            QA_H["Hooks (1)"]
            QA_S["Skills (prep)"]
        end
    end

    Global["Global Skills (8)"] --> BE & FE & PL & DS & DO & QA

    style BE fill:#d1fae5,stroke:#059669
    style FE fill:#d1fae5,stroke:#059669
    style PL fill:#dbeafe,stroke:#2563eb
    style DS fill:#fef3c7,stroke:#d97706
    style DO fill:#fef3c7,stroke:#d97706
    style QA fill:#fef3c7,stroke:#d97706
```

## 4. Init Flow (초기화 흐름)

```mermaid
flowchart TD
    Start(["/harness-init"]) --> Detect["프로젝트 분석\n(빌드파일, 설정파일)"]
    Detect --> Choose{"팀 선택"}

    Choose -->|Planning| PL_Flow
    Choose -->|Backend| BE_Flow
    Choose -->|Frontend| FE_Flow

    subgraph PL_Flow["Planning 경로"]
        PL1["런타임 감지\n(Codex / Claude)"] --> PL2["Planner Bundle 설치"]
        PL2 --> PL3["AGENTS.md → CLAUDE.md 변환"]
        PL3 --> PL4["26+ Skills 등록"]
    end

    subgraph BE_Flow["Backend 경로"]
        BE1["Global Security Hooks 등록 (4)"] --> BE2["프로젝트 코드 분석\n(Entity, API, 패턴)"]
        BE2 --> BE3["convention-backend.md 생성"]
        BE3 --> BE4["Team Hooks 등록 (4+)"]
        BE4 --> BE5["context-map.md 생성"]
        BE5 --> BE6["Project-Aware Agents 생성"]
        BE6 --> BE7["Workflow Pattern 생성"]
        BE7 --> BE8["생성물 검증"]
    end

    subgraph FE_Flow["Frontend 경로"]
        FE1["Global Security Hooks 등록"] --> FE2["프론트엔드 분석\n(React/Vue, 번들)"]
        FE2 --> FE3["convention-frontend.md 생성"]
        FE3 --> FE4["Team Hooks 등록"]
    end

    PL_Flow & BE_Flow & FE_Flow --> Done["✅ 초기화 완료\n.ai-harness/ 생성"]

    style PL_Flow fill:#dbeafe,stroke:#2563eb
    style BE_Flow fill:#d1fae5,stroke:#059669
    style FE_Flow fill:#fef9c4,stroke:#ca8a04
```

## 5. Architecture Layer Enforcement (레이어 규칙)

```mermaid
graph TD
    L1["Types / Entity\n(Layer 1)"] --> L2["Config\n(Layer 2)"]
    L2 --> L3["Repository\n(Layer 3)"]
    L3 --> L4["Service\n(Layer 4)"]
    L4 --> L5["Controller\n(Layer 5)"]

    L5 -.->|"🚫 BLOCKED"| L3
    L4 -.->|"🚫 BLOCKED"| L1
    L3 -.->|"🚫 BLOCKED"| L5

    style L1 fill:#e0e7ff,stroke:#4338ca
    style L2 fill:#dbeafe,stroke:#2563eb
    style L3 fill:#d1fae5,stroke:#059669
    style L4 fill:#fef3c7,stroke:#d97706
    style L5 fill:#fee2e2,stroke:#dc2626
```

## 6. OMC Integration (oh-my-claudecode 연동)

```mermaid
flowchart LR
    subgraph OMC["oh-my-claudecode"]
        OMC_Hooks["OMC Hooks"]
        OMC_Modes["Modes\n(autopilot, ralph, team)"]
        OMC_Agents["OMC Agents"]
    end

    subgraph Bridge["harness-hook-bridge.js"]
        Chain["Hook Chaining\nOMC + Harness 동시 평가"]
    end

    subgraph Harness["AI Harness"]
        H_Hooks["Harness Hooks"]
        H_Skills["Harness Skills"]
        H_Teams["Team Configs"]
    end

    OMC_Hooks --> Chain
    H_Hooks --> Chain
    Chain -->|"Both Pass"| Allow["✅ Allow"]
    Chain -->|"Any Block"| Deny["🚫 Block"]

    OMC_Modes -->|"mode-configs/*.json"| Harness
    OMC_Agents -->|"custom-agents/"| Harness

    style OMC fill:#f3e8ff,stroke:#7c3aed
    style Bridge fill:#fef3c7,stroke:#d97706
    style Harness fill:#d1fae5,stroke:#059669
```

## 7. 파일 구조 요약

```mermaid
graph LR
    Root["ai-harness/"]

    Root --> hooks["hooks/\n(5 global hooks)"]
    Root --> skills["skills/\n(7 core skills)"]
    Root --> teams["teams/\n(6 teams)"]
    Root --> scripts["scripts/\n(10 utilities)"]
    Root --> templates["templates/\n(configs, agents,\nskills, workflows)"]
    Root --> global["global/\n(8 shared skills)"]
    Root --> omc["omc-integration/\n(bridge + mode configs)"]
    Root --> docs["docs/\n(28 planning + 8 SDD)"]
    Root --> custom["custom-agents/\n(company-specific)"]
    Root --> runtime[".ai-harness/\n(runtime state)"]

    teams --> t_be["backend/"]
    teams --> t_fe["frontend/"]
    teams --> t_pl["planning/"]
    teams --> t_ds["design/"]
    teams --> t_do["devops/"]
    teams --> t_qa["qa/"]

    style Root fill:#f1f5f9,stroke:#475569,stroke-width:2px
    style hooks fill:#fee2e2,stroke:#dc2626
    style skills fill:#dbeafe,stroke:#2563eb
    style teams fill:#d1fae5,stroke:#059669
    style scripts fill:#fef3c7,stroke:#d97706
    style templates fill:#f3e8ff,stroke:#7c3aed
    style runtime fill:#e2e8f0,stroke:#64748b,stroke-dasharray:5
```

## 8. Skills 카탈로그

```mermaid
mindmap
  root((AI Harness Skills))
    Core Management
      harness-init
      harness-status
      harness-rules
      harness-team
      harness-exclude
      harness-metrics
      harness-scaffold
    Backend
      convention-backend
      api-design
      entity
      migration
      agent-map
    Frontend
      convention-frontend
      component
      storybook
      e2e
    Planning
      create-prd
      user-stories
      jira
      jira-checklist
      ui-ux-pro-max
      +21 more
    Global
      test-scenario
      regression
      smoke-test
      deploy-check
      rollback-plan
      infra-plan
      onboard
      handoff
```
