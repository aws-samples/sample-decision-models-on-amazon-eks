"""Decision-model server for Amazon EKS: POST /v1/systemone (and /invocations), GET /ping, GET /health.

Startup (once, before the server listens):
  1. Copy the model and its base model from S3 (WEIGHTS_S3_URI) into MODEL_DIR, an in-memory volume.
  2. Load the model with strands-decider, on CPU, in bf16 (DECIDER_CPU_DTYPE=bf16, the default here) or
     in fp32 (fp32-layers).
Each request returns the package's answers plus server_ms, queue_ms (waiting for this pod's lock),
compute_ms (the model call) and host (the pod that answered).
"""
import json
import os
import resource
import threading
import time

STARTED = time.time()
# Plain folders, no Hugging Face cache:
#   $MODEL_DIR/decider  (adapter, head, tokenizer; its config points base_model at $MODEL_DIR/qwen)
#   $MODEL_DIR/qwen     (the base model)
MODEL_DIR = os.environ.get("MODEL_DIR", "/opt/model")
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ.setdefault("HF_HOME", os.path.join(MODEL_DIR, ".hf-home"))  # inside the pod's model volume
HOST = os.environ.get("HOSTNAME", "")
STATS = {}


def log(msg, **kw):
    print(json.dumps({"msg": msg, "t": round(time.time() - STARTED, 2), **kw}), flush=True)


def stage_weights():
    uri = os.environ.get("WEIGHTS_S3_URI")
    marker = os.path.join(MODEL_DIR, ".staged")
    if not uri or os.path.exists(marker):
        STATS["stage_s"] = 0.0
        return
    from concurrent.futures import ThreadPoolExecutor

    import boto3
    from boto3.s3.transfer import TransferConfig

    bucket, _, prefix = uri.removeprefix("s3://").partition("/")
    s3 = boto3.client("s3")
    keys = [o for p in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix=prefix)
            for o in p.get("Contents", [])]
    cfg = TransferConfig(max_concurrency=16, multipart_chunksize=64 * 1024 * 1024)
    t = time.time()

    def get(o):
        dest = os.path.join(MODEL_DIR, o["Key"][len(prefix):].lstrip("/"))
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        s3.download_file(bucket, o["Key"], dest, Config=cfg)

    with ThreadPoolExecutor(8) as ex:
        list(ex.map(get, keys))
    with open(marker, "w", encoding="utf-8"):
        pass
    STATS["stage_s"] = round(time.time() - t, 2)
    STATS["stage_gb"] = round(sum(o["Size"] for o in keys) / 1e9, 2)
    log("weights staged", **STATS)


def _upcast_layers(engine) -> None:
    """Like the package's fp32 upcast, but one decoder layer at a time, so the bf16 and fp32
    copies of the whole model never exist together. The token embedding table stays in bf16;
    its output is cast to fp32 before the first layer."""
    import torch

    torso = engine.model.torso
    base = torso.get_base_model() if hasattr(torso, "get_base_model") else torso
    with torch.inference_mode():
        for layer in base.layers:
            layer.to(torch.float32)
        for name, mod in base.named_children():
            if name not in ("layers", "embed_tokens"):
                mod.to(torch.float32)
    base.embed_tokens.register_forward_hook(lambda m, i, out: out.to(torch.float32))


def load():
    import torch
    from strands_decider import infer
    from strands_decider.infer import load_engine

    threads = int(os.environ.get("DECIDER_THREADS", "0")) or os.cpu_count()
    torch.set_num_threads(threads)
    mode = os.environ.get("DECIDER_CPU_DTYPE", "bf16")
    if mode == "bf16":
        # Keep the bf16 weights as they are: on Graviton5 this is about twice as fast as fp32.
        infer.SystemOneEngine._upcast_torso_for_cpu = lambda self: None
    elif mode == "fp32-layers":
        infer.SystemOneEngine._upcast_torso_for_cpu = _upcast_layers
    t = time.time()
    log("loading", threads=threads, cpu_dtype=mode)
    engine = load_engine(os.path.join(MODEL_DIR, "decider"), device="cpu")
    # Report the checkpoint served (MODEL_NAME, set by the Deployment) as `model` in every response.
    engine.cfg.model_name = os.environ.get("MODEL_NAME", engine.cfg.model_name)
    STATS.update(load_s=round(time.time() - t, 2), threads=threads, cpu_dtype=mode, torch=torch.__version__)
    return engine


stage_weights()
ENGINE = load()
STATS["init_s"] = round(time.time() - STARTED, 2)
STATS["peak_rss_gb"] = round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e6, 2)
log("ready", **STATS)

from fastapi import FastAPI, HTTPException  # noqa: E402
from fastapi.responses import JSONResponse  # noqa: E402
from strands_decider.schema import SystemOneRequest  # noqa: E402

app = FastAPI()
# Serve one request at a time: each forward already uses all of the pod's threads, so overlapping
# forwards fight for the same cores. FastAPI runs sync handlers on a thread pool, so without this
# lock calls overlap.
LOCK = threading.Lock()


@app.get("/ping")
def ping():
    return {"status": "Healthy"}


@app.get("/health")
def health():
    return STATS


@app.post("/invocations")
@app.post("/v1/systemone")
def invocations(body: dict):
    t = time.perf_counter()
    try:
        with LOCK:
            t_lock = time.perf_counter()
            out = ENGINE.evaluate(SystemOneRequest(**body))
            t_done = time.perf_counter()
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    payload = out.model_dump()
    payload["server_ms"] = round((time.perf_counter() - t) * 1000, 2)
    payload["queue_ms"] = round((t_lock - t) * 1000, 2)
    payload["compute_ms"] = round((t_done - t_lock) * 1000, 2)
    payload["host"] = HOST
    return JSONResponse(payload)


if __name__ == "__main__":
    import uvicorn

    # Loopback unless told otherwise; the Deployment sets BIND_HOST=0.0.0.0 inside the pod, where only the
    # ClusterIP Service (and the optional internal NLB) can reach it.
    uvicorn.run(app, host=os.environ.get("BIND_HOST", "127.0.0.1"), port=int(os.environ.get("PORT", "8080")), workers=1)
