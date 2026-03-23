# AI Harness - 마이그레이션 경로

## 대상 시나리오

| 시나리오 | 난이도 | 설명 |
|---------|--------|------|
| **A. 빈 프로젝트** | 쉬움 | CLAUDE.md 없음, `ai-harness init`으로 끝 |
| **B. CLAUDE.md만 있는 프로젝트** | 보통 | 기존 규칙 보존하며 하네스 주입 |
| **C. OMC 사용 중인 프로젝트** | 보통 | OMC Hook과 하네스 Hook 체이닝 |
| **D. 커스텀 Hook이 있는 프로젝트** | 어려움 | 기존 Hook과 하네스 Hook 충돌 방지 |

---

## 시나리오 B: 기존 CLAUDE.md 보존 마이그레이션

### 비파괴적 주입

```markdown
# 기존 CLAUDE.md (100% 보존)

## 우리 프로젝트 규칙
- 모든 API는 v2 사용
- 커밋 메시지에 Jira 이슈번호 포함
...

# ─── AI Harness (자동 생성, 수동 편집 금지) ───
<!-- harness:start -->
## [Harness] 회사 공통 규칙
- 보안 필수 규칙 ...

## [Harness] 백엔드팀 규칙
- API 규칙 ...
<!-- harness:end -->
```

### 충돌 감지

```
$ ai-harness init

  ⚠ 기존 CLAUDE.md에서 하네스 규칙과 중복 감지:

  ┌─────────────────────────────────────────────┐
  │ 기존: "커밋 메시지에 Jira 이슈번호 포함"     │
  │ 하네스: "커밋 메시지에 이슈 번호 필수"        │
  │ → 유사 규칙 (기존 유지, 하네스에서 제외)      │
  └─────────────────────────────────────────────┘

  중복 제거 후 진행할까요? (Y/n): _
```

---

## 시나리오 D: 커스텀 Hook 공존

### 기존 Hook 감지

```
$ ai-harness init

  ━━━ 기존 Hook 감지 ━━━━━━━━━━━━━━━━━━━━━━━━━━

  .claude/settings.json에 기존 Hook 2개 발견:

  1. PreToolUse: "npm run lint-check" (matcher: Write)
  2. PostToolUse: "npm run test-changed" (matcher: Edit)

  처리 방법:
  1. 하네스 Hook 뒤에 기존 Hook 실행 (권장)
  2. 기존 Hook을 하네스 팀 Hook으로 마이그레이션
  3. 기존 Hook 그대로 유지, 하네스 Hook만 추가

  선택: 1
```

### Hook 실행 순서 (공존 모드)

```
PreToolUse:
  1. harness/global/*     (하네스 공통)
  2. harness/team/*       (하네스 팀별)
  3. existing hooks       (기존 커스텀 Hook)
  4. omc hooks            (OMC)
```

---

## 점진적 마이그레이션 전략

### Phase 1: 관찰 모드 (1주)

```bash
$ ai-harness init --mode observe

# 관찰 모드: Hook을 등록하되 차단하지 않음
# 차단 대신 "차단했을 것" 로그만 기록
```

```
[하네스-관찰] 이 명령은 block-dangerous Hook에 의해 차단될 예정입니다:
  명령: git push --force origin main
  정책: force push 차단
  ※ 관찰 모드이므로 실행을 허용합니다.
```

### Phase 2: 경고 모드 (1주)

```bash
$ ai-harness config set mode warn

# 경고 모드: 차단 대신 경고 + 사용자 확인
```

```
[하네스-경고] ⚠ force push가 감지되었습니다.
  정책: block-dangerous (차단 예정)
  계속 진행하시겠습니까? (Y/n): _
```

### Phase 3: 강제 모드 (정식)

```bash
$ ai-harness config set mode enforce

# 강제 모드: 잠금 Hook은 차단, 일반 Hook은 경고
```

### 모드 비교

| 모드 | 잠금 Hook | 일반 Hook | 감사 로깅 | 용도 |
|------|----------|----------|----------|------|
| **observe** | 로그만 | 로그만 | ✅ | 도입 초기, 영향도 파악 |
| **warn** | 확인 후 진행 | 경고 후 통과 | ✅ | 적응 기간 |
| **enforce** | 차단 | 경고/차단 | ✅ | 정식 운영 |

---

## 마이그레이션 CLI

```bash
# 마이그레이션 상태 확인
$ ai-harness migrate status
  현재 모드: warn
  관찰 기간: 7일 경과
  차단 예상 건수: 12건/일
  오탐 추정: 2건 (git push --force to feature branch)

# 다음 단계로 진행
$ ai-harness migrate next
  warn → enforce로 전환합니다.
  계속할까요? (Y/n): _

# 이전 단계로 복귀
$ ai-harness migrate back
  enforce → warn으로 전환합니다.
```

---

## 대규모 롤아웃 전략

```
전사 100개 프로젝트에 하네스를 도입할 때:

Week 1-2: Pilot (3개 프로젝트)
  ├── 하네스 관리자의 프로젝트
  ├── 자원자 팀 프로젝트 1개
  └── 비핵심 프로젝트 1개
  → observe 모드

Week 3-4: Early Adopter (10개 프로젝트)
  ├── 각 팀에서 1~2개 프로젝트
  └── warn 모드

Week 5-6: Rollout (50개 프로젝트)
  ├── 신규 프로젝트는 enforce
  └── 기존 프로젝트는 warn → enforce 전환

Week 7-8: Full Coverage (100개 프로젝트)
  └── 전체 enforce
```
