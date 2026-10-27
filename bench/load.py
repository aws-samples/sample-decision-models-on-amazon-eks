"""Load test for the decision model on EKS, run from the bench pod inside the cluster (standard library only).

  python /bench/bench/load.py --url http://decider:8080 --label sweep --concurrency 1,2,4,8 --requests 48 [--warmup 4]

For each concurrency level, sends `--requests` routing-100 requests (cycling through the items) with that many in
flight, and records one JSON line per request: client and server latency, which pod answered, and whether the route
matched the label. Prints one summary line per level and writes /bench/results/raw/eks-<label>-<UTC>.jsonl.
"""
import argparse
import concurrent.futures as cf
import datetime as dt
import http.client
import json
import os
import statistics as st
import time
import urllib.parse
from collections import Counter

DATA = os.environ.get("BENCH_DATA", "/bench/data/routing-100.jsonl")
TEAMS = {
    "billing": "Charges, refunds, invoices from us, payment methods, plan prices already paid",
    "technical": "Bugs, errors, outages, integrations, API problems, wrong calculations",
    "sales": "New plans, pricing quotes, demos, trials, partnerships, buying more",
    "account": "Logins, users, permissions, 2FA, workspace and data settings",
    "unknown": "A general question that is not about AnyCompany Invoicing at all",
}


def payload(text: str) -> dict:
    return {
        "state": f"A customer sent this message to AnyCompany Invoicing support:\n\n{text}",
        "questions": {
            "route": {"type": "choice", "instructions": "Which team should handle this message?", "criteria": TEAMS},
            "in_scope": {"type": "noul",
                         "instructions": "Is this message about the AnyCompany Invoicing product or account?"},
        },
    }


def post_json(url: str, body: dict, timeout: float) -> dict:
    """POST JSON with http.client. Only http:// and https:// URLs; anything else (file://, ...) is refused."""
    u = urllib.parse.urlsplit(url)
    if u.scheme not in ("http", "https") or not u.hostname:
        raise ValueError(f"{url}: only http:// and https:// URLs are supported")
    conn_cls = http.client.HTTPSConnection if u.scheme == "https" else http.client.HTTPConnection
    conn = conn_cls(u.hostname, u.port, timeout=timeout)
    try:
        conn.request("POST", u.path or "/", body=json.dumps(body), headers={"Content-Type": "application/json"})
        resp = conn.getresponse()
        data = resp.read()
        if resp.status >= 400:
            raise RuntimeError(f"HTTP {resp.status}: {data[:200]!r}")
        return json.loads(data)
    finally:
        conn.close()


def call(url: str, item: dict) -> dict:
    t = time.perf_counter()
    try:
        out = post_json(url, payload(item["text"]), timeout=900)
        a = out["answers"]
        rec = {"ok": True, "route": a["route"]["choice"], "route_conf": a["route"]["confidence"],
               "route_probs": a["route"]["probabilities"], "in_scope_p": a["in_scope"]["noul"],
               "server_ms": out.get("server_ms"), "queue_ms": out.get("queue_ms"),
               "compute_ms": out.get("compute_ms"), "host": out.get("host"),
               "tokens_in": out.get("usage", {}).get("input_tokens")}
    except Exception as e:  # a failed request is a result
        rec = {"ok": False, "error": f"{type(e).__name__}: {e}"[:200]}
    rec["client_ms"] = round((time.perf_counter() - t) * 1000, 1)
    rec.update(id=item["id"], label_route=item["route"], label_in_scope=item["in_scope"], hard=item.get("hard"))
    return rec


def pct(xs, q):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(q * (len(xs) - 1))))] if xs else None


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--url", required=True)
    p.add_argument("--label", required=True)
    p.add_argument("--concurrency", default="1,2,4,8")
    p.add_argument("--requests", type=int, default=48)
    p.add_argument("--warmup", type=int, default=4, help="untimed requests first, at the highest concurrency")
    a = p.parse_args()
    url = a.url.rstrip("/") + "/v1/systemone"
    with open(DATA, encoding="utf-8") as fh:
        items = [json.loads(line) for line in fh if line.strip()]
    levels = [int(x) for x in a.concurrency.split(",")]
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    results = os.environ.get("RESULTS_DIR", "/bench/results/raw")
    os.makedirs(results, exist_ok=True)
    path = f"{results}/eks-{a.label}-{stamp}.jsonl"
    with cf.ThreadPoolExecutor(max(levels)) as ex:
        list(ex.map(lambda i: call(url, items[i % len(items)]), range(a.warmup)))
    with open(path, "w", encoding="utf-8") as f:
        for c in levels:
            t0 = time.perf_counter()
            with cf.ThreadPoolExecutor(c) as ex:
                recs = list(ex.map(lambda i: call(url, items[i % len(items)]), range(a.requests)))
            wall = time.perf_counter() - t0
            ok = [r for r in recs if r["ok"]]
            for r in recs:
                r.update(concurrency=c, label=a.label)
                f.write(json.dumps(r) + "\n")
            srv, cli = [r["server_ms"] for r in ok], [r["client_ms"] for r in ok]
            acc = sum(r["route"] == r["label_route"] for r in ok) / len(ok) if ok else None
            print(json.dumps({
                "label": a.label, "concurrency": c, "requests": len(recs), "ok": len(ok),
                "req_per_s": round(len(ok) / wall, 3), "wall_s": round(wall, 1),
                "server_p50_ms": round(st.median(srv)) if srv else None, "server_p95_ms": pct(srv, .95),
                "compute_p50_ms": round(st.median([r["compute_ms"] for r in ok if r.get("compute_ms") is not None] or [0])),
                "queue_p50_ms": round(st.median([r["queue_ms"] for r in ok if r.get("queue_ms") is not None] or [0])),
                "client_p50_ms": round(st.median(cli)) if cli else None, "client_p95_ms": pct(cli, .95),
                "route_acc": round(acc, 3) if acc is not None else None,
                "hosts": dict(Counter(r.get("host") for r in ok)),
            }), flush=True)
    print("wrote", path, flush=True)


if __name__ == "__main__":
    main()
