# Strands Decider 2B on Amazon EKS. Build context: this folder.
#   ./quickstart.sh image          CPU image, built in CodeBuild natively on arm64 (Graviton nodes)
#   ./quickstart.sh image gpu      optional GPU image (TORCH_VARIANT=cuda), built on x86_64 for NVIDIA nodes
# The server (app/app.py) exposes /ping, /invocations, /v1/systemone and /health on port 8080.
# Weights are not baked in: the app copies them from S3 at start (WEIGHTS_S3_URI, EKS Pod Identity).
# The same image carries the example triage agent (examples/agent, Strands Agents) and the test tools
# (bench/ and the routing-100 set), so pods in the cluster can run them.
# Pinned to the multi-arch index digest of python:3.12.16-slim (10 Nov 2026), so every build starts from the same base;
# the apt-get upgrade below then adds the Debian security fixes current at build time.
FROM public.ecr.aws/docker/library/python:3.12.16-slim@sha256:5e2bdb1b0d542d5039cffb8181c65930093949194a65c365dfb1b0fe13a4fa5b
ENV PIP_NO_CACHE_DIR=1 PYTHONUNBUFFERED=1
ARG TORCH_VERSION=2.14.1
ARG DECIDER_VERSION=0.3.0
ARG TRANSFORMERS_VERSION=5.20.2
ARG STRANDS_AGENTS_VERSION=1.62.0
# strands-agents 1.62.0 accepts mcp >=1.23,<2.2; 1.30.0 is the patched 1.x release (CVE-2026-59951).
ARG MCP_VERSION=1.30.0
ARG PIP_VERSION=26.2.2
# cpu: the CPU build of torch (arm64 image). cuda: the CUDA build from PyPI, with its NVIDIA runtime libraries
# and the flash-linear-attention kernels (strands-decider[cuda]); the node provides the driver.
ARG TORCH_VARIANT=cpu
ARG FLA_VERSION=0.6.0
# Debian security updates released after the base image was built. The GPU image also needs a C compiler:
# Triton (used by the flash-linear-attention kernels) compiles a small launcher the first time it runs.
# The base is pinned by digest, so the upgrade is how fixes released since then get in.
# nosemgrep: dockerfile.best-practice.avoid-apt-get-upgrade.avoid-apt-get-upgrade
RUN case "$TORCH_VARIANT" in cpu|cuda) ;; *) echo "TORCH_VARIANT must be cpu or cuda"; exit 1 ;; esac \
 && apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
 && if [ "$TORCH_VARIANT" = "cuda" ]; then \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gcc libc6-dev; fi \
 && apt-get clean && rm -rf /var/lib/apt/lists/*
# On CPU, torch comes from the PyTorch CPU index without its dependencies (that index carries older copies of
# filelock, setuptools and others); pip resolves them from PyPI with everything else. On CUDA, torch and its NVIDIA
# libraries come from PyPI. pip is needed only to build the image: the last step removes it, with the libraries it
# bundles (urllib3, msgpack, ...).
RUN pip install "pip==${PIP_VERSION}" \
 && if [ "$TORCH_VARIANT" = "cuda" ]; then \
      pip install "torch==${TORCH_VERSION}" "flash-linear-attention==${FLA_VERSION}" \
      && DECIDER="strands-decider[cuda]==${DECIDER_VERSION}"; \
    else \
      pip install --index-url https://download.pytorch.org/whl/cpu --no-deps "torch==${TORCH_VERSION}" \
      && DECIDER="strands-decider==${DECIDER_VERSION}"; \
    fi \
 && pip install "$DECIDER" "transformers==${TRANSFORMERS_VERSION}" \
      "strands-agents==${STRANDS_AGENTS_VERSION}" "mcp==${MCP_VERSION}" boto3 \
 && python -m pip uninstall -y pip \
 && rm -rf /root/.cache
WORKDIR /app
COPY app/app.py ./
COPY examples/agent/triage.py examples/agent/threshold.py /app/agent/
COPY bench/load.py /bench/bench/
COPY bench/data/routing-100.jsonl /bench/data/routing-100.jsonl
# Runs as a non-root user; the bench pod writes its results under /bench/results.
RUN useradd --create-home --uid 10001 decider && mkdir -p /bench/results/raw && chown -R 10001:10001 /bench
USER 10001
EXPOSE 8080
# For docker run. Kubernetes ignores HEALTHCHECK; the Deployment uses its own startup and readiness probes.
HEALTHCHECK --interval=30s --timeout=5s --start-period=180s --retries=3 \
  CMD ["python", "-c", "import http.client; c = http.client.HTTPConnection('127.0.0.1', 8080, timeout=4); c.request('GET', '/ping'); exit(c.getresponse().status != 200)"]
ENTRYPOINT ["python", "/app/app.py"]
