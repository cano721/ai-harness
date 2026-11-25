### 동작 변경

- **기능 PR의 변경 항목을 `changelog.d/` 조각 파일에 씁니다** — PR마다 `changelog.d/<이슈>-<요약>.md`에 소제목과 항목을 쓰고, 릴리스 때 `scripts/release-prep.sh <version>`이 소제목별로 합쳐 버전 절을 만든 뒤 조각을 지웁니다. `--check`는 조각 형식도 검사합니다. 동시에 열린 PR들이 `CHANGELOG.md` 맨 위에서 충돌하지 않습니다. (#558)
  요약: 변경 항목은 이제 `CHANGELOG.md` 대신 `changelog.d/` 아래 PR별 파일에 적습니다. 릴리스 노트 형식은 그대로입니다.
