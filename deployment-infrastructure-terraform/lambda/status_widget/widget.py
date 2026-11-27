"""Render the SWxSOC pipeline status page as a CloudWatch custom widget.

A CloudWatch dashboard invokes this function with the widget's parameters
(``environment``: ``prod`` or ``dev``) and a ``widgetContext`` and renders the
HTML it returns. The page is written for the whole team, not only for cloud
engineers: a one-sentence verdict first, one group per mission with the
problem named in its header, one row per pipeline step in plain words, and
for every firing alarm a plain-language headline with direct links to the log
lines, the alarm and the resource involved.

Everything is derived from the alarms the pipeline root creates for each
workspace (``pipeline-infrastructure-terraform/pipeline_health.tf``):

* every composite alarm ``<env><mission-slug>-pipeline-unhealthy`` identifies a
  workspace;
* the other ``<env><mission-slug>-pipeline-*`` alarms are mapped to a step and
  a severity by their suffix (an *issue*: errors while data still flows; an
  *outage*: data is not getting through), and to a headline, a log filter and
  a "what to do" note;
* ``DescribeAlarmHistory`` provides the recent events;
* one ``GetMetricData`` call per environment reads the latest health-check
  counts (``IncomingObjectsInWindow``, ``ReconciledObjects``, ...) from the
  ``SWxSOC/Pipeline/<env>-<mission-slug>`` namespaces for the "Last 24 h"
  line under each mission header. That line is decoration: when the metrics
  are absent or the call fails the page renders without it.

The function needs only ``cloudwatch:DescribeAlarms``,
``cloudwatch:DescribeAlarmHistory`` and ``cloudwatch:GetMetricData``. It never
raises to the dashboard: an AWS error renders as an error panel so the widget
still explains itself.
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

# Severity ordering, worst last. "off" is a step with no alarms at all.
SEVERITY_RANK = {"off": -1, "available": 0, "nodata": 1, "issue": 2, "outage": 3}


@dataclass(frozen=True)
class StageInfo:
    key: str
    title: str  # what the page shows
    technical: str  # the name engineers and the Terraform use
    description: str  # one line under the title


STAGES: tuple[StageInfo, ...] = (
    StageInfo(
        "landing",
        "Arrival",
        "Landing",
        "New files land in the mission's incoming bucket.",
    ),
    StageInfo(
        "sorting",
        "Sorting",
        "Sorting",
        "Each file is filed into its instrument bucket by name and date.",
    ),
    StageInfo(
        "notification",
        "Hand-off",
        "Notification",
        "Each filed file is announced to the processing step and the download queue.",
    ),
    StageInfo(
        "processing",
        "Processing",
        "Processing",
        "Science code runs on the file and the result is recorded in MetaTracker.",
    ),
    StageInfo(
        "artifacts",
        "Recording",
        "Artifacts",
        "Every file and product is written to the Timestream file log.",
    ),
    StageInfo(
        "concating",
        "Daily files",
        "Concatenation",
        "Files are combined into day-long files.",
    ),
    StageInfo(
        "reconciliation",
        "Health check",
        "Reconciliation",
        "Regular audit that every file in the buckets has its MetaTracker and "
        "Timestream records.",
    ),
)
STAGE_BY_KEY = {stage.key: stage for stage in STAGES}

LAMBDA_STAGES = "(?P<stage>sorting|processing|artifacts|concating)"

# Log filter patterns, in CloudWatch Logs filter syntax. The log-error ones are
# the metric-filter patterns pipeline_health.tf installs, so the link shows
# exactly the lines that raised the alarm.
CRASH_PATTERN = '?"Task timed out" ?"Runtime." ?"[ERROR]" ?"Traceback" ?"errorMessage"'
LOG_ERROR_PATTERNS = {
    "sorting": '?"Issue parsing file" ?"Error sorting file" ?"does not exist in bucket"',
    "processing": "?\"Error Processing Event\" ?\"'status': 'ERROR'\"",
    "artifacts": (
        '"\'status\': \'ERROR\'" -"comms client" -"Slack" -"slack" '
        '-"Mattermost" -"mattermost" -"message_ts"'
    ),
    "concating": '?"ERROR:" ?"Traceback"',
}


@dataclass(frozen=True)
class AlarmKind:
    """What one family of alarms means and where its evidence is."""

    pattern: re.Pattern[str]
    stage: str
    severity: str  # what ALARM means: "issue" or "outage"
    headline: str  # plain language; {stage}, {INSTRUMENT} and {h} are filled in
    what_to_do: str
    number: str  # how the latest datapoint reads: files | count | duration | age | none
    log_source: str  # self | stage | reconciliation | none
    log_filter: str  # "" = unfiltered; "{stage}" = that stage's log-error pattern
    log_label: str
    resource: str  # "" | topic | queue | incoming-bucket
    monitoring: bool = False  # add a Lambda monitoring link


ALARM_KINDS: tuple[AlarmKind, ...] = (
    AlarmKind(
        re.compile(r"^unsorted-incoming-objects$"),
        "landing",
        "outage",
        "Files arrived but were not sorted into instrument buckets",
        "Open the list of affected files; then the Sorting log says why each one "
        "was skipped. Rename or remove files the mission does not accept from the "
        "incoming bucket.",
        "files",
        "reconciliation",
        "affected_keys unsorted",
        "List of affected files",
        "incoming-bucket",
    ),
    AlarmKind(
        re.compile(rf"^{LAMBDA_STAGES}-log-errors$"),
        "{stage}",
        "issue",
        "{stage} failed on some files, data still flowing",
        "Open the {stage} log filtered to the error lines; each has the file name "
        "and the traceback. The next health check lists any file that was lost.",
        "count",
        "stage",
        "{stage}",
        "{stage} log (errors only)",
        "",
    ),
    AlarmKind(
        re.compile(rf"^{LAMBDA_STAGES}-errors$"),
        "{stage}",
        "issue",
        "{stage} crashed or timed out",
        "Open the {stage} log filtered to crash lines. Files announced while it "
        "was down may not have been handled; the next health check lists them.",
        "count",
        "self",
        CRASH_PATTERN,
        "{stage} log (crashes)",
        "",
    ),
    AlarmKind(
        re.compile(rf"^{LAMBDA_STAGES}-throttles$"),
        "{stage}",
        "issue",
        "AWS refused some {stage} runs (throttled)",
        "No log line exists for a throttled run; the monitoring tab shows the "
        "spike. The next health check reports any file that was skipped.",
        "count",
        "none",
        "",
        "",
        "",
        monitoring=True,
    ),
    AlarmKind(
        re.compile(rf"^{LAMBDA_STAGES}-duration$"),
        "{stage}",
        "issue",
        "A {stage} run is close to its time limit",
        "Open the {stage} log filtered to the REPORT lines to find the slow runs; "
        "a run that hits the limit is killed mid-file.",
        "duration",
        "self",
        '"REPORT RequestId"',
        "{stage} log (run times)",
        "",
    ),
    AlarmKind(
        re.compile(r"^missing-metatracker-rows$"),
        "processing",
        "outage",
        "Files were filed but have no MetaTracker record",
        "Open the list of affected files and the Processing log for the same "
        "window; reprocess the listed files. The next health check clears the "
        "alarm.",
        "files",
        "reconciliation",
        "affected_keys missing_metatracker",
        "List of affected files",
        "",
    ),
    AlarmKind(
        re.compile(r"^missing-timestream-records$"),
        "artifacts",
        "outage",
        "Files were filed but have no Timestream record",
        "Open the list of affected files, then the Recording log for the same window.",
        "files",
        "reconciliation",
        "affected_keys missing_timestream",
        "List of affected files",
        "",
    ),
    AlarmKind(
        re.compile(r"^reconciliation-check-errors$"),
        "reconciliation",
        "issue",
        "The health check could not reach S3, the database or Timestream",
        "Open the health-check log; the run summary's check_errors field names "
        "the system that failed. The other counts from that run cannot be "
        "trusted.",
        "count",
        "reconciliation",
        "check_errors",
        "Health-check log",
        "",
    ),
    AlarmKind(
        re.compile(r"^reconciliation-not-running$"),
        "reconciliation",
        "issue",
        "The health check has stopped running, so the pipeline is unwatched",
        "Data may still be flowing, but nothing is verifying it. Open the "
        "health-check log (an empty view is itself the evidence), then the "
        "Lambda's monitoring tab.",
        "none",
        "reconciliation",
        "",
        "Health-check log",
        "",
        monitoring=True,
    ),
    AlarmKind(
        re.compile(r"^reconciliation-errors$"),
        "reconciliation",
        "issue",
        "The health-check program itself crashed",
        "Open the health-check log filtered to crash lines.",
        "count",
        "self",
        CRASH_PATTERN,
        "Health-check log (crashes)",
        "",
    ),
    AlarmKind(
        re.compile(r"^(?P<instrument>.+)-topic-delivery-failures$"),
        "notification",
        "outage",
        "New {INSTRUMENT} files are not reaching processing",
        "The announcement of a new file could not be delivered to the processing "
        "or recording step. Check the topic's subscriptions, then the Processing "
        "log for the same window. Dropped files show up at the next health check.",
        "count",
        "stage:processing",
        "{processing}",
        "Processing log (errors only)",
        "topic",
    ),
    AlarmKind(
        re.compile(r"^(?P<instrument>.+)-queue-age$"),
        "notification",
        "issue",
        "The {INSTRUMENT} download queue is not being emptied",
        "SWxSOC processing is not affected: the external system that reads this "
        "queue has stopped picking up files. Contact its owner; nothing on the "
        "SWxSOC side needs fixing.",
        "age",
        "none",
        "",
        "",
        "queue",
    ),
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
    "available": "OK",
    "issue": "Issue",
    "outage": "Outage",
    "nodata": "Not checked yet",
    "off": "Not used",
}

STATUS_MEANINGS = {
    "available": "OK: working normally",
    "issue": "Issue: errors on some files, data still getting through",
    "outage": "Outage: data is not getting through this step",
    "nodata": "Not checked yet: the health check has not run for this mission",
    "off": "Not used: this mission does not have this step",
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
    def namespace(self) -> str:
        """Where the workspace's health check publishes its metrics."""
        return f"SWxSOC/Pipeline/{self.environment}-{self.slug}"

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
    description: str = ""
    threshold: float | None = None
    period: int | None = None
    dimensions: dict[str, str] = field(default_factory=dict)
    arn: str = ""
    stage: str | None = None
    severity: str = "issue"  # what ALARM means for this alarm
    kind: AlarmKind | None = None
    instrument: str = ""

    @property
    def label(self) -> str:
        """The alarm name without the workspace prefix."""
        return self.name.split("-pipeline-", 1)[-1]

    @property
    def account(self) -> str:
        parts = self.arn.split(":")
        return parts[4] if len(parts) > 5 else ""


@dataclass
class Stage:
    info: StageInfo
    status: str
    alarms: list[Alarm] = field(default_factory=list)
    since: dt.datetime | None = None

    @property
    def key(self) -> str:
        return self.info.key

    @property
    def title(self) -> str:
        return self.info.title

    @property
    def firing(self) -> list[Alarm]:
        """Alarms in ALARM, worst severity first, oldest first within it."""
        return sorted(
            (a for a in self.alarms if a.state == "ALARM"),
            key=lambda a: (
                -SEVERITY_RANK[a.severity],
                a.updated or dt.datetime.max.replace(tzinfo=dt.UTC),
            ),
        )


# Health-check metrics behind the "Last 24 h" line: Counts field -> MetricName.
COUNT_METRICS = {
    "arrived": "IncomingObjectsInWindow",
    "checked": "ReconciledObjects",
    "missing_metatracker": "MissingMetaTrackerRows",
    "missing_timestream": "MissingTimestreamRecords",
    "failed": "FailedProcessingFiles",
}
DEFAULT_RECONCILIATION_PERIOD = 3600
METRIC_DATA_BATCH = 500  # GetMetricData accepts at most 500 queries per call
QUIET_DAY_NOTE = (
    "No alarm: a quiet day and a stopped uploader look the same to the pipeline"
)


@dataclass
class Counts:
    """What the latest health-check run counted; None when it was not published."""

    arrived: int | None = None
    checked: int | None = None
    missing_metatracker: int | None = None
    missing_timestream: int | None = None
    failed: int | None = None

    @property
    def missing(self) -> int | None:
        parts = [
            v
            for v in (self.missing_metatracker, self.missing_timestream)
            if v is not None
        ]
        return sum(parts) if parts else None

    @property
    def available(self) -> bool:
        return self.arrived is not None


@dataclass
class Mission:
    workspace: Workspace
    stages: list[Stage]
    status: str
    functions: dict[str, str] = field(default_factory=dict)  # stage key -> FunctionName
    counts: Counts | None = None

    @property
    def firing_stages(self) -> list[Stage]:
        return sorted(
            (s for s in self.stages if s.status in ("issue", "outage")),
            key=lambda s: (
                -SEVERITY_RANK[s.status],
                s.since or dt.datetime.max.replace(tzinfo=dt.UTC),
            ),
        )

    @property
    def since(self) -> dt.datetime | None:
        moments = [s.since for s in self.firing_stages if s.since]
        return min(moments) if moments else None


@dataclass
class Event:
    alarm: Alarm
    workspace: Workspace
    start: dt.datetime
    end: dt.datetime | None = None
    reason: str = ""  # the StateReason recorded when the alarm fired
    mission: Mission | None = None

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
    match = match_kind(alarm_name, workspace)
    if match is None:
        return None
    kind, groups = match
    return kind.stage.format(stage=groups.get("stage", "")), kind.severity


def match_kind(
    alarm_name: str, workspace: Workspace
) -> tuple[AlarmKind, dict[str, str]] | None:
    if not alarm_name.startswith(workspace.prefix):
        return None
    suffix = alarm_name[len(workspace.prefix) :]
    for kind in ALARM_KINDS:
        found = kind.pattern.match(suffix)
        if found:
            return kind, {k: v for k, v in found.groupdict().items() if v}
    return None


def worst(statuses: list[str]) -> str:
    return max(statuses, key=lambda s: SEVERITY_RANK[s], default="off")


def stage_status(alarms: list[Alarm]) -> str:
    """Worst alarm state of a step, or ``off`` when it has no alarms."""
    if not alarms:
        return "off"
    alarming = [a for a in alarms if a.state == "ALARM"]
    if alarming:
        return worst([a.severity for a in alarming])
    if all(a.state == "INSUFFICIENT_DATA" for a in alarms):
        return "nodata"
    return "available"


def mission_status(stages: list[Stage]) -> str:
    """Worst step; steps that have not evaluated yet do not count against a
    mission unless nothing has evaluated at all."""
    evaluated = [
        s.status for s in stages if s.status in ("available", "issue", "outage")
    ]
    if evaluated:
        return worst(evaluated)
    if any(s.status == "nodata" for s in stages):
        return "nodata"
    return "off"


def alarming_since(alarms: list[Alarm]) -> dt.datetime | None:
    """Earliest state change among the alarms currently in ALARM."""
    moments = [a.updated for a in alarms if a.state == "ALARM" and a.updated]
    return min(moments) if moments else None


def build_missions(workspaces: list[Workspace], alarms: list[Alarm]) -> list[Mission]:
    """Group alarms per workspace and step and compute every status."""
    missions = []
    for workspace in workspaces:
        by_stage: dict[str, list[Alarm]] = {stage.key: [] for stage in STAGES}
        functions: dict[str, str] = {}
        for alarm in alarms:
            match = match_kind(alarm.name, workspace)
            if match is None:
                continue
            kind, groups = match
            alarm.kind = kind
            alarm.stage = kind.stage.format(stage=groups.get("stage", ""))
            alarm.severity = kind.severity
            alarm.instrument = groups.get("instrument", "")
            by_stage[alarm.stage].append(alarm)
            function = alarm.dimensions.get("FunctionName")
            if function:
                functions.setdefault(alarm.stage, function)
        stages = []
        for info in STAGES:
            stage_alarms = by_stage[info.key]
            stages.append(
                Stage(
                    info,
                    stage_status(stage_alarms),
                    stage_alarms,
                    alarming_since(stage_alarms),
                )
            )
        missions.append(Mission(workspace, stages, mission_status(stages), functions))
    missions.sort(key=lambda m: (-SEVERITY_RANK[m.status], m.workspace.name.lower()))
    return missions


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
    The reason recorded when the alarm fired travels with the event.
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
                reason = str(data["newState"].get("stateReason", ""))
                open_events[name] = Event(
                    alarms[name], owner[name], when, reason=reason
                )
        elif new_state == "OK" and name in open_events:
            event = open_events.pop(name)
            event.end = when
            events.append(event)
        # INSUFFICIENT_DATA neither opens nor closes an event.

    for name, alarm in alarms.items():
        if alarm.state == "ALARM" and name not in open_events and name in owner:
            open_events[name] = Event(
                alarm, owner[name], alarm.updated or now, reason=alarm.reason
            )
    events.extend(open_events.values())
    events.sort(key=lambda e: (not e.ongoing, -e.start.timestamp()))
    return events


def reconciliation_period(mission: Mission) -> int:
    """The workspace's health-check interval, read from its reconciliation alarms."""
    for stage in mission.stages:
        for alarm in stage.alarms:
            if (
                alarm.kind
                and alarm.kind.log_source == "reconciliation"
                and alarm.period
            ):
                return int(alarm.period)
    return DEFAULT_RECONCILIATION_PERIOD


def count_queries(
    missions: list[Mission],
) -> tuple[list[dict], dict[str, tuple[Workspace, str]]]:
    """GetMetricData queries for every mission's counts, and query id -> target.

    Each query asks for the Maximum over one reconciliation period, so a
    datapoint is the value one health-check run published.
    """
    queries: list[dict] = []
    lookup: dict[str, tuple[Workspace, str]] = {}
    for index, mission in enumerate(missions):
        period = reconciliation_period(mission)
        for attribute, metric in COUNT_METRICS.items():
            query_id = f"m{index}_{attribute}"
            lookup[query_id] = (mission.workspace, attribute)
            queries.append(
                {
                    "Id": query_id,
                    "MetricStat": {
                        "Metric": {
                            "Namespace": mission.workspace.namespace,
                            "MetricName": metric,
                        },
                        "Period": period,
                        "Stat": "Maximum",
                    },
                    "ReturnData": True,
                }
            )
    return queries, lookup


def parse_counts(
    results: list[dict], lookup: dict[str, tuple[Workspace, str]]
) -> dict[Workspace, Counts]:
    """Counts per workspace from MetricDataResults ordered newest first.

    A result without values (the metric has never been published, or not in
    the window) leaves that field None; a workspace with no values at all is
    absent from the mapping.
    """
    counts: dict[Workspace, Counts] = {}
    for result in results:
        target = lookup.get(result.get("Id", ""))
        values = result.get("Values") or []
        if target is None or not values:
            continue
        workspace, attribute = target
        setattr(
            counts.setdefault(workspace, Counts()),
            attribute,
            round(float(values[0])),
        )
    return counts


def counts_words(counts: Counts) -> list[tuple[str, str]]:
    """The "Last 24 h" segments as (text, tooltip) pairs, in reading order."""

    def plural(n: int, noun: str) -> str:
        return f"{n:,} {noun}{'' if n == 1 else 's'}"

    out: list[tuple[str, str]] = []
    if counts.arrived is not None:
        text = f"{plural(counts.arrived, 'file')} arrived"
        out.append((text, QUIET_DAY_NOTE if counts.arrived == 0 else ""))
    if counts.checked is not None:
        out.append((f"{counts.checked:,} checked", ""))
    missing = counts.missing
    if missing is not None:
        out.append((f"{plural(missing, 'missing record')}", ""))
    if counts.failed is not None:
        out.append((f"{counts.failed:,} failed processing", ""))
    return out


# -- AWS access ---------------------------------------------------------------


@dataclass(frozen=True)
class Settings:
    region: str
    console_region: str
    history_days: int
    contact: str = ""

    @classmethod
    def from_environment(cls) -> Settings:
        region = os.environ.get("AWS_REGION", "us-east-1")
        return cls(
            region=region,
            console_region=os.environ.get("CONSOLE_REGION", region),
            history_days=int(os.environ.get("HISTORY_DAYS", "14")),
            contact=os.environ.get("STATUS_CONTACT", "").strip(),
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
            threshold = record.get("Threshold")
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
                    description=record.get("AlarmDescription", "") or "",
                    threshold=float(threshold) if threshold is not None else None,
                    period=record.get("Period"),
                    dimensions={
                        d["Name"]: d["Value"] for d in record.get("Dimensions", [])
                    },
                    arn=record.get("AlarmArn", ""),
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


def fetch_counts(
    client, missions: list[Mission], now: dt.datetime
) -> dict[Workspace, Counts]:
    """The latest health-check counts of every mission, in one GetMetricData call.

    The window is two reconciliation periods so the latest run is always
    inside it whatever the phase of the schedule; the newest datapoint wins.
    More than 500 queries (100 workspaces) would take a second call.
    """
    if not missions:
        return {}
    queries, lookup = count_queries(missions)
    longest = max(reconciliation_period(m) for m in missions)
    start = now - dt.timedelta(seconds=2 * longest)
    results: list[dict] = []
    for offset in range(0, len(queries), METRIC_DATA_BATCH):
        kwargs = {
            "MetricDataQueries": queries[offset : offset + METRIC_DATA_BATCH],
            "StartTime": start,
            "EndTime": now,
            "ScanBy": "TimestampDescending",
        }
        while True:
            page = client.get_metric_data(**kwargs)
            results.extend(page.get("MetricDataResults", []))
            token = page.get("NextToken")
            if not token:
                break
            kwargs["NextToken"] = token
    return parse_counts(results, lookup)


def collect(client, environment: str, settings: Settings, now: dt.datetime) -> Snapshot:
    """Read CloudWatch and build the snapshot for one environment."""
    all_alarms = fetch_alarms(client)
    workspaces = [
        w
        for w in discover_workspaces([a.name for a in all_alarms])
        if w.environment == environment
    ]
    missions = build_missions(workspaces, all_alarms)
    # The counts line is a nicety: a missing permission or a throttled call
    # must not take the status page down with it.
    try:
        counts = fetch_counts(client, missions, now)
    except Exception:
        log.warning("daily counts unavailable; rendering without them", exc_info=True)
        counts = {}
    for mission in missions:
        mission.counts = counts.get(mission.workspace)
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
    by_workspace = {m.workspace: m for m in missions}
    for event in events:
        event.mission = by_workspace.get(event.workspace)
    return Snapshot(environment, missions, events[:20], now)


# -- words and numbers --------------------------------------------------------


def fill(template: str, alarm: Alarm) -> str:
    """Fill {stage}, {INSTRUMENT} and {h} in a headline or note."""
    stage = STAGE_BY_KEY.get(alarm.stage or "", None)
    hours = ""
    if alarm.threshold is not None and alarm.kind and alarm.kind.number == "age":
        hours = f"{alarm.threshold / 3600:g}"
    text = template.format(
        stage=stage.title if stage else "",
        INSTRUMENT=alarm.instrument.upper(),
        h=hours,
    )
    return text[:1].upper() + text[1:]


def headline(alarm: Alarm) -> str:
    if alarm.kind is None:
        return alarm.description or alarm.label
    return fill(alarm.kind.headline, alarm)


DATAPOINT = re.compile(r"\[(\d+(?:\.\d+)?) \(")
BUCKET_IN_DESCRIPTION = re.compile(r"\bin bucket (\S+)")


def bucket_in_description(description: str) -> str:
    """The bucket an alarm description names with "in bucket <name>", or ""."""
    match = BUCKET_IN_DESCRIPTION.search(description or "")
    return match.group(1).rstrip(";,.") if match else ""


def latest_datapoint(reason: str) -> float | None:
    """The first datapoint value in a CloudWatch 'Threshold Crossed' reason."""
    found = DATAPOINT.search(reason or "")
    return float(found.group(1)) if found else None


def measure(alarm: Alarm, reason: str | None = None) -> str:
    """The alarm's latest value in words, or '' when there is nothing to say."""
    reason = alarm.reason if reason is None else reason
    value = latest_datapoint(reason)
    if alarm.kind is None or alarm.kind.number == "none":
        return ""
    if value is None:
        # Hand-written or unexpected reasons are shown as they are.
        return "" if reason.startswith("Threshold Crossed") else reason
    kind = alarm.kind.number
    if kind == "files":
        return f"{int(value):,} file{'' if int(value) == 1 else 's'}"
    if kind == "count":
        minutes = round((alarm.period or 300) / 60)
        return f"{value:g} in the last {minutes} min"
    if kind == "duration":
        limit = (
            f", alarm line {alarm.threshold / 1000:.0f} s" if alarm.threshold else ""
        )
        return f"ran {value / 1000:.0f} s{limit}"
    if kind == "age":
        return f"waiting {value / 3600:.1f} h"
    return ""


def _when(moment: dt.datetime | None, now: dt.datetime) -> str:
    if moment is None:
        return ""
    moment = moment.astimezone(dt.UTC)
    pattern = "%b %d, %H:%M UTC" if moment.year == now.year else "%b %d %Y, %H:%M UTC"
    return moment.strftime(pattern)


def _day(moment: dt.datetime, now: dt.datetime) -> str:
    moment = moment.astimezone(dt.UTC)
    return moment.strftime("%b %d" if moment.year == now.year else "%b %d %Y")


def _ago(moment: dt.datetime | None, now: dt.datetime) -> str:
    """How long ago, in the coarsest unit that still reads naturally."""
    if moment is None:
        return ""
    seconds = max(0.0, (now - moment).total_seconds())
    if seconds < 90:
        return "just now"
    minutes = round(seconds / 60)
    if minutes < 90:
        return f"{minutes} min"
    hours = seconds / 3600
    if hours < 6:
        whole, rest = int(hours), round((hours - int(hours)) * 60)
        return f"{whole} h {rest} min" if rest else f"{whole} h"
    if hours < 36:
        return f"{round(hours)} h"
    days = round(hours / 24)
    return f"{days} day{'' if days == 1 else 's'}"


def _lasted(start: dt.datetime, end: dt.datetime) -> str:
    seconds = max(0.0, (end - start).total_seconds())
    if seconds < 3600:
        return f"{max(1, round(seconds / 60))} min"
    hours = seconds / 3600
    if hours < 48:
        whole, rest = int(hours), round((hours - int(hours)) * 60)
        return f"{whole} h {rest} min" if rest else f"{whole} h"
    days = round(hours / 24)
    return f"{days} day{'' if days == 1 else 's'}"


# -- console links --------------------------------------------------------------


def _console(region: str, service: str) -> str:
    return f"https://{region}.console.aws.amazon.com/{service}/home?region={region}"


def _console_alarm_url(region: str, alarm_name: str) -> str:
    return (
        f"{_console(region, 'cloudwatch')}#alarmsV2:alarm/{quote(alarm_name, safe='')}"
    )


def _console_alarms_search_url(region: str, prefix: str) -> str:
    return (
        f"{_console(region, 'cloudwatch')}#alarmsV2:?search={quote(prefix, safe='')}"
        "&alarmStateFilter=ALARM"
    )


def _console_dashboard_url(region: str, dashboard_name: str) -> str:
    return (
        f"{_console(region, 'cloudwatch')}#dashboards:name="
        f"{quote(dashboard_name, safe='')}"
    )


def _console_escape(value: str) -> str:
    """The CloudWatch Logs console's own escaping: percent-encode twice, then
    write every ``%`` as ``$`` (``/aws/lambda/x`` becomes ``$252Faws$252F...``)."""
    return quote(quote(value, safe=""), safe="").replace("%", "$")


def _log_search_url(
    region: str,
    group: str,
    pattern: str,
    start: dt.datetime,
    end: dt.datetime | None = None,
) -> str:
    """Log events of ``group`` filtered to ``pattern`` from ``start`` on."""
    url = (
        f"{_console(region, 'cloudwatch')}#logsV2:log-groups/log-group/"
        f"{_console_escape(group)}/log-events"
    )
    params = [f"start$3D{int(start.timestamp() * 1000)}"]
    if end is not None:
        params.append(f"end$3D{int(end.timestamp() * 1000)}")
    if pattern:
        params.insert(0, f"filterPattern$3D{_console_escape(pattern)}")
    return url + "$3F" + "$26".join(params)


def _lambda_monitoring_url(region: str, function: str) -> str:
    return (
        f"{_console(region, 'lambda')}#/functions/{quote(function, safe='')}"
        "?tab=monitoring"
    )


def _topic_url(region: str, account: str, topic: str) -> str:
    arn = f"arn:aws:sns:{region}:{account}:{topic}"
    return f"https://{region}.console.aws.amazon.com/sns/v3/home?region={region}#/topic/{arn}"


def _queue_url(region: str, account: str, queue: str) -> str:
    queue_url = f"https://sqs.{region}.amazonaws.com/{account}/{queue}"
    return (
        f"https://{region}.console.aws.amazon.com/sqs/v3/home?region={region}"
        f"#/queues/{quote(queue_url, safe='')}"
    )


def _bucket_url(region: str, bucket: str) -> str:
    return f"https://s3.console.aws.amazon.com/s3/buckets/{bucket}?region={region}&tab=objects"


@dataclass(frozen=True)
class Link:
    label: str
    url: str
    mono: bool = False
    title: str = ""


def evidence_links(
    alarm: Alarm,
    mission: Mission,
    region: str,
    start: dt.datetime | None,
    end: dt.datetime | None = None,
) -> list[Link]:
    """Logs, alarm and resource links for one firing alarm, in reading order."""
    links: list[Link] = []
    kind = alarm.kind
    if kind is None:
        return [Link("Alarm", _console_alarm_url(region, alarm.name), mono=True)]

    stage_key = alarm.stage or ""
    source = kind.log_source
    function = None
    if source == "self":
        function = alarm.dimensions.get("FunctionName") or mission.functions.get(
            stage_key
        )
    elif source == "stage":
        function = mission.functions.get(stage_key)
    elif source.startswith("stage:"):
        function = mission.functions.get(source.split(":", 1)[1])
    elif source == "reconciliation":
        function = mission.functions.get("reconciliation")

    if function and start is not None:
        pattern = kind.log_filter
        if pattern == "{stage}":
            pattern = LOG_ERROR_PATTERNS.get(stage_key, "")
        elif pattern == "{processing}":
            pattern = LOG_ERROR_PATTERNS["processing"]
        lead = dt.timedelta(seconds=(alarm.period or 300) * 3)
        window_end = end + dt.timedelta(minutes=15) if end else None
        links.append(
            Link(
                fill(kind.log_label, alarm),
                _log_search_url(
                    region, f"/aws/lambda/{function}", pattern, start - lead, window_end
                ),
                title=f"/aws/lambda/{function}",
            )
        )

    monitor = alarm.dimensions.get("FunctionName") or (
        mission.functions.get("reconciliation")
        if source == "reconciliation"
        else mission.functions.get(stage_key)
    )
    if kind.monitoring and monitor:
        links.append(Link("Lambda monitoring", _lambda_monitoring_url(region, monitor)))

    account = alarm.account
    if kind.resource == "topic" and alarm.dimensions.get("TopicName"):
        topic = alarm.dimensions["TopicName"]
        if account:
            links.append(Link("Topic", _topic_url(region, account, topic)))
        bucket = topic.removesuffix("-sns-topic")
        if bucket != topic:
            links.append(Link("Instrument bucket", _bucket_url(region, bucket)))
    if kind.resource == "queue" and alarm.dimensions.get("QueueName"):
        queue = alarm.dimensions["QueueName"]
        if account:
            links.append(Link("Queue", _queue_url(region, account, queue)))
    if kind.resource == "incoming-bucket":
        bucket = bucket_in_description(alarm.description)
        if bucket:
            links.append(
                Link("Incoming bucket", _bucket_url(region, bucket), title=bucket)
            )

    links.append(
        Link(
            "Alarm", _console_alarm_url(region, alarm.name), mono=True, title=alarm.name
        )
    )
    return links


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
        "chip_bg": "#1c1c1e",
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
        "chip_bg": "#f5f5f7",
    },
}


def _glyph(status: str, palette: dict[str, str], size: int = 18) -> str:
    """Shape plus colour plus an inner mark, so states read without colour."""
    colour = palette.get(status, palette["nodata"])
    mark = palette["bg"]
    if status == "available":
        shape = (
            f'<circle cx="9" cy="9" r="8" fill="{colour}"></circle>'
            f'<path d="M5 9.5 8 12.5 13 6" fill="none" stroke="{mark}" '
            'stroke-width="2" stroke-linecap="round" stroke-linejoin="round"></path>'
        )
    elif status == "issue":
        shape = (
            f'<path d="M9 1 17 9 9 17 1 9Z" fill="{colour}"></path>'
            f'<rect x="8" y="5" width="2" height="5" fill="{mark}"></rect>'
            f'<rect x="8" y="11.5" width="2" height="2" fill="{mark}"></rect>'
        )
    elif status == "outage":
        shape = (
            f'<path d="M9 1.5 17 16H1Z" fill="{colour}"></path>'
            f'<path d="M6.5 8l5 5M11.5 8l-5 5" stroke="{mark}" stroke-width="2" '
            'stroke-linecap="round"></path>'
        )
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
        f'<svg width="{size}" height="{size}" viewBox="0 0 18 18" role="img" '
        f'aria-label="{STATUS_LABELS.get(status, status)}" '
        f'style="flex:0 0 auto">{shape}</svg>'
    )


def _css(p: dict[str, str]) -> str:
    font = '-apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif'
    mono = "ui-monospace,SFMono-Regular,Menlo,Consolas,monospace"
    return f"""
.sw {{background:{p["bg"]};color:{p["fg"]};font-family:{font};-webkit-font-smoothing:antialiased;padding:8px 16px 24px;box-sizing:border-box;line-height:1.4}}
.sw * {{box-sizing:border-box}}
.sw .wrap {{max-width:880px;margin:0 auto}}
.sw h1 {{margin:20px 0 16px;font-size:32px;font-weight:700;letter-spacing:-0.3px;text-align:center;color:{p["fg"]}}}
.sw h1.sub {{font-size:22px;margin-bottom:4px}}
.sw .subtitle {{text-align:center;color:{p["muted"]};font-size:13px;margin:0 0 16px}}
.sw a {{color:{p["link"]};text-decoration:none}}
.sw a:hover {{text-decoration:underline}}
.sw .band {{display:flex;gap:14px;align-items:flex-start;padding:14px 16px;border-left:4px solid {p["nodata"]};background:{p["chip_bg"]};border-radius:0 10px 10px 0}}
.sw .band.available {{border-left-color:{p["available"]}}}
.sw .band.issue {{border-left-color:{p["issue"]}}}
.sw .band.outage {{border-left-color:{p["outage"]}}}
.sw .band .verdict {{font-size:17px;font-weight:600;flex:1 1 auto;min-width:0}}
.sw .band .checked {{color:{p["muted"]};font-size:12px;margin-top:6px;font-weight:400}}
.sw .problems {{margin:10px 0 0 20px;padding:0;list-style:none}}
.sw .problems li {{display:flex;align-items:center;gap:10px;padding:6px 0;font-size:14px}}
.sw .problems .who {{font-weight:600}}
.sw .problems .ago {{color:{p["muted"]};margin-left:auto;white-space:nowrap;font-size:13px}}
.sw .legend {{display:flex;flex-wrap:wrap;gap:6px 22px;font-size:12px;color:{p["muted"]};margin:14px 0 4px}}
.sw .legend div {{display:flex;align-items:center;gap:6px}}
.sw .legend b {{color:{p["fg"]};font-weight:600}}
.sw details.group {{border-top:1px solid {p["rule_strong"]};margin-top:14px}}
.sw details.group:last-of-type {{border-bottom:1px solid {p["rule_strong"]}}}
.sw summary.ghead {{display:flex;align-items:center;gap:14px;min-height:54px;padding:8px 0;cursor:pointer;list-style:none}}
.sw summary.ghead::-webkit-details-marker {{display:none}}
.sw .gtitle {{flex:1 1 auto;min-width:0}}
.sw .gname {{font-size:18px;font-weight:600;color:{p["fg"]}}}
.sw .gsub {{color:{p["muted"]};font-size:13px;margin-top:1px}}
.sw .gcounts {{color:{p["muted"]};font-size:12px;margin-top:2px}}
.sw .gcounts .quiet {{cursor:help;border-bottom:1px dotted {p["muted"]}}}
.sw .pills {{display:flex;gap:6px;flex-wrap:wrap;align-items:center}}
.sw .pill {{display:inline-flex;align-items:center;gap:4px;border:1px solid {p["rule_strong"]};border-radius:6px;padding:2px 8px;font-size:12px;line-height:18px;color:{p["link"]};white-space:nowrap;background:{p["bg"]}}}
.sw .pill.mono {{font-family:{mono};font-size:11px}}
.sw .chev {{width:26px;height:26px;border-radius:50%;background:{p["button"]};display:flex;align-items:center;justify-content:center;flex:0 0 auto}}
.sw .chev svg {{transition:transform .15s}}
.sw details[open] > summary .chev svg {{transform:rotate(90deg)}}
.sw .gbody {{padding:0 0 12px 32px}}
.sw .row {{display:flex;align-items:flex-start;gap:12px;padding:9px 0;border-bottom:1px solid {p["rule"]};font-size:14px}}
.sw .row:last-child {{border-bottom:0}}
.sw .row .g {{margin-top:2px}}
.sw .name {{flex:0 0 190px;min-width:0}}
.sw .name .t {{font-weight:500}}
.sw .name .d {{color:{p["muted"]};font-size:12px;line-height:1.35;margin-top:1px}}
.sw .state {{flex:0 0 120px;padding-top:1px}}
.sw .st-available {{color:{p["available"]};font-weight:600}}
.sw .st-issue {{color:{p["issue"]};font-weight:600}}
.sw .st-outage {{color:{p["outage"]};font-weight:600}}
.sw .st-nodata {{color:{p["nodata"]};font-weight:600}}
.sw .st-off {{color:{p["off"]};font-weight:600}}
.sw .right {{flex:1 1 auto;min-width:0;font-size:13px}}
.sw .right .note {{color:{p["muted"]};font-size:12px}}
.sw .incident {{padding:8px 10px;border-radius:8px;background:{p["chip_bg"]};margin:4px 0 6px}}
.sw .incident + .incident {{margin-top:6px}}
.sw .incident .h {{font-size:14px;font-weight:500}}
.sw .incident .n {{font-weight:400;color:{p["muted"]}}}
.sw .incident .t {{color:{p["muted"]};font-size:12px;margin:2px 0 6px}}
.sw details.todo {{display:inline-block}}
.sw details.todo summary {{list-style:none;cursor:pointer;display:inline-flex}}
.sw details.todo summary::-webkit-details-marker {{display:none}}
.sw details.todo p {{margin:8px 0 2px;font-size:13px;color:{p["fg"]};max-width:640px}}
.sw .unused {{color:{p["muted"]};font-size:12px;padding:8px 0 0}}
.sw .muted {{color:{p["muted"]};font-size:12px}}
.sw .empty {{border:1px dashed {p["rule_strong"]};border-radius:10px;padding:20px;margin-top:22px;color:{p["muted"]};font-size:14px;text-align:center}}
.sw h2 {{margin:36px 0 2px;font-size:20px;font-weight:600;color:{p["fg"]}}}
.sw .ev {{display:flex;gap:16px;align-items:flex-start;padding:12px 0;border-bottom:1px solid {p["rule"]};font-size:14px}}
.sw .ev:last-child {{border-bottom:0}}
.sw .evtime {{color:{p["muted"]};font-size:12px;margin-top:3px;flex:0 0 150px}}
.sw .evwhat {{flex:1 1 auto;min-width:0}}
.sw .evwhat .pills {{margin-top:6px}}
.sw .contact {{margin-top:26px;font-size:13px;color:{p["muted"]}}}
.sw .err {{border:1px solid {p["outage"]};border-radius:10px;padding:16px;margin-top:22px;font-size:14px;display:flex;gap:12px;align-items:center}}
@media (max-width:640px) {{.sw .name {{flex-basis:130px}} .sw .state {{flex-basis:90px}} .sw .evtime {{flex-basis:110px}}}}
"""


def _status_span(status: str) -> str:
    return (
        f'<span class="st-{status}" title="{html.escape(STATUS_MEANINGS[status])}">'
        f"{STATUS_LABELS[status]}</span>"
    )


def _pill_items(links: list[Link]) -> str:
    out = []
    for link in links:
        classes = "pill mono" if link.mono else "pill"
        title = f' title="{html.escape(link.title)}"' if link.title else ""
        out.append(
            f'<a class="{classes}" href="{html.escape(link.url, quote=True)}" '
            f'target="_blank" rel="noopener"{title}>{html.escape(link.label)}</a>'
        )
    return "".join(out)


def _pills(links: list[Link], extra: str = "") -> str:
    if not links and not extra:
        return ""
    return f'<span class="pills">{_pill_items(links)}{extra}</span>'


def _join_names(names: list[str]) -> str:
    if len(names) <= 1:
        return "".join(names)
    return ", ".join(names[:-1]) + " and " + names[-1]


def verdict(snapshot: Snapshot) -> str:
    """One sentence a manager can read in a meeting."""
    missions = snapshot.missions
    now = snapshot.generated
    broken = [m for m in missions if m.status in ("issue", "outage")]
    if not broken:
        count = len(missions)
        if count == 1:
            return f"{missions[0].workspace.name} is receiving and processing data."
        return f"All {count} missions are receiving and processing data."
    parts = []
    for mission in broken:
        ago = _ago(mission.since, now)
        for_how_long = f" for {ago}" if ago and ago != "just now" else ""
        if mission.status == "outage":
            parts.append(
                f"{mission.workspace.name} has not been getting data through{for_how_long}."
            )
        else:
            parts.append(
                f"{mission.workspace.name} has errors (data still flowing){for_how_long}."
            )
    fine = [m.workspace.name for m in missions if m.status not in ("issue", "outage")]
    if fine:
        verb = "is" if len(fine) == 1 else "are"
        parts.append(f"{_join_names(fine)} {verb} fine.")
    return " ".join(parts)


def render_band(snapshot: Snapshot, palette: dict[str, str]) -> str:
    now = snapshot.generated
    missions = snapshot.missions
    overall = (
        worst([m.status for m in missions if m.status != "nodata"])
        if missions
        else "off"
    )
    if overall == "off":
        overall = "nodata"
    band = (
        f'<div class="band {overall}">{_glyph(overall, palette, 24)}'
        f'<div class="verdict">{html.escape(verdict(snapshot))}'
        f'<div class="checked">Checked {_when(now, now)} · refreshes with the dashboard'
        "</div></div></div>"
    )
    problems = []
    for mission in missions:
        for stage in mission.firing_stages:
            firing = stage.firing
            if not firing:
                continue
            lead = firing[0]
            more = f" · +{len(firing) - 1} more" if len(firing) > 1 else ""
            problems.append(
                f"<li>{_glyph(stage.status, palette, 16)}"
                f'<span class="who">{html.escape(mission.workspace.name)}</span>'
                f"<span>{html.escape(stage.title)}: {html.escape(headline(lead))}"
                f"{html.escape(more)}</span>"
                f'<span class="ago">{html.escape(_ago(stage.since, now))}</span></li>'
            )
    if problems:
        band += '<ul class="problems">' + "".join(problems) + "</ul>"
    return band


def render_legend(palette: dict[str, str]) -> str:
    items = []
    for status in ("available", "issue", "outage", "nodata", "off"):
        label, _, meaning = STATUS_MEANINGS[status].partition(": ")
        items.append(
            f"<div>{_glyph(status, palette, 14)}<b>{html.escape(label)}</b>"
            f"<span>{html.escape(meaning)}</span></div>"
        )
    return '<div class="legend">' + "".join(items) + "</div>"


def mission_subtitle(mission: Mission, now: dt.datetime) -> str:
    """Plain text for the group header: the problem and how long, or all clear."""
    not_checked = [s for s in mission.stages if s.status == "nodata"]
    if mission.status == "available":
        text = "Data flowing normally"
        if not_checked:
            n = len(not_checked)
            text += f" · {n} check{'' if n == 1 else 's'} not active yet"
        return text
    if mission.status == "nodata":
        return "Not reporting yet: the health check has not run for this mission"
    if mission.status == "off":
        return "No steps reporting"
    firing = mission.firing_stages
    lead = firing[0]
    others = sum(len(s.firing) for s in firing) - 1
    head = headline(lead.firing[0]) if lead.firing else lead.title
    parts = [STATUS_LABELS[mission.status], head]
    ago = _ago(mission.since, now)
    if ago:
        parts.append(ago)
    if others > 0:
        parts.append(f"+{others} more")
    return " · ".join(parts)


def render_incident(
    alarm: Alarm, mission: Mission, region: str, now: dt.datetime
) -> str:
    number = measure(alarm)
    number_html = f' <span class="n">· {html.escape(number)}</span>' if number else ""
    started = ""
    if alarm.updated:
        ago = _ago(alarm.updated, now)
        ago = ago if ago == "just now" else f"{ago} ago"
        started = f"Started {ago} ({_when(alarm.updated, now)})"
    links = evidence_links(alarm, mission, region, alarm.updated)
    todo = ""
    if alarm.kind:
        todo = (
            '<details class="todo"><summary class="pill">What to do</summary>'
            f"<p>{html.escape(alarm.description)}"
            f"{' ' if alarm.description else ''}"
            f"{html.escape(fill(alarm.kind.what_to_do, alarm))}</p></details>"
        )
    return (
        f'<div class="incident"><div class="h">{html.escape(headline(alarm))}'
        f"{number_html}</div>"
        f'<div class="t" title="{html.escape(alarm.reason)}">{html.escape(started)}</div>'
        f"{_pills(links, todo)}</div>"
    )


def render_counts(mission: Mission) -> str:
    """The muted "Last 24 h" line under a mission header, or "" without counts."""
    if mission.counts is None or not mission.counts.available:
        return ""
    segments = []
    for text, tooltip in counts_words(mission.counts):
        if tooltip:
            segments.append(
                f'<span class="quiet" title="{html.escape(tooltip)}">'
                f"{html.escape(text)}</span>"
            )
        else:
            segments.append(html.escape(text))
    return (
        '<div class="gcounts" title="Counted by the latest health-check run">'
        f"Last 24 h: {' · '.join(segments)}</div>"
    )


def render_mission(
    mission: Mission, palette: dict[str, str], region: str, now: dt.datetime
) -> str:
    is_open = mission.status in ("issue", "outage")
    rows = []
    unused = []
    for stage in mission.stages:
        if stage.status == "off":
            unused.append(stage.title)
            continue
        right = ""
        if stage.status in ("issue", "outage"):
            right = "".join(
                render_incident(alarm, mission, region, now) for alarm in stage.firing
            )
        elif stage.status == "nodata":
            right = (
                '<span class="note">The health check has not reported for this '
                "mission yet.</span>"
            )
        rows.append(
            f'<div class="row"><span class="g">{_glyph(stage.status, palette, 16)}</span>'
            f'<span class="name" title="{html.escape(stage.info.technical)}">'
            f'<div class="t">{html.escape(stage.title)}</div>'
            f'<div class="d">{html.escape(stage.info.description)}</div></span>'
            f'<span class="state">{_status_span(stage.status)}</span>'
            f'<span class="right">{right}</span></div>'
        )
    if unused:
        verb = "is" if len(unused) == 1 else "are"
        rows.append(
            f'<div class="unused">{html.escape(_join_names(unused))} {verb} not part '
            "of this mission's pipeline.</div>"
        )
    header_links = [
        Link(
            "Graphs", _console_dashboard_url(region, mission.workspace.dashboard_name)
        ),
        Link(
            "All alarms",
            _console_alarms_search_url(region, mission.workspace.dashboard_name),
        ),
    ]
    chevron = (
        '<span class="chev" aria-hidden="true"><svg width="14" height="14" '
        'viewBox="0 0 18 18"><path d="M6 4 11 9 6 14" fill="none" '
        f'stroke="{palette["button_fg"]}" stroke-width="2" stroke-linecap="round" '
        'stroke-linejoin="round"></path></svg></span>'
    )
    return (
        f'<details class="group"{" open" if is_open else ""}>'
        f'<summary class="ghead">{_glyph(mission.status, palette)}'
        f'<span class="gtitle"><div class="gname">{html.escape(mission.workspace.name)}'
        f'</div><div class="gsub">{html.escape(mission_subtitle(mission, now))}</div>'
        f"{render_counts(mission)}</span>"
        f"{_pills(header_links)}{chevron}</summary>"
        f'<div class="gbody">{"".join(rows)}</div></details>'
    )


def render_events(snapshot: Snapshot, region: str) -> str:
    now = snapshot.generated
    if not snapshot.events:
        return '<p class="muted">Nothing has gone wrong in the last two weeks.</p>'
    out = []
    for event in snapshot.events:
        alarm = event.alarm
        if not event.ongoing:
            status, label = "available", "Resolved"
        elif alarm.state == "ALARM":
            status, label = alarm.severity, STATUS_LABELS[alarm.severity]
        else:
            # Open incident whose alarm has since gone to INSUFFICIENT_DATA:
            # unresolved, but not a confirmed issue or outage right now.
            status, label = "nodata", "Not checked yet"
        if event.ongoing:
            when = f"Ongoing · {_ago(event.start, now)}"
            when_title = f"since {_when(event.start, now)}"
        else:
            when = (
                f"{_day(event.start, now)} · lasted {_lasted(event.start, event.end)}"
            )
            when_title = f"{_when(event.start, now)} – {_when(event.end, now)}"
        stage = STAGE_BY_KEY.get(alarm.stage or "")
        stage_title = stage.title if stage else "Pipeline"
        number = measure(alarm, event.reason)
        number_html = (
            f' · <span class="muted">{html.escape(number)}</span>' if number else ""
        )
        links = []
        if event.mission is not None:
            links = evidence_links(alarm, event.mission, region, event.start, event.end)
        out.append(
            f'<div class="ev"><div class="evtime" title="{html.escape(when_title)}">'
            f"{html.escape(when)}</div>"
            f'<div class="evwhat"><div><span class="st-{status}">{label}</span> · '
            f"{html.escape(event.workspace.name)} · {html.escape(stage_title)}: "
            f"{html.escape(headline(alarm))}{number_html}</div>"
            f"{_pills(links)}</div></div>"
        )
    return "".join(out)


def render(snapshot: Snapshot, theme: str, region: str, contact: str = "") -> str:
    """The widget HTML for one environment."""
    palette = PALETTES["light" if theme == "light" else "dark"]
    env_name = ENVIRONMENTS.get(snapshot.environment, snapshot.environment)
    now = snapshot.generated
    parts = [
        '<div class="cwdb-no-default-styles"></div>',
        f"<style>{_css(palette)}</style>",
    ]
    parts.append('<div class="sw"><div class="wrap">')
    if snapshot.environment == "dev":
        parts.append(f'<h1 class="sub">{html.escape(env_name)} Pipeline Status</h1>')
        parts.append('<p class="subtitle">Test environment · not science data</p>')
    else:
        parts.append(f"<h1>{html.escape(env_name)} Pipeline Status</h1>")
    if snapshot.missions:
        parts.append(render_band(snapshot, palette))
        parts.append(render_legend(palette))
        parts.extend(render_mission(m, palette, region, now) for m in snapshot.missions)
        parts.append("<h2>Recent events</h2>")
        parts.append(
            '<p class="muted" style="margin:0 0 6px">What has gone wrong in the last '
            "14 days, newest first. Ongoing problems are also shown in the mission "
            "list above.</p>"
        )
        parts.append(render_events(snapshot, region))
    else:
        parts.append(
            f'<div class="empty">No mission pipelines are reporting for {env_name} '
            "yet. A mission appears here once its pipeline health alarms "
            "(<code>&lt;env&gt;&lt;mission&gt;-pipeline-*</code>) exist.</div>"
        )
        parts.append(
            f'<p class="muted" style="margin:12px 0 0">Checked {_when(now, now)}.</p>'
        )
        parts.append(render_legend(palette))
    if contact:
        parts.append(
            f'<p class="contact">Questions about an outage: {html.escape(contact)}</p>'
        )
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
    return render(snapshot, theme, settings.console_region, settings.contact)
