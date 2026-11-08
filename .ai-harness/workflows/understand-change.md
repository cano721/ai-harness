# Understand Change — ai-harness

플러그인 전역 Skill `/ai-harness:understand-change`가 런타임에 읽는 이 저장소의 설명 정책이다(사람 소유, 없어도 Skill은 내장 기본값으로 동작한다).

## 먼저 읽을 문서

- `.ai-harness/docs/architecture.md` — 변경이 어느 층(hook·script·Skill·템플릿·생성물)인지
- 변경이 템플릿이면 `skills/harness-init/SKILL.md`의 해당 절과 `templates/managed-files.json`
- 사용자 영향은 `CHANGELOG.md`의 `## Unreleased` 항목

## 직접 검증

```bash
bash tests/run.sh
```

변경된 스크립트는 `HARNESS_METRICS_DIR=$(mktemp -d)`로 격리해 직접 실행해 본다.

## 설명 깊이

- small: 한 스크립트 안의 수정, 문구·예시 변경
- standard: 여러 스크립트·Skill에 걸친 변경, 새 하위 명령, 템플릿 변경(다른 프로젝트의 생성물이 바뀐다)
- deep: 이벤트 스키마·manifest 형식·러너 그래프 계약·무인 실행(harvest·sync·autofix·자동 병합) 동작 변경

## 공유 위치

PR 본문(GitHub `cano721/ai-harness`). 공개 저장소이므로 설명에 회사·개인 식별자를 넣지 않는다.
