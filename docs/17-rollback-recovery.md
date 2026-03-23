# AI Harness - 롤백 & 복구

## 문제 정의

하네스 업데이트나 설정 변경이 문제를 일으킬 수 있는 시나리오:

| 시나리오 | 증상 | 심각도 |
|---------|------|--------|
| 업데이트 후 Hook 호환 깨짐 | 모든 에이전트 작업 차단 | 🔴 Critical |
| 새 잠금 정책이 기존 프로젝트와 충돌 | 특정 프로젝트에서 작업 불가 | 🟡 High |
| CLAUDE.md 주입 로직 버그 | 기존 CLAUDE.md 내용 손상 | 🟡 High |
| 설정 병합 버그 | 의도하지 않은 규칙 적용 | 🟠 Medium |
| Hook 성능 저하 | 에이전트 응답 느려짐 | 🟠 Medium |

---

## 스냅샷 시스템

### 자동 스냅샷 시점

```
스냅샷이 자동 생성되는 시점:

1. ai-harness init          → 설치 전 상태 스냅샷
2. ai-harness update        → 업데이트 전 스냅샷
3. ai-harness config set    → 설정 변경 전 스냅샷
4. ai-harness team add/remove → 팀 변경 전 스냅샷
5. ai-harness hook enable/disable → Hook 변경 전 스냅샷
```

### 스냅샷 구조

```
.ai-harness/
├── config.yaml                    # 현재 설정
├── snapshots/
│   ├── manifest.json              # 스냅샷 인덱스
│   ├── snap-20260318-140000/      # 타임스탬프 기반 ID
│   │   ├── meta.json              # 스냅샷 메타데이터
│   │   ├── config.yaml            # 당시 설정
│   │   ├── claude-md.md           # 당시 CLAUDE.md (하네스 구간)
│   │   ├── settings-hooks.json    # 당시 Hook 설정
│   │   └── lock-policy.yaml       # 당시 잠금 정책
│   ├── snap-20260317-093000/
│   └── ...
```

### 스냅샷 메타데이터

```json
// snapshots/snap-20260318-140000/meta.json
{
  "id": "snap-20260318-140000",
  "created_at": "2026-03-18T14:00:00Z",
  "trigger": "update",
  "description": "ai-harness update (v1.2.0 → v1.3.0)",
  "harness_version": "1.2.0",
  "config_package_version": "1.2.0",
  "teams": ["frontend", "backend"],
  "hook_count": 7,
  "user": "khb1122",
  "files": [
    "config.yaml",
    "claude-md.md",
    "settings-hooks.json",
    "lock-policy.yaml"
  ]
}
```

### 스냅샷 보존 정책

```yaml
snapshots:
  max_count: 20              # 최대 20개 보존
  max_age_days: 90           # 90일 이상 된 스냅샷 삭제
  auto_cleanup: true         # 한도 초과 시 가장 오래된 것부터 삭제
  protected:                 # 삭제 방지 태그
    - "before-major-update"
    - "known-good"
```

---

## 롤백 명령어

### 인터랙티브 롤백

```
$ ai-harness rollback

  ━━━ 롤백 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  사용 가능한 스냅샷:

  #  시점              트리거     버전    설명
  ── ──────────────── ───────── ──────── ─────────────────────
  1  2026-03-18 14:00  update    v1.2.0  update (v1.2.0 → v1.3.0)
  2  2026-03-17 09:30  config    v1.2.0  config set max_cost_usd 10
  3  2026-03-16 11:15  init      v1.2.0  최초 설치
  4  2026-03-15 16:00  team      v1.2.0  team add frontend

  롤백할 스냅샷 번호: 1

  ━━━ 변경 사항 미리보기 ━━━━━━━━━━━━━━━━━━━━━━━

  [되돌릴 항목]
  - harness 버전: v1.3.0 → v1.2.0
  - config.yaml: 3개 항목 변경
  - CLAUDE.md: 보안 규칙 2개 제거 (v1.3.0에서 추가된 것)
  - Hook: secret-scanner 패턴 변경 복원

  [유지되는 항목]
  - 프로젝트 로컬 설정 (config.yaml의 프로젝트 오버라이드)
  - 감사 로그 (삭제하지 않음)

  롤백을 실행할까요? (Y/n): Y

  ✔ config.yaml 복원
  ✔ CLAUDE.md 복원
  ✔ settings.json Hook 복원
  ✔ 롤백 완료 (snap-20260318-140000 → 현재)

  새 스냅샷 생성: snap-20260318-143000 (롤백 전 상태 보존)
```

### 직접 지정 롤백

```bash
# 특정 스냅샷으로 롤백
$ ai-harness rollback --to snap-20260317-093000

# 마지막 변경 취소 (undo)
$ ai-harness rollback --last

# dry-run (변경 사항 확인만)
$ ai-harness rollback --to snap-20260318-140000 --dry-run

# 특정 항목만 롤백
$ ai-harness rollback --to snap-20260318-140000 --only config
$ ai-harness rollback --to snap-20260318-140000 --only hooks
$ ai-harness rollback --to snap-20260318-140000 --only claude-md
```

### 롤백 안전장치

```
롤백 시 자동 수행:

1. 현재 상태를 스냅샷으로 저장 (롤백의 롤백 가능)
2. 잠금 정책 호환성 검증
   - 롤백 대상이 현재 잠금 정책보다 느슨하면 경고
   - 보안 Hook가 비활성화되는 경우 추가 확인
3. Hook 테스트 자동 실행
   - 롤백 후 모든 Hook의 기본 테스트 실행
   - 실패 시 경고 (롤백 자체는 완료)
4. doctor 실행
   - 롤백 후 전체 설정 검증
```

---

## 버전 고정 (Pinning)

### 안정 버전 고정

```yaml
# .ai-harness/config.yaml

# 설정 패키지 버전을 고정하여 자동 업데이트 방지
config_package: "@our-company/harness-config"
config_version: "1.2.0"        # 정확한 버전
# config_version: "~1.2.0"     # 패치만 허용
# config_version: "^1.2.0"     # 마이너까지 허용
# config_version: "latest"     # 항상 최신 (기본)

# 하네스 코어 버전 고정
core_version: ">=1.0.0 <2.0.0"  # 메이저 업데이트 차단
```

### known-good 스냅샷

```bash
# 현재 상태를 "검증된 안정 버전"으로 태깅
$ ai-harness snapshot tag --name "known-good" --description "QA 검증 완료 상태"

  ✔ 스냅샷 snap-20260318-140000에 태그 추가: known-good
  이 스냅샷은 자동 정리에서 보호됩니다.

# 언제든 known-good 상태로 복구
$ ai-harness rollback --tag known-good
```

---

## 긴급 복구 절차

### Level 1: 설정 롤백 (가장 빠름)

```bash
# 마지막 변경 취소
$ ai-harness rollback --last
# 소요: 즉시
```

### Level 2: 하네스 비활성화 (작업 계속 필요할 때)

```bash
# 하네스를 일시적으로 끔
$ ai-harness bypass --reason "업데이트 호환 문제 조사 중"
# 소요: 즉시
# 효과: 모든 Hook 비활성, 에이전트 정상 사용 가능
```

### Level 3: 전체 재설치 (설정 손상 시)

```bash
# 하네스 제거 후 재설치
$ ai-harness uninstall
$ ai-harness init --config @our-company/harness-config@1.2.0
# 소요: 1~2분
# 주의: 로컬 설정 커스텀이 초기화됨
```

### Level 4: 수동 복구 (CLI가 동작하지 않을 때)

```bash
# 하네스가 관리하는 Hook을 수동으로 제거
# .claude/settings.json에서 _managed_by: "ai-harness" 항목 삭제

# CLAUDE.md에서 하네스 구간 제거
# <!-- harness:start --> ~ <!-- harness:end --> 삭제

# 하네스 설정 디렉토리 제거
$ rm -rf .ai-harness/

# 이후 재설치
$ ai-harness init
```

---

## 업데이트 안전 프로토콜

### 단계적 롤아웃

```
중앙 관리자가 업데이트를 배포할 때:

Phase 1: Canary (1~2일)
  ├── 하네스 관리자 본인의 프로젝트에서 먼저 테스트
  └── 문제 없으면 다음 단계

Phase 2: Early Adopter (3~5일)
  ├── 자원자 팀 또는 비핵심 프로젝트에 적용
  ├── 피드백 수집
  └── 문제 없으면 다음 단계

Phase 3: General Availability
  ├── 전사 업데이트 알림
  ├── 각 팀이 자율적으로 update 실행
  └── 강제 업데이트는 보안 패치만
```

### 업데이트 전 자동 검증

```
$ ai-harness update

  ━━━ 업데이트 전 검증 ━━━━━━━━━━━━━━━━━━━━━━━━━

  1. 현재 상태 스냅샷 생성... ✔
  2. 변경 사항 분석... ✔
  3. 호환성 검증...
     ✔ 프로젝트 설정과 충돌 없음
     ✔ 새 잠금 정책이 현재 설정을 위반하지 않음
     ⚠ 새 Hook 'dependency-check' 추가됨 (재시작 필요)
  4. 롤백 가능 확인... ✔

  안전하게 업데이트할 수 있습니다.
  문제 발생 시: ai-harness rollback --last
```

---

## 스냅샷 관리 CLI

```bash
# 스냅샷 목록
$ ai-harness snapshot list
  #  ID                    시점              태그         트리거
  ── ───────────────────── ──────────────── ──────────── ─────────
  1  snap-20260318-143000  2026-03-18 14:30  -           rollback
  2  snap-20260318-140000  2026-03-18 14:00  known-good  update
  3  snap-20260317-093000  2026-03-17 09:30  -           config

# 스냅샷 상세
$ ai-harness snapshot show snap-20260318-140000

# 스냅샷 비교
$ ai-harness snapshot diff snap-20260317-093000 snap-20260318-140000
  config.yaml:
  + guardrails.max_cost_usd: 10.0  (was: 5.0)
  hooks:
  + secret-scanner: 패턴 3개 추가

# 스냅샷 태그
$ ai-harness snapshot tag snap-20260318-140000 --name "pre-react19"

# 스냅샷 삭제
$ ai-harness snapshot delete snap-20260316-111500

# 스냅샷 내보내기 (다른 프로젝트로 이동)
$ ai-harness snapshot export snap-20260318-140000 > snapshot.tar.gz
```
