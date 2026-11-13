"""Post CloudWatch alarm notifications from the pipeline alert topic to Mattermost.

Subscribed to ``<env>-<mission>-pipeline-alerts``. Each SNS record carries a
CloudWatch alarm state change (metric or composite) as JSON; anything else is
posted verbatim so no notification is lost. The Mattermost server, channel and
token come from the same mission secret the sorting and artifacts Lambdas use,
injected as environment variables by Terraform.
"""

from __future__ import annotations

import json
import logging
import os
import urllib.request

log = logging.getLogger("notifier")
log.setLevel(logging.INFO)

STATE_ICONS = {"ALARM": ":rotating_light:", "OK": ":white_check_mark:"}


def format_message(sns_message: str, subject: str | None = None) -> str:
    """Render one SNS message as Mattermost markdown."""
    try:
        alarm = json.loads(sns_message)
    except ValueError:
        return subject + "\n" + sns_message if subject else sns_message
    if not isinstance(alarm, dict) or "AlarmName" not in alarm:
        return subject + "\n" + sns_message if subject else sns_message

    state = alarm.get("NewStateValue", "UNKNOWN")
    icon = STATE_ICONS.get(state, ":grey_question:")
    lines = [f"{icon} **{alarm['AlarmName']}** is **{state}**"]
    if alarm.get("AlarmDescription"):
        lines.append(alarm["AlarmDescription"])
    if alarm.get("NewStateReason"):
        lines.append(f"Reason: {alarm['NewStateReason']}")
    children = alarm.get("TriggeringChildren") or []
    names = [child.get("Arn", "").rsplit(":", 1)[-1] for child in children]
    if names:
        lines.append("Triggered by: " + ", ".join(name for name in names if name))
    if alarm.get("StateChangeTime"):
        lines.append(f"At: {alarm['StateChangeTime']}")
    return "\n".join(lines)


def post(url: str, token: str, channel_id: str, message: str) -> None:
    request = urllib.request.Request(
        f"{url.rstrip('/')}/api/v4/posts",
        data=json.dumps({"channel_id": channel_id, "message": message}).encode(),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        response.read()


def handler(event, context):
    """Lambda entry point; ``context`` is unused."""
    url = os.environ["MATTERMOST_URL"]
    token = os.environ["MATTERMOST_TOKEN"]
    channel_id = os.environ["MATTERMOST_CHANNEL_ID"]
    posted = 0
    for record in event.get("Records", []):
        sns = record.get("Sns", {})
        message = format_message(sns.get("Message", ""), sns.get("Subject"))
        post(url, token, channel_id, message)
        posted += 1
    log.info("posted %d notification(s) to Mattermost", posted)
    return {"posted": posted}
