### 새 기능
- `.ai-harness/docs/ui.md`에 화면별 렌더 대상(chromium·webkit·firefox·simulator/emulator)을 적으면, 러너의 화면 검증(ui_review·design-polish measure)이 그 엔진으로 렌더링하고 증거에 사용한 엔진을 남깁니다. 선언한 엔진이 없으면 다른 엔진으로 대신 돌리지 않고 미검증으로 멈춥니다. (#678)

### 업데이트 후 해야 할 일
- 하네스 sync 뒤 `.ai-harness/docs/ui.md` 화면 표에 렌더 대상을 실측으로 적습니다. 비워 두면 chromium으로 검증합니다. webkit·firefox가 필요하면 승인 뒤 `npx playwright install webkit` 같은 명령으로 설치합니다. (#678)
