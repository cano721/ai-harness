# AI Harness - 비용 추적 모델

## 토큰 비용 산출

```
모델별 단가 (cost-rates.yaml에서 중앙 관리):

│ 모델               │ Input $/1M   │ Output $/1M  │
│ claude-opus-4-6    │ $15.00       │ $75.00       │
│ claude-sonnet-4-6  │ $3.00        │ $15.00       │
│ claude-haiku-4-5   │ $0.80        │ $4.00        │

비용 = (input_tokens × input_rate) + (output_tokens × output_rate)
```

## 3단계 한도

| 단계 | 기준 | 동작 |
|------|------|------|
| **경고** | 한도의 70% | 경고 메시지 표시 |
| **중단 요청** | 한도의 90% | 계속 여부 확인 |
| **강제 중단** | 한도 100% | 작업 중단, 로깅 |

```yaml
cost:
  limits:
    per_session_usd: 5.00
    per_day_usd: 20.00
    per_week_usd: 100.00
    per_month_usd: 300.00
  mode_overrides:
    autopilot: { per_session_usd: 10.00 }
    ralph: { per_session_usd: 15.00 }
```

## 토큰 사용량 데이터 소스

에이전트별로 토큰 사용량을 획득하는 방법이 다르다.

| 에이전트 | 데이터 소스 | 정확도 | 방법 |
|---------|-----------|--------|------|
| **Claude Code** | API 응답 usage 필드 | 정확 | PostToolUse Hook에서 `$TOOL_RESULT`의 `usage.input_tokens`, `usage.output_tokens` 파싱 |
| **Codex CLI** | CLI 래퍼 출력 파싱 | 정확 | `ai-harness wrap codex` 실행 시 출력에서 토큰 정보 추출 |
| **Cursor** | 추정 (문자 수 기반) | 추정 | 입력 문자 수 × 1.3 (토큰 추정 계수), 모델별 단가 적용 |
| **Gemini CLI** | API 응답 usage 필드 | 정확 | Claude Code와 동일한 방식 |

### Claude Code 토큰 획득 상세

```
PostToolUse Hook 실행 시:
  1. Claude Code가 Hook에 전달하는 환경변수에서 세션 정보 읽기
  2. ~/.claude/projects/*/sessions/*.jsonl에서 최근 메시지의 usage 파싱
  3. input_tokens + output_tokens를 cost-rates.yaml 단가와 곱하여 비용 산출
  4. 결과를 감사 로그에 cost 이벤트로 기록
```

### Tier 2/3 에이전트 추정 방법

```
정확한 토큰 수를 얻을 수 없는 에이전트:
  1. 입력: 프롬프트 문자 수 × 1.3 (영문 기준, 한국어는 × 2.0)
  2. 출력: 응답 문자 수 × 1.3
  3. 추정값에 1.2 안전 계수를 곱하여 보수적 추정
  4. 추정값임을 감사 로그에 명시 ("estimated": true)
```

---

## 조회 & 리포트

```bash
$ ai-harness cost                    # 현재 세션/일/주/월 비용
$ ai-harness cost --daily            # 일별 상세 (모델별)
$ ai-harness cost --by project       # 프로젝트별
$ ai-harness cost --by team          # 팀별
$ ai-harness cost --by mode          # OMC 모드별
$ ai-harness cost export             # CSV 내보내기
$ ai-harness cost optimize           # 비용 최적화 제안
```

## 비용 최적화 제안

감사 로그 분석을 통해 자동 제안:
- 모델 다운그레이드 가능 영역
- 불필요한 컨텍스트 (파일 읽기 비중 분석)
- ralph 루프 최적화 (진전 없는 루프 감지)
