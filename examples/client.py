"""Call Strands Decider on EKS from your own code (standard library only).

  python examples/client.py http://<nlb-dns-name>          # from inside the VPC, after ./quickstart.sh expose
  kubectl -n decider port-forward svc/decider 8080:8080 &   # or, from a laptop with kubectl access:
  python examples/client.py http://127.0.0.1:8080

The request is the strands-decider "System One" shape: a state (the text to decide about) and named
questions. Question types: "noul" (yes/no probability), "choice" (pick one option; give criteria),
"score" (an ordinal scale; give criteria as a list). One request can ask several questions at once.
"""
import http.client
import json
import sys
import urllib.parse


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

URL = (sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8080").rstrip("/") + "/invocations"

request = {
    "state": "A customer wrote to support: I was charged twice for my subscription this month.",
    "questions": {
        "route": {
            "type": "choice",
            "instructions": "Which team should handle this message?",
            "criteria": {
                "billing": "Charges, refunds, invoices",
                "technical": "Bugs, errors, outages",
                "sales": "Plans, pricing, demos",
                "unknown": "Not about this product",
            },
        },
        "urgent": {"type": "noul", "instructions": "Does the customer need an answer today?"},
    },
}

out = post_json(URL, request, timeout=60)

route = out["answers"]["route"]
print(f"route: {route['choice']} (confidence {route['confidence']:.2f})")
print(f"urgent: p={out['answers']['urgent']['noul']:.2f}")
print(f"server time: {out.get('server_ms')} ms, answered by {out.get('host')}")
# A common pattern: act on confident answers, escalate the rest to an LLM.
if route["confidence"] < 0.6:
    print("low confidence: escalate to a larger model")
