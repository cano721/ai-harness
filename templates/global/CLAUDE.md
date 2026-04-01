## AI Harness 보안 규칙

### 절대 금지
- 위험 명령 실행 금지 (rm -rf, DROP TABLE, force push, chmod 777, sudo)
- 시크릿/인증 정보 하드코딩 금지
- .env, credentials.json 등 민감 파일 커밋 금지

### 코드 작성 시
- 코드를 작성하거나 수정할 때는 반드시 해당 팀의 컨벤션 스킬을 참고하라
- Backend: /convention-backend
- Frontend: /convention-frontend
- 전체: /convention

### 컨텍스트 안전
- 대화가 10개 메시지 이상 진행되면, 파일 편집 전 반드시 해당 파일을 다시 읽어라 (자동 압축으로 기존 컨텍스트가 사라졌을 수 있음)
- 파일 편집 후 결과를 다시 읽어 변경이 정상 적용되었는지 확인하라 (Edit 도구의 silent failure 방어)
- 같은 파일에 3회 이상 편집 시 반드시 중간에 검증 읽기를 수행하라

### 이름 변경(Rename) 시 필수 검색
- 함수/타입/변수 이름을 변경할 때 단일 검색으로 끝내지 마라
- 상세 검색 항목은 /convention 참고

### 감사 추적
- 모든 도구 사용은 감사 로그에 기록됩니다
