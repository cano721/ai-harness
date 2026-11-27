---
name: ga
description: Google Analytics 4(GA4) 속성의 사용자·세션·이벤트·전환·페이지·실시간 지표를 Data API로 조회한다. 읽기 전용이다. "GA", "GA4", "구글 애널리틱스", "사용자 수", "이벤트 수", "실시간 사용자", "전환" 조회와, 배포·캠페인 전후 지표 비교에 쓴다. 여러 속성을 별칭으로 등록해 오간다.
---

# GA4 (Google Analytics Data API)

GA4 Data API(`analyticsdata.googleapis.com/v1beta`)의 `runReport`·`runRealtimeReport`·`metadata`를 `scripts/ga.py`로 호출한다. Python 표준 라이브러리와 `openssl`만 쓴다. 읽기 전용이다(scope `analytics.readonly`) — 속성 설정·데이터 변경은 이 스킬로 하지 않는다.

## 사용자 규칙 (먼저 읽기)

`${HARNESS_METRICS_DIR:-$HOME/.ai-harness}/skills/ga.md`가 있으면 호출 전에 Read하고 따른다. `/ai-harness:setup`이 회사·팀 전용 값(속성 별칭과 그 의미, 기본 기간, 사내 다른 데이터 소스와 숫자 정의 차이)을 적어 두는 파일이다. 이 본문과 다르면 그 파일이 이긴다 — 단 자격 증명을 다루는 방식은 이 본문을 따른다. 파일이 없으면 이 본문의 일반 규칙대로 하고, 매번 같은 값을 묻게 되면 `/ai-harness:setup`으로 저장하자고 한 번 제안한다.

## 인증 — 서비스 계정 JSON 키

| 환경변수 | 설명 |
|---|---|
| `GA_KEY_FILE` | 서비스 계정 JSON 키 파일 경로. `/ai-harness:setup`이 받은 파일을 `${HARNESS_METRICS_DIR:-~/.ai-harness}/keys/ga.json`(0600)으로 복사해 그 경로를 저장한다(원본은 확인 뒤 사용자가 지운다) |
| `GA_PROPERTY_ID` | 기본 속성의 **숫자 속성 ID**(GA 관리 → 속성 세부정보). `G-XXXX` 측정 ID가 아니다 |
| `GA_PROPERTY_<별칭>` | 다른 속성. 별칭 → 접미사: 대문자 + `-`→`_` (`checkout-web` → `GA_PROPERTY_CHECKOUT_WEB`), `--prop checkout-web` |

- `ga.py`는 프로세스 환경 → `~/.claude/settings.json`의 `env` → `${HARNESS_METRICS_DIR:-~/.ai-harness}/secrets.env` 순서로 읽는다. 방금 저장한 값도 세션 재시작 없이 쓴다.
- **키 파일 내용은 비밀이다.** 경로는 적어도 되지만 파일을 Read·`cat`·`jq`로 열거나 내용을 대화·이슈·PR에 옮기지 않는다. `ga.py`가 서명할 때만 읽고, 출력하는 것은 서비스 계정 이메일(`client_email`)뿐이다.
- 키 파일을 그룹·다른 사용자가 읽거나 쓸 수 있으면(권한 끝 두 자리가 0이 아니면, 예: 0644) `ga.py`가 호출을 거부한다 — 사용자에게 `chmod 600 <경로>`를 안내한다.
- 액세스 토큰은 `${HARNESS_METRICS_DIR:-~/.ai-harness}/cache/ga-token.json`(0600)에 키 파일별로 한 시간 캐시된다.
- 별칭을 줬는데 그 속성이 없으면 기본 속성으로 대신하지 않고 멈춘다 — 다른 속성 숫자를 그 속성 것으로 오인하지 않기 위해서다.
- 키·속성이 없거나 `check`가 실패하면 `/ai-harness:setup`(Codex는 ai-harness setup 스킬)으로 안내한다.

## 도구

스크립트 경로는 이 SKILL.md 옆 `scripts/`. 아래 `ga`는 `python3 -I <skill-dir>/scripts/ga.py`를 뜻한다.

```bash
ga aliases                                   # 등록된 속성 별칭·ID와 키 파일 상태
ga check                                     # 키·토큰·속성 접근 확인 (속성 metadata 조회)
ga meta [검색어]                             # 쓸 수 있는 dimension·metric 이름 찾기
ga report --days 7 --metrics activeUsers,sessions --dims date
ga report --start 2026-11-01 --end 2026-11-25 --metrics eventCount --dims eventName --order -eventCount --limit 30
ga realtime --metrics activeUsers --dims unifiedScreenName     # 최근 30분
ga raw '<runReport JSON 본문>'               # 옵션으로 표현이 안 되는 요청
```

- 공통 옵션: `--prop <별칭>`, `--filter`, `--order <이름>`(앞에 `-`면 내림차순, `--order -activeUsers`), `--limit N`(기본 50), `--json`(원본 응답), `--dry-run`(보낼 본문만 출력, 호출 안 함).
- 필터: `field==value`(일치) · `field!=value`(제외) · `field=~value`(포함) · `field^=value`(시작), 쉼표는 AND. 예: `--filter "eventName==sign_up,platform^=Android"`. OR·숫자 비교는 `raw`로 `dimensionFilter`·`metricFilter`를 직접 쓴다.
- 값에 쉼표가 들어 있으면(쉼표는 AND로 쪼개진다) `--filter` 대신 `raw`로 `dimensionFilter`를 직접 쓴다.
- 기간을 안 주면 최근 7일(오늘 포함). `--end`는 `--start`와 함께만 쓴다. 날짜는 GA 속성의 시간대 기준이다.
- 출력은 탭 구분 표, stderr에 행 수·합계(`TOTAL`)와 임계값·샘플링 표시.

## 규칙

- 이름을 추측하지 않는다 — 처음 쓰는 dimension·metric은 `ga meta <검색어>`로 확인한다. 커스텀 이벤트 매개변수는 `customEvent:<이름>`, 커스텀 측정항목은 `customEvent:<이름>`(metric) 형태다.
- 보고할 때 숫자를 표째 옮기지 말고 핵심만 요약하고, 쓴 속성(별칭)·기간·필터를 한 줄로 적는다.
- stderr에 `thresholding`(적은 사용자 수 행을 가림)이나 `sampled`가 보이면 함께 알린다 — 합계가 실제보다 작을 수 있다.
- GA 숫자는 사내 로그·DB 집계와 다를 수 있다(사용자·세션 정의, 동의 모드, 봇 필터, 시간대). 다른 소스와 맞대기 전에 사용자 규칙 파일의 정의 차이부터 확인하고, 없으면 차이가 날 수 있다고 적는다.
- 개인 식별 가능한 값(사용자 ID 등)을 차원으로 뽑아 이슈·문서·PR에 옮기지 않는다.

## 오류

| 증상 | 원인 · 조치 |
|---|---|
| `HTTP 403` · `PERMISSION_DENIED` | 서비스 계정 이메일이 그 GA 속성에 없음 — GA 관리 → 속성 액세스 관리에 `ga check`가 보여 준 이메일을 **뷰어**로 추가 |
| `SERVICE_DISABLED` · "has not been used" · "is disabled" | 키를 만든 GCP 프로젝트에서 Google Analytics Data API를 사용 설정하지 않음 — API 및 서비스 → 라이브러리에서 사용 설정 후 몇 분 기다림 |
| `token request failed` · `invalid_grant` | 키가 폐기됐거나 컴퓨터 시계가 어긋남 — 새 JSON 키를 받아 `/ai-harness:setup`으로 다시 저장 |
| `key file permissions` | `chmod 600 <키 파일>` |
| `openssl failed` | 키 파일 손상(서명 실패) — 새 JSON 키를 받아 `/ai-harness:setup`으로 다시 저장 |
| `openssl not available` | openssl을 실행하지 못함 — openssl을 설치하고 PATH에 있는지 확인 |
| `key temp file failed` | 서명용 임시 키 파일을 쓰지 못함 — 하네스 데이터 폴더의 `cache/ga-sign` 권한과 디스크 공간 확인 |
| `bad property` | `G-XXXX`(측정 ID)를 넣음 — 숫자 속성 ID로 바꾼다 |
| `HTTP 400` | dimension·metric 조합이 호환되지 않거나 이름이 틀림 — 메시지를 보고 `ga meta`로 확인 |
