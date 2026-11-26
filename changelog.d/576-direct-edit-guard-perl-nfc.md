### 버그 수정

- **python3가 없어도 편집 가드가 한글(NFD) 폴더 저장소의 편집을 막습니다** — 생성된 direct-edit-guard가 경로 정규화에 python3만 써서, python3가 없거나 실패하는 macOS 환경에서는 NFD 폴더 저장소의 편집을 저장소 밖으로 오판해 통과시켰습니다. 이제 perl Unicode::Normalize로 대신 맞춥니다. (#576)
  요약: python3 없이도 perl로 경로를 맞춰 비교하므로, 컨벤션 문서를 읽지 않은 편집이 가드를 통과하지 않습니다. 기존 저장소는 `/harness-init --sync`로 가드를 다시 생성하면 반영됩니다.
