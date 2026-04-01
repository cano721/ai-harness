#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Shared path resolution for the UI/UX Pro Max skill."""

from __future__ import annotations

import os
from pathlib import Path


def _is_valid_src_root(path: Path) -> bool:
    return path.is_dir() and all((path / name).is_dir() for name in ("data", "scripts", "templates"))


def _resolve_src_root() -> Path:
    env_src_root = os.environ.get("UI_UX_PRO_MAX_SRC_ROOT")
    if env_src_root:
        candidate = Path(env_src_root).expanduser().resolve()
        if _is_valid_src_root(candidate):
            return candidate

    current_file = Path(__file__).resolve()
    for parent in (current_file.parent, *current_file.parents):
        direct_candidate = parent
        nested_candidate = parent / "src" / "ui-ux-pro-max"

        if _is_valid_src_root(direct_candidate):
            return direct_candidate
        if _is_valid_src_root(nested_candidate):
            return nested_candidate

    raise FileNotFoundError(
        "Could not locate the ui-ux-pro-max source root containing data/, scripts/, and templates/."
    )


def _resolve_skill_root(src_root: Path) -> Path:
    env_skill_root = os.environ.get("UI_UX_PRO_MAX_SKILL_ROOT")
    if env_skill_root:
        candidate = Path(env_skill_root).expanduser().resolve()
        if (candidate / "SKILL.md").exists():
            return candidate

    candidate = src_root.parent.parent
    if (candidate / "SKILL.md").exists():
        return candidate

    return candidate


SRC_ROOT = _resolve_src_root()
SKILL_ROOT = _resolve_skill_root(SRC_ROOT)
DATA_DIR = SRC_ROOT / "data"
TEMPLATES_DIR = SRC_ROOT / "templates"
SOURCE_SCRIPTS_DIR = SRC_ROOT / "scripts"
ROOT_SCRIPTS_DIR = SKILL_ROOT / "scripts"

__all__ = [
    "DATA_DIR",
    "ROOT_SCRIPTS_DIR",
    "SKILL_ROOT",
    "SOURCE_SCRIPTS_DIR",
    "SRC_ROOT",
    "TEMPLATES_DIR",
]
