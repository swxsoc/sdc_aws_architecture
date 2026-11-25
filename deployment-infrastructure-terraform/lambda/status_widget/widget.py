"""Render the SWxSOC pipeline status page as a CloudWatch custom widget.

A CloudWatch dashboard invokes this function with the widget's parameters
(``environment``: ``prod`` or ``dev``) and a ``widgetContext`` and renders the
HTML it returns. The page is modelled on Apple's system-status page: one group
per mission, one row per pipeline stage, and a list of recent events.

Everything is derived from the alarms the pipeline root creates for each
workspace (``pipeline-infrastructure-terraform/pipeline_health.tf``):

* every composite alarm ``<env><mission-slug>-pipeline-unhealthy`` identifies a
  workspace;
* the other ``<env><mission-slug>-pipeline-*`` alarms are mapped to a stage by
  their suffix, each with the severity its ALARM state means (an *issue*: errors
  while data still flows; an *outage*: data is not getting through);
* ``DescribeAlarmHistory`` provides the recent events.

The function needs only ``cloudwatch:DescribeAlarms`` and
``cloudwatch:DescribeAlarmHistory``. It never raises to the dashboard: an AWS
error renders as an error panel so the widget still explains itself.
"""

from __future__ import annotations

import datetime as dt
import html
import json
import logging
import os
import re
from dataclasses import dataclass, field
from urllib.parse import quote

log = logging.getLogger("status_widget")
log.setLevel(logging.INFO)

UNHEALTHY_SUFFIX = "-pipeline-unhealthy"
DEV_PREFIX = "dev-"

ENVIRONMENTS = {"prod": "Production", "dev": "Development"}

# Severity ordering, worst last. "off" is a stage with no alarms at all.
SEVERITY_RANK = {"off": -1, "available": 0, "nodata": 1, "issue": 2, "outage": 3}

STAGES: tuple[tuple[str, str], ...] = (
    ("landing", "Landing"),
    ("sorting", "Sorting"),
    ("notification", "Notification"),
    ("processing", "Processing"),
    ("artifacts", "Artifacts"),
    ("concating", "Concatenation"),
    ("reconciliation", "Reconciliation"),
)

LAMBDA_ALARMS = "(errors|throttles|duration|log-errors)"

# (pattern on the part after "<prefix>-pipeline-", stage, severity of ALARM).
# Order matters: specific names come before the per-instrument patterns.
CLASSIFIERS: tuple[tuple[re.Pattern[str], str, str], ...] = (
    (re.compile(r"^unsorted-incoming-objects$"), "landing", "outage"),
    (re.compile(rf"^sorting-{LAMBDA_ALARMS}$"), "sorting", "issue"),
    (re.compile(rf"^processing-{LAMBDA_ALARMS}$"), "processing", "issue"),
    (re.compile(r"^missing-metatracker-rows$"), "processing", "outage"),
    (re.compile(rf"^artifacts-{LAMBDA_ALARMS}$"), "artifacts", "issue"),
    (re.compile(r"^missing-timestream-records$"), "artifacts", "outage"),
    (re.compile(rf"^concating-{LAMBDA_ALARMS}$"), "concating", "issue"),
    (
        re.compile(r"^reconciliation-(not-running|errors|check-errors)$"),
        "reconciliation",
        "issue",
    ),
    (re.compile(r"^.+-topic-delivery-failures$"), "notification", "outage"),
    (re.compile(r"^.+-queue-age$"), "notification", "outage"),
)

MISSION_NAMES = {
    "padre": "PADRE",
    "hermes": "HERMES",
    "impax": "iMPAX",
    "gdctb": "GDC-Trailblazer",
    "swxsoc-pipeline": "SWxSOC Pipeline",
    "demo": "Demo",
}

STATUS_LABELS = {
    "available": "Available",
    "issue": "Issue",
    "outage": "Outage",
    "nodata": "No data",
    "off": "Not enabled",
}

DESCRIBE_MARKDOWN = """## SWxSOC pipeline status

Renders the pipeline status of every mission workspace in one environment,
derived from the `<env><mission>-pipeline-*` CloudWatch alarms.

### Widget parameters

``` yaml
environment: prod
```

`environment` is `prod` or `dev`.
"""


# -- data model -------------------------------------------------------------


@dataclass(frozen=True)
class Workspace:
    environment: str  # "prod" or "dev"
    slug: str  # mission slug, e.g. "padre" or "swxsoc-pipeline"

    @property
    def prefix(self) -> str:
        env = DEV_PREFIX if self.environment == "dev" else ""
        return f"{env}{self.slug}-pipeline-"

    @property
    def dashboard_name(self) -> str:
        return self.prefix[:-1]

    @property
    def name(self) -> str:
        if self.slug in MISSION_NAMES:
            return MISSION_NAMES[self.slug]
        return self.slug.replace("-", " ").title()


@dataclass
class Alarm:
    name: str
    state: str  # OK, ALARM or INSUFFICIENT_DATA
    reason: str = ""
    updated: dt.datetime | None = None
    stage: str | None = None
    severity: str = "issue"  # what ALARM means for this alarm

    @property
    def label(self) -> str:
        """The alarm name without the workspace prefix."""
        return self.name.split("-pipeline-", 1)[-1]


@dataclass
class Stage:
    key: str
    title: str
    status: str
    alarms: list[Alarm] = field(default_factory=list)
    since: dt.datetime | None = None


@dataclass
class Mission:
    workspace: Workspace
    stages: list[Stage]
    status: str


@dataclass
class Event:
    alarm: Alarm
    workspace: Workspace
    start: dt.datetime
    end: dt.datetime | None = None

    @property
    def ongoing(self) -> bool:
        return self.end is None


@dataclass
class Snapshot:
    environment: str
    missions: list[Mission]
    events: list[Event]
    generated: dt.datetime


# -- pure functions ---------------------------------------------------------


def discover_workspaces(alarm_names: list[str]) -> list[Workspace]:
    """Return one workspace per ``*-pipeline-unhealthy`` composite alarm."""
    found: set[Workspace] = set()
    for name in alarm_names:
        if not name.endswith(UNHEALTHY_SUFFIX):
            continue
        base = name[: -len(UNHEALTHY_SUFFIX)]
        environment, slug = "prod", base
        if base.startswith(DEV_PREFIX):
            environment, slug = "dev", base[len(DEV_PREFIX) :]
        if slug:
            found.add(Workspace(environment, slug))
    return sorted(found, key=lambda w: (w.environment, w.name.lower()))


def classify(alarm_name: str, workspace: Workspace) -> tuple[str, str] | None:
    """Map an alarm of ``workspace`` to ``(stage, severity)``; None if unknown."""
    if not alarm_name.startswith(workspace.prefix):
        return None
    suffix = alarm_name[len(workspace.prefix) :]
    for pattern, stage, severity in CLASSIFIERS:
        if pattern.match(suffix):
            return stage, severity
    return None


def worst(statuses: list[str]) -> str:
    return max(statuses, key=lambda s: SEVERITY_RANK[s], default="off")


def stage_status(alarms: list[Alarm]) -> str:
    """Worst alarm state of a stage, or ``off`` when it has no alarms."""
    if not alarms:
        return "off"
    alarming = [a for a in alarms if a.state == "ALARM"]
    if alarming:
        return worst([a.severity for a in alarming])
    if all(a.state == "INSUFFICIENT_DATA" for a in alarms):
        return "nodata"
    return "available"


def alarming_since(alarms: list[Alarm]) -> dt.datetime | None:
    """Earliest state change among the alarms currently in ALARM."""
    moments = [a.updated for a in alarms if a.state == "ALARM" and a.updated]
    return min(moments) if moments else None


def build_missions(workspaces: list[Workspace], alarms: list[Alarm]) -> list[Mission]:
    """Group alarms per workspace and stage and compute every status."""
    missions = []
    for workspace in workspaces:
        by_stage: dict[str, list[Alarm]] = {key: [] for key, _ in STAGES}
        for alarm in alarms:
            classified = classify(alarm.name, workspace)
            if classified is None:
                continue
            alarm.stage, alarm.severity = classified
            by_stage[alarm.stage].append(alarm)
        stages = []
        for key, title in STAGES:
            stage_alarms = by_stage[key]
            status = stage_status(stage_alarms)
            stages.append(
                Stage(key, title, status, stage_alarms, alarming_since(stage_alarms))
            )
        live = [s.status for s in stages if s.status != "off"]
        missions.append(Mission(workspace, stages, worst(live) if live else "nodata"))
    return missions


def summarize(missions: list[Mission]) -> dict[str, int]:
    counts = {"available": 0, "issue": 0, "outage": 0, "nodata": 0}
    for mission in missions:
        for stage in mission.stages:
            if stage.status in counts:
                counts[stage.status] += 1
    return counts


def pair_history(
    items: list[dict],
    alarms: dict[str, Alarm],
    workspaces: list[Workspace],
    now: dt.datetime,
) -> list[Event]:
    """Pair ALARM/OK transitions from alarm history into events.

    ``items`` are ``DescribeAlarmHistory`` records (``AlarmName``,
    ``Timestamp``, ``HistoryData`` JSON). Only alarms in ``alarms`` (the
    classified, non-composite alarms) count. A transition to OK with no
    preceding ALARM is ignored. An alarm that is in ALARM now but has no open
    event in the window gets an ongoing event from its own state timestamp.
    """
    owner: dict[str, Workspace] = {}
    for name in alarms:
        for workspace in workspaces:
            if name.startswith(workspace.prefix):
                owner[name] = workspace
                break

    events: list[Event] = []
    open_events: dict[str, Event] = {}
    ordered = sorted(items, key=lambda item: item["Timestamp"])
    for item in ordered:
        name = item.get("AlarmName", "")
        if name not in alarms or name not in owner:
            continue
        try:
            data = json.loads(item.get("HistoryData") or "{}")
            new_state = data["newState"]["stateValue"]
        except (ValueError, KeyError, TypeError):
            continue
        when = item["Timestamp"]
        if new_state == "ALARM":
            if name not in open_events:
                open_events[name] = Event(alarms[name], owner[name], when)
        elif new_state == "OK" and name in open_events:
            event = open_events.pop(name)
            event.end = when
            events.append(event)
        # INSUFFICIENT_DATA neither opens nor closes an event.

    for name, alarm in alarms.items():
        if alarm.state == "ALARM" and name not in open_events and name in owner:
            open_events[name] = Event(alarm, owner[name], alarm.updated or now)
    events.extend(open_events.values())
    events.sort(key=lambda e: (not e.ongoing, -e.start.timestamp()))
    return events


# -- AWS access ---------------------------------------------------------------


@dataclass(frozen=True)
class Settings:
    region: str
    console_region: str
    history_days: int

    @classmethod
    def from_environment(cls) -> Settings:
        region = os.environ.get("AWS_REGION", "us-east-1")
        return cls(
            region=region,
            console_region=os.environ.get("CONSOLE_REGION", region),
            history_days=int(os.environ.get("HISTORY_DAYS", "14")),
        )


def _timestamp(value) -> dt.datetime | None:
    if isinstance(value, dt.datetime):
        return value if value.tzinfo else value.replace(tzinfo=dt.UTC)
    return None


def fetch_alarms(client) -> list[Alarm]:
    """Every metric and composite alarm in the account/region."""
    alarms: list[Alarm] = []
    paginator = client.get_paginator("describe_alarms")
    for page in paginator.paginate(AlarmTypes=["CompositeAlarm", "MetricAlarm"]):
        for record in page.get("MetricAlarms", []) + page.get("CompositeAlarms", []):
            alarms.append(
                Alarm(
                    name=record["AlarmName"],
                    state=record.get("StateValue", "INSUFFICIENT_DATA"),
                    reason=record.get("StateReason", ""),
                    # StateUpdatedTimestamp also moves on evaluation updates
                    # without a state change; the transition time is the
                    # incident start.
                    updated=_timestamp(
                        record.get("StateTransitionedTimestamp")
                        or record.get("StateUpdatedTimestamp")
                    ),
                )
            )
    return alarms


def fetch_history(client, start: dt.datetime, end: dt.datetime) -> list[dict]:
    items: list[dict] = []
    paginator = client.get_paginator("describe_alarm_history")
    for page in paginator.paginate(
        HistoryItemType="StateUpdate",
        AlarmTypes=["MetricAlarm"],
        StartDate=start,
        EndDate=end,
        ScanBy="TimestampDescending",
    ):
        items.extend(page.get("AlarmHistoryItems", []))
    return items


def collect(client, environment: str, settings: Settings, now: dt.datetime) -> Snapshot:
    """Read CloudWatch and build the snapshot for one environment."""
    all_alarms = fetch_alarms(client)
    workspaces = [
        w
        for w in discover_workspaces([a.name for a in all_alarms])
        if w.environment == environment
    ]
    missions = build_missions(workspaces, all_alarms)
    classified = {
        alarm.name: alarm
        for mission in missions
        for stage in mission.stages
        for alarm in stage.alarms
    }
    history: list[dict] = []
    if classified:
        history = fetch_history(
            client, now - dt.timedelta(days=settings.history_days), now
        )
    events = pair_history(history, classified, workspaces, now)
    return Snapshot(environment, missions, events[:20], now)


# -- rendering ----------------------------------------------------------------

PALETTES = {
    "dark": {
        "bg": "#000000",
        "fg": "#f5f5f7",
        "muted": "#98989d",
        "rule": "#2a2a2e",
        "rule_strong": "#424245",
        "link": "#2997ff",
        "available": "#30d158",
        "issue": "#ffd60a",
        "outage": "#ff453a",
        "nodata": "#98989d",
        "off": "#636366",
        "button": "#2997ff",
        "button_fg": "#000000",
    },
    "light": {
        "bg": "#ffffff",
        "fg": "#1d1d1f",
        "muted": "#6e6e73",
        "rule": "#e8e8ed",
        "rule_strong": "#d2d2d7",
        "link": "#0066cc",
        "available": "#1f9d49",
        "issue": "#b8860b",
        "outage": "#d70015",
        "nodata": "#6e6e73",
        "off": "#86868b",
        "button": "#0071e3",
        "button_fg": "#ffffff",
    },
}


def _glyph(status: str, palette: dict[str, str], size: int = 18) -> str:
    colour = palette.get(status, palette["nodata"])
    if status == "available":
        shape = f'<circle cx="9" cy="9" r="8" fill="{colour}"></circle>'
    elif status == "issue":
        shape = f'<path d="M9 1 17 9 9 17 1 9Z" fill="{colour}"></path>'
    elif status == "outage":
        shape = f'<path d="M9 1.5 17 16H1Z" fill="{colour}"></path>'
    elif status == "off":
        shape = (
            f'<circle cx="9" cy="9" r="7" fill="none" stroke="{colour}" '
            'stroke-width="2"></circle>'
        )
    else:
        shape = (
            f'<circle cx="9" cy="9" r="7" fill="none" stroke="{colour}" '
            'stroke-width="2" stroke-dasharray="3 3"></circle>'
        )
    return (
        f'<svg width="{size}" height="{size}" viewBox="0 0 18 18" '
        f'aria-hidden="true" style="flex:0 0 auto">{shape}</svg>'
    )


def _css(p: dict[str, str]) -> str:
    font = '-apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif'
    return f"""
.sw {{background:{p["bg"]};color:{p["fg"]};font-family:{font};-webkit-font-smoothing:antialiased;padding:8px 16px 24px;box-sizing:border-box;line-height:1.35}}
.sw * {{box-sizing:border-box}}
.sw .wrap {{max-width:880px;margin:0 auto}}
.sw h1 {{margin:24px 0 20px;font-size:32px;font-weight:700;letter-spacing:-0.3px;text-align:center;color:{p["fg"]}}}
.sw a {{color:{p["link"]};text-decoration:none}}
.sw a:hover {{text-decoration:underline}}
.sw .row {{display:flex;align-items:center;gap:12px;min-height:40px;padding:6px 0;border-bottom:1px solid {p["rule"]};font-size:14px}}
.sw .row:last-child {{border-bottom:0}}
.sw .sum {{font-size:15px;font-weight:500;padding:10px 0;border-bottom:1px solid {p["rule"]}}}
.sw .sum.first {{border-top:1px solid {p["rule_strong"]}}}
.sw .sum.last {{border-bottom:1px solid {p["rule_strong"]}}}
.sw .name {{font-weight:500}}
.sw .dot {{color:{p["muted"]};padding:0 2px}}
.sw .st-available {{color:{p["available"]};font-weight:600}}
.sw .st-issue {{color:{p["issue"]};font-weight:600}}
.sw .st-outage {{color:{p["outage"]};font-weight:600}}
.sw .st-nodata {{color:{p["nodata"]};font-weight:600}}
.sw .st-off {{color:{p["off"]};font-weight:600}}
.sw .detail {{margin-left:auto;color:{p["muted"]};font-size:12px;text-align:right}}
.sw details.group {{border-top:1px solid {p["rule_strong"]};margin-top:22px}}
.sw details.group:last-of-type {{border-bottom:1px solid {p["rule_strong"]}}}
.sw summary.ghead {{display:flex;align-items:center;gap:14px;min-height:52px;padding:6px 0;cursor:pointer;list-style:none}}
.sw summary.ghead::-webkit-details-marker {{display:none}}
.sw .gtitle {{font-size:18px;font-weight:600;flex:1 1 auto;min-width:0;color:{p["fg"]}}}
.sw .gsub {{color:{p["muted"]};font-size:13px;font-weight:400}}
.sw .plus {{width:26px;height:26px;border-radius:50%;background:{p["button"]};color:{p["button_fg"]};display:flex;align-items:center;justify-content:center;flex:0 0 auto;font-size:18px;line-height:1}}
.sw .plus::before {{content:"+"}}
.sw details[open] .plus::before {{content:"\\00d7"}}
.sw .gbody {{padding:0 0 10px 32px}}
.sw .muted {{color:{p["muted"]};font-size:12px}}
.sw .empty {{border:1px dashed {p["rule_strong"]};border-radius:10px;padding:20px;margin-top:22px;color:{p["muted"]};font-size:14px;text-align:center}}
.sw h2 {{margin:36px 0 4px;font-size:20px;font-weight:600;color:{p["fg"]}}}
.sw .ev {{display:flex;gap:16px;align-items:flex-start;padding:12px 0;border-bottom:1px solid {p["rule"]};font-size:14px}}
.sw .ev:last-child {{border-bottom:0}}
.sw .evtime {{color:{p["muted"]};font-size:12px;margin-top:2px;flex:0 0 230px}}
.sw .evwhat {{flex:1 1 auto;min-width:0}}
.sw .evwho {{color:{p["muted"]};font-size:12px;margin-top:2px;overflow-wrap:anywhere}}
.sw .legend {{margin-top:32px;padding-top:16px;border-top:1px solid {p["rule_strong"]};display:flex;flex-wrap:wrap;gap:10px 28px;font-size:12px;color:{p["muted"]}}}
.sw .legend div {{display:flex;align-items:center;gap:8px}}
.sw .err {{border:1px solid {p["outage"]};border-radius:10px;padding:16px;margin-top:22px;font-size:14px;display:flex;gap:12px;align-items:center}}
@media (max-width:640px) {{.sw .detail {{display:none}} .sw .evtime {{flex-basis:120px}}}}
"""


def _console_alarm_url(region: str, alarm_name: str) -> str:
    return (
        f"https://{region}.console.aws.amazon.com/cloudwatch/home?region={region}"
        f"#alarmsV2:alarm/{quote(alarm_name, safe='')}"
    )


def _console_dashboard_url(region: str, dashboard_name: str) -> str:
    return (
        f"https://{region}.console.aws.amazon.com/cloudwatch/home?region={region}"
        f"#dashboards:name={quote(dashboard_name, safe='')}"
    )


def _short_time(moment: dt.datetime | None) -> str:
    if moment is None:
        return ""
    return moment.astimezone(dt.UTC).strftime("%b %d, %H:%M UTC")


def _status_span(status: str) -> str:
    return f'<span class="st-{status}">{STATUS_LABELS[status]}</span>'


def _plural(count: int, noun: str) -> str:
    return f"{count} {noun}{'' if count == 1 else 's'}"


def _stage_names(missions: list[Mission], status: str) -> str:
    return ", ".join(
        f"{m.workspace.name} {s.title.lower()}"
        for m in missions
        for s in m.stages
        if s.status == status
    )


def render_summary(snapshot: Snapshot, palette: dict[str, str]) -> str:
    counts = summarize(snapshot.missions)
    missions = snapshot.missions
    lines = [
        (
            "available",
            f"{_plural(counts['available'], 'stage')} available",
            f"across {_plural(len(missions), 'mission')}",
        )
    ]
    if counts["outage"]:
        lines.append(
            (
                "outage",
                _plural(counts["outage"], "current outage"),
                _stage_names(missions, "outage"),
            )
        )
    if counts["issue"]:
        lines.append(
            (
                "issue",
                _plural(counts["issue"], "current issue"),
                _stage_names(missions, "issue"),
            )
        )
    if counts["nodata"]:
        lines.append(
            (
                "nodata",
                f"{_plural(counts['nodata'], 'stage')} reporting no data",
                _stage_names(missions, "nodata"),
            )
        )
    out = []
    for index, (status, text, detail) in enumerate(lines):
        classes = ["row", "sum"]
        if index == 0:
            classes.append("first")
        if index == len(lines) - 1:
            classes.append("last")
        out.append(
            f'<div class="{" ".join(classes)}">{_glyph(status, palette)}'
            f"<span>{html.escape(text)}</span>"
            f'<span class="detail">{html.escape(detail)}</span></div>'
        )
    return "".join(out)


def _stage_detail(stage: Stage, region: str) -> str:
    """Right-hand note for a stage row, as HTML."""
    if stage.status in ("issue", "outage"):
        links = ", ".join(
            f'<a href="{_console_alarm_url(region, a.name)}" target="_blank" '
            f'rel="noopener" title="{html.escape(a.reason or a.name)}">'
            f"{html.escape(a.label)}</a>"
            for a in stage.alarms
            if a.state == "ALARM"
        )
        since = _short_time(stage.since)
        return f"{links} · since {html.escape(since)}" if since else links
    if stage.status == "nodata":
        return "Alarms have nothing to evaluate yet"
    return ""


def render_mission(mission: Mission, palette: dict[str, str], region: str) -> str:
    live = [s for s in mission.stages if s.status != "off"]
    good = [s for s in live if s.status == "available"]
    if mission.status == "available":
        summary = "All stages available"
    elif not live:
        summary = "No stages reporting"
    else:
        summary = f"{len(good)} of {len(live)} stages available"
    is_open = mission.status != "available"
    rows = [
        f'<div class="row"><span class="name">{html.escape(stage.title)}</span>'
        f'<span class="dot">·</span>{_status_span(stage.status)}'
        f'<span class="detail">{_stage_detail(stage, region)}</span></div>'
        for stage in mission.stages
    ]
    dashboard = _console_dashboard_url(region, mission.workspace.dashboard_name)
    return (
        f'<details class="group"{" open" if is_open else ""}>'
        f'<summary class="ghead">{_glyph(mission.status, palette)}'
        f'<span class="gtitle"><a href="{dashboard}" target="_blank" rel="noopener">'
        f"{html.escape(mission.workspace.name)}</a> "
        f'<span class="gsub">· {html.escape(summary)}</span></span>'
        f'<span class="plus" aria-hidden="true"></span></summary>'
        f'<div class="gbody">{"".join(rows)}</div></details>'
    )


def _event_time(event: Event) -> str:
    if event.ongoing:
        return f"Ongoing · since {_short_time(event.start)}"
    start = event.start.astimezone(dt.UTC)
    end = event.end.astimezone(dt.UTC)
    if start.date() == end.date():
        return (
            f"Resolved · {start.strftime('%b %d, %H:%M')} – {end.strftime('%H:%M UTC')}"
        )
    return f"Resolved · {_short_time(start)} – {_short_time(end)}"


def render_events(snapshot: Snapshot, region: str) -> str:
    if not snapshot.events:
        return '<p class="muted">No alarm state changes in the last two weeks.</p>'
    stage_titles = dict(STAGES)
    out = []
    for event in snapshot.events:
        if not event.ongoing:
            status, label = "available", "Resolved"
        elif event.alarm.state == "ALARM":
            status, label = event.alarm.severity, STATUS_LABELS[event.alarm.severity]
        else:
            # Open incident whose alarm has since gone to INSUFFICIENT_DATA:
            # unresolved, but not a confirmed issue or outage right now.
            status, label = "nodata", "No data"
        stage = stage_titles.get(event.alarm.stage or "", "Pipeline")
        out.append(
            f'<div class="ev"><div class="evtime">{html.escape(_event_time(event))}</div>'
            f'<div class="evwhat"><div><span class="st-{status}">{label}</span> · '
            f"{html.escape(event.workspace.name)} · {html.escape(stage)} · "
            f'<a href="{_console_alarm_url(region, event.alarm.name)}" target="_blank" '
            f'rel="noopener">{html.escape(event.alarm.label)}</a></div>'
            f'<div class="evwho">{html.escape(event.alarm.reason)}</div></div></div>'
        )
    return "".join(out)


def render_legend(palette: dict[str, str]) -> str:
    items = (
        ("available", "Available: every alarm for the stage is OK"),
        ("issue", "Issue: errors or slowness, data still flowing"),
        ("outage", "Outage: data is not making it through the stage"),
        ("nodata", "No data: the alarms have nothing to evaluate yet"),
        ("off", "Not enabled: the stage has no alarms in this workspace"),
    )
    body = "".join(
        f"<div>{_glyph(status, palette, 13)}{html.escape(text)}</div>"
        for status, text in items
    )
    return f'<div class="legend">{body}</div>'


def render(snapshot: Snapshot, theme: str, region: str) -> str:
    """The widget HTML for one environment."""
    palette = PALETTES["light" if theme == "light" else "dark"]
    env_name = ENVIRONMENTS.get(snapshot.environment, snapshot.environment)
    generated = snapshot.generated.astimezone(dt.UTC).strftime("%B %d, %Y at %H:%M UTC")
    parts = [
        '<div class="cwdb-no-default-styles"></div>',
        f"<style>{_css(palette)}</style>",
        '<div class="sw"><div class="wrap">',
        f"<h1>{html.escape(env_name)} Pipeline Status</h1>",
    ]
    if snapshot.missions:
        parts.append(render_summary(snapshot, palette))
        parts.append(
            f'<p class="muted" style="margin:12px 0 0">Last updated {generated}. '
            "Derived from CloudWatch alarm state; refreshes with the dashboard.</p>"
        )
        parts.extend(render_mission(m, palette, region) for m in snapshot.missions)
        parts.append("<h2>Recent events</h2>")
        parts.append(
            '<p class="muted" style="margin:0 0 6px">Alarm state changes from '
            "the last 14 days, newest first.</p>"
        )
        parts.append(render_events(snapshot, region))
    else:
        parts.append(
            f'<div class="empty">No mission pipelines are reporting for {env_name} '
            "yet. A workspace appears here once its pipeline health alarms "
            "(<code>&lt;env&gt;&lt;mission&gt;-pipeline-*</code>) exist.</div>"
        )
        parts.append(
            f'<p class="muted" style="margin:12px 0 0">Checked {generated}.</p>'
        )
    parts.append(render_legend(palette))
    parts.append("</div></div>")
    return "".join(parts)


def render_error(message: str, theme: str) -> str:
    palette = PALETTES["light" if theme == "light" else "dark"]
    return (
        '<div class="cwdb-no-default-styles"></div>'
        f"<style>{_css(palette)}</style>"
        '<div class="sw"><div class="wrap"><h1>Pipeline Status</h1>'
        f'<div class="err">{_glyph("outage", palette)}<span>The status widget '
        f"could not read CloudWatch: {html.escape(message)}</span></div></div></div>"
    )


# -- entry point --------------------------------------------------------------


def cloudwatch_client(region: str):
    """The boto3 client; imported lazily so the pure functions need no boto3."""
    import boto3

    return boto3.client("cloudwatch", region_name=region)


def handler(event, context):
    """CloudWatch custom widget entry point; ``context`` is unused."""
    event = event or {}
    if event.get("describe"):
        return DESCRIBE_MARKDOWN
    theme = (event.get("widgetContext") or {}).get("theme", "dark")
    environment = str(event.get("environment", "prod")).lower()
    if environment not in ENVIRONMENTS:
        return render_error(
            f"unknown environment {environment!r}; use prod or dev", theme
        )
    settings = Settings.from_environment()
    # The dashboard must always get HTML back, so any failure becomes a panel.
    try:
        client = cloudwatch_client(settings.region)
        snapshot = collect(client, environment, settings, dt.datetime.now(dt.UTC))
    except Exception as error:
        log.exception("status widget failed")
        return render_error(f"{type(error).__name__}: {error}", theme)
    return render(snapshot, theme, settings.console_region)
