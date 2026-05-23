#!/usr/bin/env python3
"""Download Gemma 4 26B A4B 4-bit MLX weights into the repo's models/ dir.

Usage:
    pip install -U huggingface_hub
    python scripts/download_model.py
"""
from pathlib import Path
from huggingface_hub import snapshot_download

REPO = "mlx-community/gemma-4-26b-a4b-it-4bit"

repo_root = Path(__file__).resolve().parent.parent
target = repo_root / "models" / "gemma-4-26b-a4b-it-4bit"
target.mkdir(parents=True, exist_ok=True)

snapshot_download(repo_id=REPO, local_dir=str(target))
print(f"Downloaded to: {target}")
