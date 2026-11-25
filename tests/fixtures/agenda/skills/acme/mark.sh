#!/usr/bin/env bash
# 가짜 connect·disconnect: 불린 것을 표시 파일로 남긴다.
set -euo pipefail
mkdir -p "$HM_DATA_DIR/fixture-acme"
printf '%s\n' "$1" >>"$HM_DATA_DIR/fixture-acme/marks"
