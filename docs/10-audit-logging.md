# AI Harness - 감사 로깅 설계

## 개요

AI 에이전트의 모든 액션을 기록하여 추적, 분석, 개선에 활용. 감사 로깅은 잠금 정책으로 비활성화 불가.

## 로그 이벤트 유형

| 유형 | 설명 | 예시 |
|------|------|------|
| **tool_use** | AI가 도구를 사용한 액션 | 파일 읽기/쓰기, bash 실행 |
| **hook_trigger** | Hook 트리거 이벤트 | 위험 명령 차단, 보안 스캔 경고 |
| **gate_decision** | 승인 게이트 결과 | 사용자 승인/거부 |
| **mode_event** | OMC 모드 상태 변경 | autopilot 시작/완료 |
| **error** | 에러 발생 | Hook 실패, 도구 실행 오류 |
| **cost** | API 비용 발생 | 토큰 사용량, 예상 비용 |

## 로그 포맷 (JSONL)

```json
{
  "timestamp": "2026-03-18T14:32:15.123Z",
  "session_id": "sess_abc123",
  "event_type": "tool_use",
  "tool": "Bash",
  "action": "git push origin feature/login",
  "result": "blocked",
  "reason": "force push 차단 정책",
  "user": "khb1122",
  "project": "ats-frontend",
  "team": ["frontend"]
}
```

## 저장

- **로컬**: `.ai-harness/logs/YYYY-MM-DD.jsonl` (일별 JSONL)
- **압축**: 7일 이상 자동 gzip
- **보존**: 기본 30일, 초과 시 자동 삭제
- **원격**: 선택 사항 (Phase 3)

## 조회

```bash
$ ai-harness audit summary          # 오늘 요약
$ ai-harness audit filter --result blocked  # 차단 이력
$ ai-harness audit cost             # 비용 조회
$ ai-harness audit export --format csv      # 내보내기
```

## 민감 정보 처리

| 패턴 | 마스킹 결과 |
|------|------------|
| API 키/토큰 | `***REDACTED_TOKEN***` |
| 비밀번호 | `***REDACTED_PASSWORD***` |
| 이메일 | `u***@company.com` |
| 파일 내용 (> 200자) | 첫 50자 + `... (truncated)` |
