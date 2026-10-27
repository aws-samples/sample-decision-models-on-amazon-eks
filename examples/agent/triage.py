"""Triage agent: the decision model routes each support message, and a Strands agent on Amazon Bedrock
handles the messages it isn't confident about.

  POST /triage {"message": "..."}  ->  {"team", "decided_by", "confidence", ...}
  GET  /ping

For every message, one request to the decision model asks two questions at once: which team should
handle it (a choice), and whether it is about the product at all (a yes/no). When the route's confidence
is at least CONFIDENCE_THRESHOLD, the decision model's answer is used as it is. Below the threshold, the
message escalates to a Strands agent that runs a foundation model on Amazon Bedrock (ESCALATION_MODEL_ID)
and returns a team with structured output.

Environment: DECIDER_URL (default http://decider:8080), ESCALATION_MODEL_ID, CONFIDENCE_THRESHOLD
(default 0.7), AWS_REGION, BIND_HOST (default 127.0.0.1), PORT (default 8080).
"""
import http.client
import json
import os
import time
import urllib.parse
from typing import Literal

from pydantic import BaseModel, Field

DECIDER_URL = os.environ.get("DECIDER_URL", "http://decider:8080").rstrip("/") + "/v1/systemone"
ESCALATION_MODEL_ID = os.environ.get("ESCALATION_MODEL_ID", "eu.amazon.nova-2-lite-v1:0")
THRESHOLD = float(os.environ.get("CONFIDENCE_THRESHOLD", "0.7"))

TEAMS = {
    "billing": "Charges, refunds, invoices from us, payment methods, plan prices already paid",
    "technical": "Bugs, errors, outages, integrations, API problems, wrong calculations",
    "sales": "New plans, pricing quotes, demos, trials, partnerships, buying more",
    "account": "Logins, users, permissions, 2FA, workspace and data settings",
    "unknown": "A general question that is not about AnyCompany Invoicing at all",
}


def decide(message: str, timeout: float = 60) -> dict:
    """One request, two questions: the route (choice) and whether the message is in scope (yes/no)."""
    body = {
        "state": f"A customer sent this message to AnyCompany Invoicing support:\n\n{message}",
        "questions": {
            "route": {"type": "choice", "instructions": "Which team should handle this message?",
                      "criteria": TEAMS},
            "in_scope": {"type": "noul",
                         "instructions": "Is this message about the AnyCompany Invoicing product or account?"},
        },
    }
    return post_json(DECIDER_URL, body, timeout)


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


class Route(BaseModel):
    team: Literal["billing", "technical", "sales", "account", "unknown"] = Field(
        description="The team that should handle the message")
    reason: str = Field(description="One short sentence explaining the choice")


_model = None


def escalate(message: str) -> Route:
    """Ask a Strands agent on Amazon Bedrock for the team. A new agent per message keeps each one on its own
    (and safe to call from several requests at once); the Bedrock model client is created once."""
    global _model
    from strands import Agent
    from strands.models import BedrockModel

    if _model is None:
        _model = BedrockModel(model_id=ESCALATION_MODEL_ID)
    teams = "\n".join(f"- {k}: {v}" for k, v in TEAMS.items())
    agent = Agent(
        model=_model,
        system_prompt=f"You route customer support messages for AnyCompany Invoicing to exactly one team:\n{teams}",
        callback_handler=None,
    )
    return agent(f"Route this customer message:\n\n{message}", structured_output_model=Route).structured_output


def triage(message: str) -> dict:
    t = time.perf_counter()
    out = decide(message)
    route = out["answers"]["route"]
    result = {
        "team": route["choice"],
        "confidence": round(route["confidence"], 3),
        "in_scope": round(out["answers"]["in_scope"]["noul"], 3),
        "decided_by": "decision-model",
        "threshold": THRESHOLD,
    }
    if route["confidence"] < THRESHOLD:
        r = escalate(message)
        result.update(team=r.team, reason=r.reason, decided_by=f"bedrock:{ESCALATION_MODEL_ID}",
                      decision_model_choice=route["choice"])
    result["ms"] = round((time.perf_counter() - t) * 1000)
    return result


if __name__ == "__main__":
    import uvicorn
    from fastapi import FastAPI

    app = FastAPI()

    @app.get("/ping")
    def ping():
        return {"status": "Healthy"}

    class Ticket(BaseModel):
        message: str

    @app.post("/triage")
    def triage_endpoint(ticket: Ticket):
        return triage(ticket.message)

    # Loopback unless told otherwise; the Deployment sets BIND_HOST=0.0.0.0 inside the pod, behind a
    # ClusterIP Service.
    uvicorn.run(app, host=os.environ.get("BIND_HOST", "127.0.0.1"), port=int(os.environ.get("PORT", "8080")))
