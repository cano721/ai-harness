# SDD 04 - Hook 실행 엔진 상세

## Hook 규약

### 입력
Hook 스크립트는 2개 인자를 받는다:
```bash
$1 = TOOL_NAME    # "Bash", "Write", "Edit", "Read", "Grep" 등
$2 = TOOL_INPUT   # 도구에 전달되는 입력 (명령어, 파일 경로 등)
```

### Exit Code
```
exit 0  →  통과 (도구 실행 허용)
exit 2  →  차단 (도구 실행 차단, stdout을 차단 사유로 표시)
그 외   →  에러 (에러 정책에 따라 처리)
```

### stdout
- exit 0: 무시됨
- exit 2: 차단 사유로 사용자에게 표시
- 에러: 에러 메시지로 로깅

---

## Hook 스크립트 상세

### 1. block-dangerous.sh (PreToolUse)

```
목적: 위험한 명령/패턴을 실행 전에 차단
시점: PreToolUse
잠금: locked (비활성화 불가)

차단 패턴:
  Bash 도구:
    - rm -rf (rm과 -r, -f 플래그 조합)
    - DROP TABLE/DATABASE/INDEX
    - git push --force (main/master 대상)
    - TRUNCATE TABLE
    - chmod 777
    - sudo

  모든 도구:
    - ai-harness bypass/hook disable/uninstall (자기 보호)
    - HARNESS_BYPASS 환경변수 설정

통과 조건:
    - 위 패턴에 매칭되지 않는 모든 입력
```

### 2. secret-scanner.sh (PreToolUse)

```
목적: 민감 정보가 코드/커밋에 포함되는 것을 방지
시점: PreToolUse (Write, Edit 도구 대상)
잠금: locked

차단 패턴:
  - AWS Access Key: AKIA[0-9A-Z]{16}
  - Generic Secret: (?i)(password|secret|token|api[_-]?key)\s*[=:]\s*['"][^\s'"]{8,}
  - Private Key: -----BEGIN.*PRIVATE KEY-----
  - .env 파일 쓰기: .env, .env.* 파일에 쓰기 시도

경고 패턴 (차단하지 않고 경고):
  - 하드코딩된 IP 주소
  - localhost URL with port

허용 목록:
  - **/test**/**, **/*.test.*, **/fixtures/** 경로
  - EXAMPLE_, DUMMY_, FAKE_ 접두사
```

### 3. audit-logger.sh (PostToolUse)

```
목적: 모든 AI 에이전트 액션을 JSONL로 기록
시점: PostToolUse
잠금: locked (비활성화 불가)

동작:
  1. 현재 날짜로 로그 파일 경로 결정 (.ai-harness/logs/YYYY-MM-DD.jsonl)
  2. 로그 디렉토리 없으면 생성
  3. JSONL 엔트리 생성 (timestamp, tool, action, result, user, project)
  4. 민감 정보 마스킹 (패턴 매칭)
  5. 파일에 append

마스킹:
  - Bearer/Authorization 헤더 값 → ***REDACTED***
  - password= 뒤의 값 → ***REDACTED***
  - 200자 초과 내용 → 첫 50자 + ... (truncated)
```

---

## Hook 체이닝 순서

```
PreToolUse (순차, 하나라도 exit 2면 전체 차단):
  1. block-dangerous.sh
  2. secret-scanner.sh
  3. (팀별 Hook - Phase 2)

PostToolUse (감사 로깅은 항상 실행):
  1. audit-logger.sh
  2. (팀별 Hook - Phase 2)
```

---

## Hook 테스트 실행 엔진

```
ai-harness hook test <hook-name>

1. hooks/<hook-name>.sh 파일 존재 확인
2. hooks/<hook-name>.test.yaml 파일 로드
3. 각 테스트 케이스에 대해:
   a. Hook 스크립트를 서브프로세스로 실행
   b. $1=tool, $2=input 전달
   c. exit code와 stdout 캡처
   d. expect_exit, expect_output_contains와 비교
   e. PASS/FAIL 판정
4. 전체 결과 요약 출력
```
