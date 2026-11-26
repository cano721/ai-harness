### 버그 수정

- 그래프 러너가 기준 브랜치보다 뒤처진 작업 브랜치를 시작 때 fast-forward로 따라잡고(자기 커밋·더러운 트리면 그대로 둠), brief·deliver·fix·repair 노드가 HEAD를 움직이는 git 작업을 하지 않도록 프롬프트에 명시해 `invariant_violation`으로 런이 끝나던 문제를 고친다. (#653)
