"""Choose CONFIDENCE_THRESHOLD from your own labeled messages.

  python threshold.py labeled.jsonl            # one JSON object per line: {"text": "...", "route": "<team>"}

Sends every message to the decision model once (the same request the triage agent makes), then prints,
for each candidate threshold, how many messages the decision model would answer on its own and how many
of those it routes correctly. The rest would escalate to the foundation model. Pick the lowest threshold
whose accuracy you are happy to accept without escalation.
"""
import json
import sys

from triage import decide

THRESHOLDS = [0.5, 0.6, 0.7, 0.8, 0.9]


def main(path: str) -> None:
    with open(path, encoding="utf-8") as fh:
        rows = [json.loads(line) for line in fh if line.strip()]
    scored = []
    for i, row in enumerate(rows, 1):
        route = decide(row["text"])["answers"]["route"]
        scored.append((route["confidence"], route["choice"] == row["route"]))
        if i % 25 == 0 or i == len(rows):
            print(f"scored {i}/{len(rows)}", file=sys.stderr)
    print(f"{len(scored)} labeled messages")
    print(f"{'threshold':>9}  {'answered alone':>14}  {'correct when alone':>18}  {'escalated':>9}")
    for t in THRESHOLDS:
        alone = [ok for conf, ok in scored if conf >= t]
        share = len(alone) / len(scored)
        acc = sum(alone) / len(alone) if alone else 0.0
        print(f"{t:>9.2f}  {share:>14.0%}  {acc:>18.0%}  {1 - share:>9.0%}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "/bench/data/routing-100.jsonl")
