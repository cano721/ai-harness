# AI Harness - 트러블슈팅 가이드

## 빠른 진단

```bash
# 무조건 이것부터 실행
$ ai-harness doctor
```

doctor가 동작하지 않으면 수동 진단 절차로 이동.

---

## 증상별 해결법

### 1. "모든 명령이 차단됨"

**증상**: 에이전트가 아무 것도 할 수 없음. 모든 도구 사용이 BLOCKED.

```
원인 진단:
┌─ Hook 브릿지 크래시?
│  $ node --version     # Node.js 동작 확인
│  $ ai-harness hook list  # Hook 목록 출력 확인
│
├─ 잠금 Hook 에러로 fail-closed 발동?
│  $ cat .ai-harness/logs/$(date +%Y-%m-%d).jsonl | grep '"result":"error"'
│
└─ 설정 파일 손상?
   $ ai-harness config show   # 파싱 에러 확인
```

**해결법**:
```bash
# 즉시 해제: 바이패스 모드
$ HARNESS_BYPASS=true claude

# 원인 파악 후:
$ ai-harness rollback --last           # 마지막 변경 취소
# 또는
$ ai-harness hook reset block-dangerous # 특정 Hook 리셋
```

---

### 2. "CLAUDE.md에 하네스 규칙이 안 보임"

**증상**: `ai-harness init` 했는데 CLAUDE.md에 harness 섹션이 없음.

```
원인 진단:
┌─ CLAUDE.md 자체가 없는가?
│  $ ls .claude/CLAUDE.md
│
├─ harness:start 마커가 있는가?
│  $ grep "harness:start" .claude/CLAUDE.md
│
└─ init이 실제로 완료됐는가?
   $ cat .ai-harness/config.yaml   # 설정 파일 존재 확인
```

**해결법**:
```bash
# 재주입
$ ai-harness sync

# 그래도 안 되면 재설치
$ ai-harness uninstall && ai-harness init
```

---

### 3. "Hook이 실행되지 않음"

**증상**: 위험 명령을 해도 차단되지 않음, 감사 로그가 안 쌓임.

```
원인 진단:
┌─ settings.json에 Hook이 등록되어 있는가?
│  $ grep "ai-harness" .claude/settings.json
│
├─ Hook 스크립트가 실행 가능한가?
│  $ ai-harness hook test block-dangerous
│
└─ 서킷 브레이커가 열려 있는가?
   $ ai-harness health
```

**해결법**:
```bash
# Hook 재등록
$ ai-harness sync

# 서킷 브레이커 리셋
$ ai-harness hook reset --all

# Hook 스크립트 권한 수정
$ chmod +x .ai-harness/hooks/*.sh
```

---

### 4. "에이전트가 느려졌다"

**증상**: 하네스 설치 후 에이전트 응답이 눈에 띄게 느림.

```
원인 진단:
$ ai-harness perf

  Hook 실행 시간 (최근 1시간):
  block-dangerous:  p50=2ms   p95=5ms    ✅
  audit-logger:     p50=8ms   p95=15ms   ✅
  secret-scanner:   p50=40ms  p95=120ms  ✅
  bundle-size:      p50=8s    p95=25s    🔴 ← 범인
  sql-review:       p50=200ms p95=800ms  ⚠
```

**해결법**:
```bash
# 느린 Hook 비활성화 (free Hook만 가능)
$ ai-harness hook disable bundle-size --reason "성능 이슈 조사 중"

# 타임아웃 조정
$ ai-harness config set timeouts.hook_overrides.bundle-size 5000

# 비동기 모드로 전환 (Post Hook만)
$ ai-harness config set hooks.bundle-size.async true
```

---

### 5. "업데이트 후 동작이 이상함"

**증상**: `ai-harness update` 후 예상치 못한 차단, 설정 변경 등.

**해결법**:
```bash
# 1단계: 무엇이 변경됐는지 확인
$ ai-harness snapshot diff --last

# 2단계: 롤백
$ ai-harness rollback --last

# 3단계: 선택적 업데이트
$ ai-harness update --select
```

---

### 6. "팀 전환 후 이전 팀 Hook이 남아있음"

**증상**: `ai-harness team switch frontend` 했는데 backend Hook이 계속 실행됨.

**해결법**:
```bash
# sync로 설정 재적용
$ ai-harness sync

# 현재 적용 중인 Hook 확인
$ ai-harness hook list --active

# 강제 재초기화
$ ai-harness team switch frontend --force
```

---

### 7. "MCP 서버 연결 실패"

**증상**: Jira/Confluence MCP 서버가 연결되지 않음.

```
원인 진단:
$ ai-harness doctor

  [MCP 서버]
  ✔ jira-server       → 등록됨
  ❌ confluence-server → 등록됨, 연결 실패 (timeout)
```

**해결법**:
```bash
# MCP 서버 재등록
$ ai-harness mcp reconnect confluence-server

# 네트워크 확인
$ curl -I https://your-company.atlassian.net

# MCP 설정 확인
$ cat .claude/settings.json | grep -A5 "confluence"
```

---

### 8. "비용 추적이 0으로 표시됨"

**증상**: `ai-harness cost`가 항상 $0.00.

```
원인:
- 감사 로깅 Hook이 비활성화됨
- 또는 cost 이벤트 로깅이 비활성화됨
```

**해결법**:
```bash
# 감사 로거 상태 확인
$ ai-harness hook list | grep audit-logger

# 비용 로깅 활성화
$ ai-harness config set cost.tracking_enabled true
```

---

## 수동 복구 가이드

### CLI가 아예 동작하지 않을 때

```bash
# 1. 하네스 Hook을 settings.json에서 수동 제거
#    .claude/settings.json 열고 _managed_by: "ai-harness" 항목 삭제

# 2. CLAUDE.md에서 하네스 구간 제거
#    <!-- harness:start --> ~ <!-- harness:end --> 사이 삭제

# 3. 하네스 디렉토리 정리
$ rm -rf .ai-harness/

# 4. 재설치
$ npm install -g @ai-harness/core
$ ai-harness init
```

### 로그 파일이 디스크를 가득 채울 때

```bash
# 즉시 정리
$ ai-harness audit prune --older-than 7d

# 로그 크기 확인
$ ai-harness audit stats

# 보존 기간 축소
$ ai-harness config set compliance.retention.local_logs.default_days 14
```

---

## doctor 출력 해석

```
$ ai-harness doctor

  [환경]
  ✔ Claude Code v2.1.x        # 정상
  ✔ Node.js v20.x              # 정상
  ✔ Git 저장소                  # 정상
  ⚠ OMC v4.x.x (업데이트 가능) # 경고: 동작하지만 최신 아님

  [하네스]
  ✔ 버전: v1.3.0 (최신)        # 정상
  ❌ 설정 파일: 파싱 에러       # 에러 → config.yaml 구문 확인
  ✔ 잠금 정책                  # 정상

  [Hook 연결]
  ✔ block-dangerous            # 정상
  ❌ audit-logger: not found   # 에러 → Hook 스크립트 없음
  ⚠ bundle-size: OPEN          # 경고: 서킷 브레이커 열림

  [수정 제안]
  1. .ai-harness/config.yaml line 23: YAML 구문 오류 수정
  2. audit-logger.sh 재설치: ai-harness hook reinstall audit-logger
  3. bundle-size 서킷 리셋: ai-harness hook reset bundle-size
```

---

## 자주 묻는 질문 (FAQ)

| 질문 | 답변 |
|------|------|
| 하네스를 끄고 싶다 | `HARNESS_BYPASS=true claude` 또는 `ai-harness bypass` |
| 특정 Hook만 끄고 싶다 | `ai-harness hook disable <hook명>` (잠금 Hook은 불가) |
| 다른 프로젝트에 같은 설정 적용 | 그 프로젝트에서 `ai-harness init` (같은 config 패키지면 동일 설정) |
| 로그를 보고 싶다 | `ai-harness audit summary` 또는 `cat .ai-harness/logs/오늘날짜.jsonl` |
| 롤백하고 싶다 | `ai-harness rollback --last` |
| 하네스 완전 삭제 | `ai-harness uninstall` |
