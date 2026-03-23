---
name: harness-exclude
description: 글로벌 하네스에서 프로젝트를 제외합니다
---

<Purpose>글로벌 하네스가 적용되지 않을 프로젝트를 관리합니다.</Purpose>

<Use_When>
- "이 프로젝트 하네스에서 제외해줘", "제외 목록 보여줘", "harness exclude"
</Use_When>

<Steps>
### 제외 추가
1. ~/.ai-harness/config.yaml Read
2. exclude_projects 배열에 현재 프로젝트 경로 추가
3. Write로 저장
4. "글로벌 하네스에서 제외되었습니다" 안내

### 제외 제거
1. ~/.ai-harness/config.yaml Read
2. exclude_projects 배열에서 경로 제거
3. Write로 저장

### 제외 목록
1. ~/.ai-harness/config.yaml Read
2. exclude_projects 배열 표시
</Steps>
