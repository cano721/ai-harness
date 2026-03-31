#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Compatibility wrapper for running ui-ux-pro-max from the skill root."""

from __future__ import annotations

import os
import runpy
import sys
from pathlib import Path

SKILL_ROOT = Path(__file__).resolve().parent.parent
SRC_ROOT = SKILL_ROOT / 'src' / 'ui-ux-pro-max'
SOURCE_SCRIPTS_DIR = SRC_ROOT / 'scripts'
SEARCH_SCRIPT = SOURCE_SCRIPTS_DIR / 'search.py'

if not SEARCH_SCRIPT.exists():
    raise SystemExit(f'Missing source search script: {SEARCH_SCRIPT}')

os.environ.setdefault('UI_UX_PRO_MAX_SKILL_ROOT', str(SKILL_ROOT))
os.environ.setdefault('UI_UX_PRO_MAX_SRC_ROOT', str(SRC_ROOT))

if str(SOURCE_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SOURCE_SCRIPTS_DIR))

runpy.run_path(str(SEARCH_SCRIPT), run_name='__main__')
