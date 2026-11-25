#!/usr/bin/env bash
# 가짜 done: 받은 인자를 기록하고, 다음 fetch가 그 항목을 빼게 한다.
set -euo pipefail
mkdir -p "$HM_DATA_DIR/fixture-acme"
printf '%s\n' "$*" >>"$HM_DATA_DIR/fixture-acme/done-args"
printf '%s\n' "$1" >>"$HM_DATA_DIR/fixture-acme/done"
