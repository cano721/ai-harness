### 버그 수정
- `git reset --soft <ref>`로 HEAD의 조상이 아닌 커밋(남의 새 커밋) 위로 브랜치를 옮기려 하면 Bash 가드가 막고 `git rebase`를 안내합니다. 자기 커밋을 합치는 `reset --soft $(git merge-base HEAD <ref>)`는 그대로 됩니다. 끄려면 `HM_STALE_RESET_GUARD=0`. #601
- 그래프 러너가 publish 전후와 병합 직전에 브랜치가 기준 브랜치의 최근 변경을 옛 내용으로 되돌리거나 다른 이슈의 changelog 조각을 지웠는지 검사해, 그런 경우 파일 목록과 함께 사람에게 넘깁니다. 수동 병합 전 검사는 `workflow-driver.sh revert-check --base <branch>`. #601
