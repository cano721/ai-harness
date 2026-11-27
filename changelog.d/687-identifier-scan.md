### 새 기능

- **공개 저장소 식별자 검사 `scripts/identifier-scan.sh`와 CI 단계** — 회사명·사용자 ID·실명 같은 금지어를 테스트마다 정규식으로 박아 두면 목록 자체가 공개되고, 검사하지 않는 경로(CHANGELOG·주석·픽스처)에는 식별자가 쌓였습니다. 이제 금지어 목록을 저장소 밖(`HM_IDENTIFIER_DENYLIST` 환경변수 → `~/.ai-harness/config`)에서 읽어 추적 파일 전체를 대소문자 무시로 검사하고, 매치는 `파일:줄`만 출력합니다. 목록이 없으면 건너뜁니다. (#687)
  요약: 식별자 검사 목록이 소스에서 빠지고, 저장소 전체를 한 스크립트로 검사합니다.

### 업데이트 후 해야 할 일

- **기여자는 `HM_IDENTIFIER_DENYLIST`를 설정합니다** — 로컬은 `~/.ai-harness/config`에 `HM_IDENTIFIER_DENYLIST="a|b"`, CI는 저장소 secret `HM_IDENTIFIER_DENYLIST`(값은 `|` 또는 줄바꿈 구분). 설정하지 않으면 검사가 건너뜀으로 통과합니다. (#687)
