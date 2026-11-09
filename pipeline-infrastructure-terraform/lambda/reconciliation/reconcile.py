"""Reconcile one mission workspace's pipeline against the files it handled.

Runs on a schedule, looks back a window of hours, and compares what is in S3
with what the pipeline recorded about it:

* an object still in the incoming bucket after the grace period is unsorted
  (sorting is a move, so a healthy pipeline leaves nothing there);
* an object under a data-level prefix of an instrument bucket must have a
  MetaTracker row (``<mission>_science_file``) and a Timestream record.

The counts are published as CloudWatch metrics in the workspace's namespace,
and every missing key is logged so the log doubles as the replay list. The
checks are independent: one that cannot run (RDS unreachable, say) counts as
a check error and the others still report.

Configuration comes from environment variables set by Terraform; see
``pipeline_health.tf``. ``boto3`` is imported lazily so the pure functions can
be unit-tested without it.
"""

from __future__ import annotations

import json
import logging
import os
import re
from collections.abc import Iterable
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta

import pgwire

log = logging.getLogger("reconcile")
log.setLevel(logging.INFO)

IDENTIFIER = re.compile(r"^[A-Za-z0-9_]+$")
MAX_LOGGED_KEYS = 200
SQL_CHUNK = 500


@dataclass(frozen=True)
class S3Object:
    bucket: str
    key: str
    last_modified: datetime

    @property
    def basename(self) -> str:
        return self.key.rsplit("/", 1)[-1]

    @property
    def stem(self) -> str:
        name = self.basename
        return name.rsplit(".", 1)[0] if "." in name else name


@dataclass
class Settings:
    mission: str
    environment: str
    incoming_bucket: str
    instrument_buckets: list[str]
    data_levels: list[str]
    timestream_database: str
    timestream_table: str
    metric_namespace: str
    window: timedelta
    grace: timedelta
    ignore_key: re.Pattern[str] | None
    rds_secret_arn: str
    skip_rds: bool
    region: str

    @property
    def science_file_table(self) -> str:
        return f"{self.mission}_science_file"

    @property
    def status_table(self) -> str:
        return f"{self.mission}_status"

    @classmethod
    def from_environment(cls, env: dict[str, str] | None = None) -> Settings:
        env = os.environ if env is None else env
        mission = env["MISSION"]
        if not IDENTIFIER.match(mission):
            raise ValueError(f"MISSION {mission!r} is not a valid identifier")
        ignore = env.get("IGNORE_KEY_REGEX", "")
        return cls(
            mission=mission,
            environment=env.get("ENVIRONMENT", "dev"),
            incoming_bucket=env["INCOMING_BUCKET"],
            instrument_buckets=_split(env["INSTRUMENT_BUCKETS"]),
            data_levels=_split(env["DATA_LEVELS"]),
            timestream_database=env["TIMESTREAM_DATABASE"],
            timestream_table=env["TIMESTREAM_TABLE"],
            metric_namespace=env["METRIC_NAMESPACE"],
            window=timedelta(hours=float(env.get("WINDOW_HOURS", "24"))),
            grace=timedelta(minutes=float(env.get("GRACE_MINUTES", "60"))),
            ignore_key=re.compile(ignore) if ignore else None,
            rds_secret_arn=env.get("RDS_SECRET_ARN", ""),
            skip_rds=env.get("SKIP_RDS", "false").lower() == "true",
            region=env.get("AWS_REGION", env.get("AWS_DEFAULT_REGION", "us-east-1")),
        )


def _split(value: str) -> list[str]:
    return [part.strip() for part in value.split(",") if part.strip()]


@dataclass
class Report:
    """Everything one run found, in the shape the metrics are published in."""

    incoming_in_window: int = 0
    incoming_backlog: int = 0
    unsorted: list[str] = field(default_factory=list)
    reconciled: int = 0
    missing_metatracker: list[str] = field(default_factory=list)
    missing_timestream: list[str] = field(default_factory=list)
    failed_processing: int = 0
    check_errors: list[str] = field(default_factory=list)
    skipped: list[str] = field(default_factory=list)

    def metrics(self) -> dict[str, int]:
        return {
            "IncomingObjectsInWindow": self.incoming_in_window,
            "IncomingBacklogObjects": self.incoming_backlog,
            "UnsortedIncomingObjects": len(self.unsorted),
            "ReconciledObjects": self.reconciled,
            "MissingMetaTrackerRows": len(self.missing_metatracker),
            "MissingTimestreamRecords": len(self.missing_timestream),
            "FailedProcessingFiles": self.failed_processing,
            "ReconciliationCheckErrors": len(self.check_errors),
            "ReconciliationRuns": 1,
        }

    def summary(self) -> dict[str, object]:
        return {
            "metrics": self.metrics(),
            "unsorted": self.unsorted[:MAX_LOGGED_KEYS],
            "missing_metatracker": self.missing_metatracker[:MAX_LOGGED_KEYS],
            "missing_timestream": self.missing_timestream[:MAX_LOGGED_KEYS],
            "check_errors": self.check_errors,
            "skipped": self.skipped,
        }


# -- pure logic ---------------------------------------------------------------


def classify_incoming(
    objects: Iterable[S3Object],
    now: datetime,
    window: timedelta,
    grace: timedelta,
    ignore_key: re.Pattern[str] | None,
) -> tuple[list[str], int, int]:
    """Split incoming objects into (unsorted keys, backlog count, in-window count).

    Objects newer than ``grace`` are still being worked on and are only counted
    towards the in-window total. Objects older than ``window`` are backlog:
    reported, never alarmed, so a historical leftover does not alarm forever.
    """
    unsorted: list[str] = []
    backlog = 0
    in_window = 0
    for obj in objects:
        if ignore_key is not None and ignore_key.search(obj.key):
            continue
        age = now - obj.last_modified
        if age > window:
            backlog += 1
            continue
        in_window += 1
        if age >= grace:
            unsorted.append(obj.key)
    unsorted.sort()
    return unsorted, backlog, in_window


def processed_candidates(
    objects: Iterable[S3Object],
    data_levels: Iterable[str],
    now: datetime,
    window: timedelta,
    grace: timedelta,
) -> list[S3Object]:
    """Objects the pipeline should have processed and recorded.

    Only keys under a data-level prefix reach the instrument topic, so only
    those are judged, and only once they are older than ``grace`` and within
    ``window``.
    """
    prefixes = tuple(f"{level}/" for level in data_levels)
    chosen = [
        obj
        for obj in objects
        if obj.key.startswith(prefixes)
        and not obj.key.endswith("/")
        and grace <= now - obj.last_modified <= window
    ]
    chosen.sort(key=lambda obj: (obj.bucket, obj.key))
    return chosen


def missing_from_metatracker(
    candidates: Iterable[S3Object], filenames: set[str], s3_keys: set[str]
) -> list[str]:
    """Candidates with no MetaTracker row.

    The processing Lambda records an input with its full key and a product
    with its bare filename, and ``filename`` is always the stem, so a row
    counts when any of the three match.
    """
    return [
        f"s3://{obj.bucket}/{obj.key}"
        for obj in candidates
        if obj.stem not in filenames
        and obj.key not in s3_keys
        and obj.basename not in s3_keys
    ]


def missing_from_timestream(
    candidates: Iterable[S3Object], recorded_keys: set[str]
) -> list[str]:
    """Candidates that appear in neither ``file_key`` nor ``new_file_key``."""
    return [
        f"s3://{obj.bucket}/{obj.key}"
        for obj in candidates
        if obj.key not in recorded_keys and obj.basename not in recorded_keys
    ]


def metatracker_sql(table: str, column: str, values: Iterable[str]) -> str:
    """SELECT the rows whose ``column`` is one of ``values``."""
    if not IDENTIFIER.match(table) or not IDENTIFIER.match(column):
        raise ValueError("table and column must be plain identifiers")
    literals = ", ".join(pgwire.quote_literal(value) for value in values)
    return (
        f"SELECT filename, s3_key FROM {pgwire.quote_identifier(table)} "
        f"WHERE {pgwire.quote_identifier(column)} = ANY(ARRAY[{literals}]::text[])"
    )


def failed_status_sql(status_table: str, window: timedelta) -> str:
    if not IDENTIFIER.match(status_table):
        raise ValueError("status table must be a plain identifier")
    hours = max(1, int(window.total_seconds() // 3600))
    return (
        f"SELECT count(*) FROM {pgwire.quote_identifier(status_table)} "
        f"WHERE processing_status = 'failed' AND last_processing_timestamp > "
        f"now() - interval '{hours} hours'"
    )


def timestream_sql(database: str, table: str, window: timedelta) -> str:
    hours = max(1, int(window.total_seconds() // 3600)) + 2
    return (
        f'SELECT DISTINCT file_key, new_file_key FROM "{database}"."{table}" '
        f"WHERE time > ago({hours}h)"
    )


# -- AWS access ---------------------------------------------------------------


def list_bucket(s3, bucket: str) -> list[S3Object]:
    objects: list[S3Object] = []
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket):
        for item in page.get("Contents", []):
            objects.append(S3Object(bucket, item["Key"], item["LastModified"]))
    return objects


def fetch_metatracker_rows(
    connection: pgwire.Connection, table: str, candidates: list[S3Object]
) -> tuple[set[str], set[str]]:
    """Return the filenames and s3_keys MetaTracker holds for ``candidates``."""
    filenames: set[str] = set()
    s3_keys: set[str] = set()
    lookups = {
        "filename": sorted({obj.stem for obj in candidates}),
        "s3_key": sorted(
            {obj.key for obj in candidates} | {obj.basename for obj in candidates}
        ),
    }
    for column, values in lookups.items():
        for start in range(0, len(values), SQL_CHUNK):
            chunk = values[start : start + SQL_CHUNK]
            for filename, s3_key in connection.query(
                metatracker_sql(table, column, chunk)
            ):
                if filename:
                    filenames.add(filename)
                if s3_key:
                    s3_keys.add(s3_key)
    return filenames, s3_keys


def fetch_timestream_keys(timestream, sql: str) -> set[str]:
    keys: set[str] = set()
    token: str | None = None
    while True:
        kwargs = {"QueryString": sql}
        if token:
            kwargs["NextToken"] = token
        response = timestream.query(**kwargs)
        for row in response.get("Rows", []):
            for datum in row.get("Data", []):
                value = datum.get("ScalarValue")
                if value:
                    keys.add(value)
        token = response.get("NextToken")
        if not token:
            return keys


def open_rds(settings: Settings, secrets) -> pgwire.Connection:
    secret = json.loads(
        secrets.get_secret_value(SecretId=settings.rds_secret_arn)["SecretString"]
    )
    return pgwire.connect(
        host=secret["host"],
        port=int(secret["port"]),
        database=secret["dbname"],
        user=secret["username"],
        password=secret["password"],
    )


def publish_metrics(cloudwatch, namespace: str, metrics: dict[str, int]) -> None:
    cloudwatch.put_metric_data(
        Namespace=namespace,
        MetricData=[
            {"MetricName": name, "Value": value, "Unit": "Count"}
            for name, value in metrics.items()
        ],
    )


# -- the run ------------------------------------------------------------------


def reconcile(settings: Settings, session, now: datetime | None = None) -> Report:
    now = now or datetime.now(UTC)
    report = Report()
    s3 = session.client("s3")

    try:
        incoming = list_bucket(s3, settings.incoming_bucket)
        report.unsorted, report.incoming_backlog, report.incoming_in_window = (
            classify_incoming(
                incoming, now, settings.window, settings.grace, settings.ignore_key
            )
        )
    except Exception as error:  # noqa: BLE001 - every check reports, none aborts
        log.exception("incoming bucket check failed")
        report.check_errors.append(f"incoming: {error}")

    candidates: list[S3Object] = []
    try:
        objects: list[S3Object] = []
        for bucket in settings.instrument_buckets:
            objects.extend(list_bucket(s3, bucket))
        candidates = processed_candidates(
            objects, settings.data_levels, now, settings.window, settings.grace
        )
        report.reconciled = len(candidates)
    except Exception as error:  # noqa: BLE001
        log.exception("instrument bucket listing failed")
        report.check_errors.append(f"instrument buckets: {error}")

    if settings.skip_rds or not settings.rds_secret_arn:
        report.skipped.append("metatracker: no network path to RDS (SKIP_RDS)")
    else:
        try:
            with open_rds(settings, session.client("secretsmanager")) as connection:
                filenames, s3_keys = fetch_metatracker_rows(
                    connection, settings.science_file_table, candidates
                )
                report.missing_metatracker = missing_from_metatracker(
                    candidates, filenames, s3_keys
                )
                rows = connection.query(
                    failed_status_sql(settings.status_table, settings.window)
                )
                report.failed_processing = int(rows[0][0] or 0) if rows else 0
        except Exception as error:  # noqa: BLE001
            log.exception("metatracker check failed")
            report.check_errors.append(f"metatracker: {error}")

    try:
        recorded = fetch_timestream_keys(
            session.client("timestream-query"),
            timestream_sql(
                settings.timestream_database, settings.timestream_table, settings.window
            ),
        )
        report.missing_timestream = missing_from_timestream(candidates, recorded)
    except Exception as error:  # noqa: BLE001
        log.exception("timestream check failed")
        report.check_errors.append(f"timestream: {error}")

    return report


def handler(event, context):  # noqa: ARG001 - Lambda signature
    import boto3

    settings = Settings.from_environment()
    session = boto3.session.Session(region_name=settings.region)
    report = reconcile(settings, session)
    publish_metrics(
        session.client("cloudwatch"), settings.metric_namespace, report.metrics()
    )
    summary = report.summary()
    log.info(json.dumps({"mission": settings.mission, **summary}, default=str))
    return summary
