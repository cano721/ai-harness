### 새 기능
- 기본 스킬 카탈로그에 `ga`(Google Analytics 4 조회, 읽기 전용)를 더했습니다. 서비스 계정 JSON 키로 GA4 Data API의 리포트·실시간·metadata를 조회하고(`--filter`·`--order -<지표>`·`--prop <별칭>`), `/setup`이 발급 안내(서비스 계정 → JSON 키 → Data API 사용 설정 → GA 속성 뷰어 추가)·키 파일을 `~/.ai-harness/keys/ga.json`(600)으로 복사해 저장(원본 삭제 안내)·`setup.sh check ga` 연결 확인(403·Data API 미사용 설정 원인 안내)까지 합니다. 기존 사용자에게는 다음 세션 시작 때 새 기본 스킬로 한 번 안내됩니다. (#639)
