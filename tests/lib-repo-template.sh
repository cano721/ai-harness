#!/usr/bin/env bash
# 가짜 저장소의 기준 템플릿(빈 커밋 init 하나와 user t@t)을 만드는 함수. tests/run.sh(실행 캐시)와 tests/lib.sh(영역 단독 실행 폴백)가
# source한다. 영역 파일이 아니다(tests/run.sh가 lib-*.sh를 건너뛴다). 영역은 템플릿을 cp -R의 원본으로만 읽는다(#614).

# dir에 템플릿을 만든다. 이미 있으면 그대로 둔다. 옆 임시 디렉토리에 만든 뒤 rename(2)로 확정한다 — BSD mv는 대상 디렉토리가
# 있으면 그 안으로 옮기므로 대상이 있으면 실패하는 rename을 직접 쓰고, 동시에 만든 쪽에 지면 자기 임시본을 지운다.
ensure_repo_template() { # dir
  local dir="$1" tmp
  [[ ! -d "$dir/.git" ]] || return 0
  tmp="$(mktemp -d "$dir.build.XXXXXX")"
  git init -q --template= "$tmp" # 훅 예시 등 템플릿 파일 없이 — 복사할 파일 수를 줄인다
  printf '[user]\n\temail = t@t\n\tname = t\n' >>"$tmp/.git/config"
  git -C "$tmp" commit -q --allow-empty -m init
  python3 -I -c 'import os, sys; os.rename(sys.argv[1], sys.argv[2])' "$tmp" "$dir" 2>/dev/null || rm -rf "$tmp"
  [[ -d "$dir/.git" ]]
}
