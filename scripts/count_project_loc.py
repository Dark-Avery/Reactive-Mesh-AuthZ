#!/usr/bin/env python3

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent

ALL_INCLUDE = [
    "receiver",
    "baseline",
    "grpc",
    "idp",
    "envoy-custom",
    "deploy",
    "bench",
    "scripts",
    "formal/tla",
]

CORE_INCLUDE = [
    "receiver",
    "baseline/opa",
    "grpc",
    "idp",
    "envoy-custom",
    "bench/load-client",
    "scripts",
    "formal/tla",
]

PURE_CORE_INCLUDE = [
    "receiver/cpp",
    "envoy-custom/reactive_pep",
    "idp/demo",
    "grpc/cpp",
    "grpc/proto",
]

CORE_PLUS_BASELINE_INCLUDE = [
    "receiver/cpp",
    "envoy-custom/reactive_pep",
    "idp/demo",
    "grpc/cpp",
    "grpc/proto",
    "baseline/opa",
]

EXCLUDE_DIRS = {
    ".git",
    ".github",
    ".venv",
    "__pycache__",
    "build",
    "dist",
    "distfiles",
    "deliverables",
    "envoy-src",
    "experiments",
    "node_modules",
    "results",
}

CODE_EXTENSIONS = {
    ".bzl",
    ".c",
    ".cc",
    ".cfg",
    ".conf",
    ".cpp",
    ".h",
    ".hpp",
    ".proto",
    ".py",
    ".rego",
    ".sh",
    ".tla",
    ".tpl",
    ".yaml",
    ".yml",
}


def should_skip(path: Path) -> bool:
    name = path.name
    if any(part in EXCLUDE_DIRS for part in path.parts):
        return True
    if "generated" in path.parts:
        return True
    if name.endswith(("_pb.cc", "_pb.h", ".pb.cc", ".pb.h", ".pb.go", ".pb.validate.cc", ".pb.validate.h")):
        return True
    if "_TTrace_" in name:
        return True
    if path.suffix.lower() not in CODE_EXTENSIONS:
        return True
    return False


def count_group(paths: list[str]) -> dict[str, object]:
    files: list[tuple[str, int]] = []
    total = 0
    for rel in paths:
        base = ROOT / rel
        if not base.exists():
            continue
        for path in base.rglob("*"):
            if not path.is_file() or should_skip(path):
                continue
            lines = path.read_text(encoding="utf-8", errors="ignore").count("\n") + 1
            rel_path = str(path.relative_to(ROOT))
            files.append((rel_path, lines))
            total += lines
    files.sort(key=lambda item: (-item[1], item[0]))
    return {
        "total_loc": total,
        "file_count": len(files),
        "top_files": [{"path": path, "loc": loc} for path, loc in files[:20]],
    }


def main() -> None:
    data = {
        "reactive_iam_pure_core": count_group(PURE_CORE_INCLUDE),
        "reactive_iam_core_plus_baseline": count_group(CORE_PLUS_BASELINE_INCLUDE),
        "reactive_iam_core_with_verification": count_group(CORE_INCLUDE),
        "all_authored": count_group(ALL_INCLUDE),
    }
    print(json.dumps(data, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
