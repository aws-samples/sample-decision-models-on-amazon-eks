"""Download Strands Decider and its base model into plain folders and point the Decider
config at the local base model, so loading needs no network and no Hugging Face cache.

Usage: python stage_model.py <out_dir> <decider_repo> <base_repo> [--base-path /opt/model/qwen]

MODEL_REVISION and BASE_MODEL_REVISION (environment) pin the two downloads. With no
BASE_MODEL_REVISION, the base model is fetched at the revision the checkpoint records (its config's
base_revision, else provenance.json), as strands-decider's own loader does.
"""
import json
import os
import shutil
import sys
from pathlib import Path

from huggingface_hub import snapshot_download

CONFIG_NAMES = ("strands_decider_config.json", "hobson_config.json")

out, decider, base = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
base_path = sys.argv[sys.argv.index("--base-path") + 1] if "--base-path" in sys.argv else "/opt/model/qwen"
ckpt = out / "decider"
snapshot_download(decider, local_dir=ckpt, revision=os.environ.get("MODEL_REVISION") or None)

cfg_path = next((ckpt / n for n in CONFIG_NAMES if (ckpt / n).exists()), None)
if cfg_path is None:
    sys.exit(f"{decider}: no {' or '.join(CONFIG_NAMES)}")
cfg = json.loads(cfg_path.read_text())
base_rev = os.environ.get("BASE_MODEL_REVISION")
if not base_rev and base != cfg.get("base_model"):
    print(f"warning: {decider} was trained on {cfg.get('base_model')}, not {base}; fetching {base}@main")
elif not base_rev:
    base_rev = cfg.get("base_revision")
prov = ckpt / "provenance.json"
if not base_rev and base == cfg.get("base_model") and prov.exists():
    meta = json.loads(prov.read_text())
    if meta.get("base_model") == cfg.get("base_model"):
        base_rev = meta.get("base_model_revision")
print(f"base model {base}@{base_rev or 'main'}")
snapshot_download(base, local_dir=out / "qwen", revision=base_rev or None)

# Load the base model from base_path, and stop the loader asking the Hub for a revision offline.
cfg["base_model"] = base_path
cfg["base_revision"] = None
cfg_path.write_text(json.dumps(cfg, indent=2))
print("patched", cfg_path, "->", base_path)
for p in (ckpt / ".cache", out / "qwen" / ".cache"):
    if p.exists():
        shutil.rmtree(p)
