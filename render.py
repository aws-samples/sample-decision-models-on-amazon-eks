"""Render the quickstart's manifests from environment variables (quickstart.sh sets them from config.env
and the bootstrap stack) and print them; pipe to kubectl apply -f - or eksctl.

  python render.py cluster                         # eksctl ClusterConfig
  python render.py nodepools                       # the three arm64 NodePools (+ the GPU one if INSTANCE_GPU is set)
  python render.py decider --variant large-4x16-bf16 [--replicas N] [--no-tmpfs]
  python render.py decider --variant gpu-1x2-bf16  # one GPU per pod, on the optional GPU pool
  python render.py bench
  python render.py nlb                             # optional internal Network Load Balancer
  python render.py agent                           # the example triage agent

Variants are <pool>-<pods>x<threads>-<dtype>, pool = large, small or gpu. CPU requests leave about 2 vCPU per
node for the kubelet and DaemonSets, split evenly between the pods on a node. On CPU pools the weights are
staged into RAM by default (--no-tmpfs puts them on the node disk, which made cold start about 2.5x slower in
our tests); on the GPU pool they go on the node disk, as a g5.xlarge (16 GiB) can't also hold them in RAM.
Needs: CLUSTER, REGION, K8S_VERSION, NAME, BUCKET, KEY_ARN, API_CIDRS, ACCOUNT_ID, ESCALATION_MODEL_ID (cluster); INSTANCE_*, VCPU_*, MAX_NODES (nodepools);
IMAGE_URI, BUCKET, REGION, MODEL_ID, VCPU_LARGE / VCPU_SMALL (decider, bench); GPU_IMAGE_URI, VCPU_GPU (gpu variant); NLB_CIDRS (nlb); IMAGE_URI, REGION, ESCALATION_MODEL_ID, CONFIDENCE_THRESHOLD (agent).
"""
import argparse
import os
import string
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def env(name: str) -> str:
    v = os.environ.get(name)
    if not v:
        sys.exit(f"render.py: {name} is not set (run through quickstart.sh, or export it)")
    return v


def base_model(model_id: str) -> str:
    """The foundation model behind a cross-Region inference profile: eu.amazon.nova-2-lite-v1:0 -> amazon.nova-2-lite-v1:0."""
    head, _, rest = model_id.partition(".")
    return rest if head in ("eu", "us", "apac", "us-gov", "global", "jp", "au", "ca") else model_id


def cluster() -> str:
    cidrs = ", ".join(f'"{c.strip()}"' for c in env("API_CIDRS").split(",") if c.strip())
    return string.Template((HERE / "cluster.yaml.tpl").read_text()).substitute(
        CLUSTER=env("CLUSTER"), REGION=env("REGION"), K8S_VERSION=env("K8S_VERSION"), NAME=env("NAME"),
        BUCKET=env("BUCKET"), KEY_ARN=env("KEY_ARN"), API_CIDRS=cidrs, ACCOUNT_ID=env("ACCOUNT_ID"),
        ESCALATION_MODEL_ID=env("ESCALATION_MODEL_ID"), ESCALATION_BASE_MODEL=base_model(env("ESCALATION_MODEL_ID")))


def nodepools() -> str:
    m = int(env("MAX_NODES"))
    out = string.Template((HERE / "k8s/nodepools.yaml.tpl").read_text()).substitute(
        INSTANCE_LARGE=env("INSTANCE_LARGE"), INSTANCE_SMALL=env("INSTANCE_SMALL"), INSTANCE_BENCH=env("INSTANCE_BENCH"),
        CPU_LIMIT_LARGE=m * int(env("VCPU_LARGE")), CPU_LIMIT_SMALL=m * int(env("VCPU_SMALL")))
    if os.environ.get("INSTANCE_GPU"):
        out += "---\n" + string.Template((HERE / "k8s/nodepool-gpu.yaml.tpl").read_text()).substitute(
            INSTANCE_GPU=env("INSTANCE_GPU"), CPU_LIMIT_GPU=m * int(env("VCPU_GPU")))
    return out


def decider(variant: str, replicas: int | None, tmpfs: bool) -> str:
    pool, layout, dtype = variant.split("-")
    if pool not in ("large", "small", "gpu"):
        sys.exit(f"render.py: variant pool must be large, small or gpu, got {pool!r}")
    pods, threads = (int(x) for x in layout.split("x"))
    label, vcpu = pool, int(env(f"VCPU_{pool.upper()}"))
    gpu = pool == "gpu"
    if gpu and dtype != "bf16":
        sys.exit("render.py: the gpu variant serves the checkpoint's bf16 only (gpu-<pods>x<threads>-bf16)")
    fp32 = dtype == "fp32"
    tmpfs = tmpfs and not gpu
    return string.Template((HERE / "k8s/decider.yaml.tpl").read_text()).substitute(
        REPLICAS=replicas if replicas is not None else pods, VARIANT=variant, POOL=label,
        IMAGE=env("GPU_IMAGE_URI") if gpu else env("IMAGE_URI"), ARCH="amd64" if gpu else "arm64",
        DEVICE="cuda" if gpu else "cpu",
        GPU_TOLERATION="\n        - {key: nvidia.com/gpu, operator: Exists, effect: NoSchedule}" if gpu else "",
        GPU_REQUEST=', nvidia.com/gpu: "1"' if gpu else "",
        WEIGHTS_S3_URI=f"s3://{env('BUCKET')}/model/", REGION=env("REGION"), MODEL_NAME=env("MODEL_ID").split("/")[-1],
        DTYPE="fp32-layers" if fp32 else "bf16", THREADS=threads, CPU=max(1, (vcpu - 2) // pods),
        # In RAM the staged weights (4.8 GB) count against the pod's memory.
        MODEL_VOLUME="{medium: Memory, sizeLimit: 6Gi}" if tmpfs else "{sizeLimit: 12Gi}",
        MEM_REQUEST=("18Gi" if fp32 else "12Gi") if tmpfs else ("12Gi" if fp32 else "6Gi"),
        MEM_LIMIT=("26Gi" if fp32 else "18Gi") if tmpfs else ("20Gi" if fp32 else "12Gi"))


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("what", choices=["cluster", "nodepools", "decider", "bench", "nlb", "agent"])
    p.add_argument("--variant", default=os.environ.get("VARIANT", "large-4x16-bf16"))
    p.add_argument("--replicas", type=int)
    p.add_argument("--no-tmpfs", action="store_true")
    a = p.parse_args()
    if a.what == "cluster":
        sys.stdout.write(cluster())
    elif a.what == "nodepools":
        sys.stdout.write(nodepools())
    elif a.what == "nlb":
        cidrs = ", ".join(f'"{c.strip()}"' for c in env("NLB_CIDRS").split(",") if c.strip())
        sys.stdout.write(string.Template((HERE / "k8s/service-nlb.yaml.tpl").read_text()).substitute(NLB_CIDRS=cidrs))
    elif a.what == "agent":
        sys.stdout.write(string.Template((HERE / "k8s/agent.yaml.tpl").read_text()).substitute(
            IMAGE=env("IMAGE_URI"), REGION=env("REGION"), ESCALATION_MODEL_ID=env("ESCALATION_MODEL_ID"),
            CONFIDENCE_THRESHOLD=env("CONFIDENCE_THRESHOLD")))
    elif a.what == "decider":
        sys.stdout.write(decider(a.variant, a.replicas, not a.no_tmpfs))
    else:
        sys.stdout.write(string.Template((HERE / "k8s/bench.yaml.tpl").read_text()).substitute(IMAGE=env("IMAGE_URI")))
