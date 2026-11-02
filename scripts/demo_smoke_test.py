#!/usr/bin/env python3
"""End-to-end smoke test for a SWxSOC mission pipeline, written for demo.

One synthetic L0 file is uploaded to the mission's incoming bucket. The script
then verifies, with a bounded wait at each stage, that:

1. the sorting Lambda copied it into the instrument bucket,
2. the processing Lambda produced a higher-level output next to it,
3. a Timestream record names the file (sorting and artifacts both log one),
4. the MetaTracker database has a row for it (needs a network path to RDS,
   so it is skipped with ``--skip-rds`` where there is none),
5. a Mattermost post mentions it (``--skip-mattermost`` to leave it out).

Every object the run created is deleted afterwards unless ``--keep`` is given.
A missing stage is a failure, never a skip: the exit status is non-zero when
any check fails. ``--dry-run`` only resolves names and confirms access.

Credentials come from the ambient AWS session (CodeBuild role or a profile).
Run ``python scripts/demo_smoke_test.py --help`` for the options.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Callable

import boto3
from botocore.exceptions import BotoCoreError, ClientError

DEFAULT_MATTERMOST_URL = "https://mm.sciencecloud.nasa.gov:443"
PLACEHOLDER_BODY = b"SWxSOC pipeline smoke test placeholder\n"


@dataclass
class Target:
    """Everything the checks need to know about one mission workspace."""

    mission: str
    instrument: str
    environment: str
    level: str
    region: str
    incoming_bucket: str
    mattermost_url: str

    @property
    def prefix(self) -> str:
        return "" if self.environment == "prod" else "dev-"

    @property
    def mission_slug(self) -> str:
        return self.mission.replace("_", "-")

    @property
    def instrument_bucket(self) -> str:
        return f"{self.prefix}{self.mission_slug}-{self.instrument}"

    @property
    def timestream_database(self) -> str:
        return f"{self.prefix}{self.mission}_sdc_aws_logs"

    @property
    def timestream_table(self) -> str:
        return f"{self.prefix}{self.mission}_sdc_aws_s3_bucket_log_table"

    @property
    def rds_secret(self) -> str:
        return f"swxsoc/{self.environment}/{self.mission_slug}/processing/rds"

    @property
    def mattermost_secret(self) -> str:
        return (
            f"swxsoc/{self.environment}/{self.mission_slug}/communications/mattermost"
        )

    @property
    def metatracker_table(self) -> str:
        return f"{self.mission}_science_file"

    def filename(self, stamp: str) -> str:
        # The swxsoc standard format with no mode or descriptor:
        # {mission}_{instrument}_{level}_{time}_v{version}.cdf
        return f"{self.mission}_{self.instrument}_{self.level}_{stamp}_v0.0.1.cdf"


@dataclass
class Result:
    name: str
    status: str
    detail: str
    seconds: float


@dataclass
class Report:
    results: list[Result] = field(default_factory=list)

    def record(self, name: str, status: str, detail: str, started: float) -> None:
        result = Result(name, status, detail, time.monotonic() - started)
        self.results.append(result)
        print(f"[{result.status:4}] {name}: {detail} ({result.seconds:.0f}s)")

    @property
    def failed(self) -> bool:
        return any(result.status == "FAIL" for result in self.results)

    def summary(self) -> str:
        width = max(len(result.name) for result in self.results)
        lines = ["", "Smoke test summary", "-" * (width + 24)]
        for result in self.results:
            lines.append(
                f"{result.name:<{width}}  {result.status:<4}  {result.seconds:6.0f}s"
            )
        lines.append("")
        lines.append("RESULT: " + ("FAIL" if self.failed else "PASS"))
        return "\n".join(lines)


def wait_for(
    condition: Callable[[], str | None], timeout: float, interval: float
) -> str | None:
    """Poll ``condition`` until it returns a non-empty detail or time runs out."""
    deadline = time.monotonic() + timeout
    while True:
        detail = condition()
        if detail:
            return detail
        if time.monotonic() >= deadline:
            return None
        time.sleep(interval)


def list_recent_objects(s3, bucket: str, since: datetime) -> list[dict]:
    """Return objects in ``bucket`` modified at or after ``since``."""
    recent: list[dict] = []
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket):
        for obj in page.get("Contents", []):
            if obj["LastModified"] >= since:
                recent.append(obj)
    return recent


def basename(key: str) -> str:
    return key.rsplit("/", 1)[-1]


class SmokeTest:
    def __init__(self, target: Target, args: argparse.Namespace) -> None:
        self.target = target
        self.args = args
        self.report = Report()
        session = boto3.session.Session(region_name=target.region)
        self.s3 = session.client("s3")
        self.timestream = session.client("timestream-query")
        self.secrets = session.client("secretsmanager")
        # Allow a minute of clock skew between this host and S3.
        self.started_at = datetime.now(timezone.utc) - timedelta(seconds=60)
        self.stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")
        self.filename = target.filename(self.stamp)
        self.stem = self.filename.rsplit(".", 1)[0]
        self.created: list[tuple[str, str]] = []

    # -- stages ------------------------------------------------------------

    def upload(self) -> None:
        started = time.monotonic()
        try:
            self.s3.put_object(
                Bucket=self.target.incoming_bucket,
                Key=self.filename,
                Body=PLACEHOLDER_BODY,
                Metadata={"swxsoc-smoke-test": self.stamp},
            )
        except (ClientError, BotoCoreError) as error:
            self.report.record("upload", "FAIL", str(error), started)
            return
        self.created.append((self.target.incoming_bucket, self.filename))
        self.report.record(
            "upload",
            "PASS",
            f"s3://{self.target.incoming_bucket}/{self.filename}",
            started,
        )

    def sorted_copy(self) -> None:
        started = time.monotonic()

        def found() -> str | None:
            for obj in list_recent_objects(
                self.s3, self.target.instrument_bucket, self.started_at
            ):
                if basename(obj["Key"]) == self.filename:
                    self.created.append((self.target.instrument_bucket, obj["Key"]))
                    return f"s3://{self.target.instrument_bucket}/{obj['Key']}"
            return None

        detail = wait_for(found, self.args.timeout, self.args.poll_interval)
        if detail:
            self.report.record("sorted", "PASS", detail, started)
        else:
            self.report.record(
                "sorted",
                "FAIL",
                f"{self.filename} did not appear in {self.target.instrument_bucket}",
                started,
            )

    def processed_output(self) -> None:
        started = time.monotonic()

        def found() -> str | None:
            outputs = [
                obj["Key"]
                for obj in list_recent_objects(
                    self.s3, self.target.instrument_bucket, self.started_at
                )
                if basename(obj["Key"]) != self.filename
                and self.stamp in basename(obj["Key"])
                and f"_{self.target.level}_" not in basename(obj["Key"])
            ]
            if outputs:
                self.created.extend(
                    (self.target.instrument_bucket, key) for key in outputs
                )
                return ", ".join(sorted(outputs))
            return None

        detail = wait_for(found, self.args.timeout, self.args.poll_interval)
        if detail:
            self.report.record("processed", "PASS", detail, started)
        else:
            self.report.record(
                "processed",
                "FAIL",
                "no higher-level output for "
                f"{self.filename} in {self.target.instrument_bucket}; "
                "check the processing Lambda log and the instrument package",
                started,
            )

    def timestream_record(self) -> None:
        started = time.monotonic()
        query = (
            f'SELECT COUNT(*) AS n FROM "{self.target.timestream_database}".'
            f'"{self.target.timestream_table}" WHERE time > ago(2h) AND '
            f"(file_key LIKE '%{self.filename}%' OR new_file_key LIKE "
            f"'%{self.filename}%')"
        )

        def found() -> str | None:
            response = self.timestream.query(QueryString=query)
            count = int(response["Rows"][0]["Data"][0]["ScalarValue"])
            return f"{count} record(s) name the file" if count else None

        try:
            detail = wait_for(found, self.args.timeout, self.args.poll_interval)
        except (ClientError, BotoCoreError) as error:
            self.report.record("timestream", "FAIL", str(error), started)
            return
        if detail:
            self.report.record("timestream", "PASS", detail, started)
        else:
            self.report.record(
                "timestream",
                "FAIL",
                f"no record in {self.target.timestream_database}."
                f"{self.target.timestream_table}",
                started,
            )

    def metatracker_row(self) -> None:
        started = time.monotonic()
        if self.args.skip_rds:
            self.report.record("metatracker", "SKIP", "--skip-rds", started)
            return
        try:
            import psycopg2  # noqa: PLC0415 - optional, only needed for this check
        except ImportError:
            self.report.record(
                "metatracker", "FAIL", "psycopg2 is not installed", started
            )
            return
        try:
            credentials = self.secret_json(self.target.rds_secret)
            connection = psycopg2.connect(
                host=credentials["host"],
                port=int(credentials["port"]),
                dbname=credentials["dbname"],
                user=credentials["username"],
                password=credentials["password"],
                sslmode="require",
                connect_timeout=15,
            )
        except (ClientError, BotoCoreError, KeyError, Exception) as error:
            self.report.record("metatracker", "FAIL", str(error), started)
            return

        query = (
            f'SELECT filename, s3_key FROM "{self.target.metatracker_table}" '
            "WHERE filename = %s OR s3_key LIKE %s"
        )

        def found() -> str | None:
            with connection.cursor() as cursor:
                cursor.execute(query, (self.stem, f"%{self.filename}%"))
                rows = cursor.fetchall()
            connection.rollback()
            return (
                f"{len(rows)} row(s) in {self.target.metatracker_table}"
                if rows
                else None
            )

        try:
            detail = wait_for(found, self.args.timeout, self.args.poll_interval)
        except Exception as error:  # psycopg2 errors are not BotoCore errors
            self.report.record("metatracker", "FAIL", str(error), started)
            return
        finally:
            connection.close()
        if detail:
            self.report.record("metatracker", "PASS", detail, started)
        else:
            self.report.record(
                "metatracker",
                "FAIL",
                f"no row for {self.stem} in {self.target.metatracker_table}",
                started,
            )

    def mattermost_post(self) -> None:
        started = time.monotonic()
        if self.args.skip_mattermost:
            self.report.record("mattermost", "SKIP", "--skip-mattermost", started)
            return
        try:
            credentials = self.secret_json(self.target.mattermost_secret)
            token, channel_id = credentials["token"], credentials["channel_id"]
        except (ClientError, BotoCoreError, KeyError) as error:
            self.report.record("mattermost", "FAIL", str(error), started)
            return
        since_ms = int(self.started_at.timestamp() * 1000)
        url = (
            f"{self.target.mattermost_url.rstrip('/')}/api/v4/channels/"
            f"{urllib.parse.quote(channel_id)}/posts?since={since_ms}"
        )

        def found() -> str | None:
            request = urllib.request.Request(
                url, headers={"Authorization": f"Bearer {token}"}
            )
            with urllib.request.urlopen(request, timeout=30) as response:
                posts = json.load(response).get("posts", {})
            matches = [
                post
                for post in posts.values()
                if self.filename in post.get("message", "")
            ]
            return f"{len(matches)} post(s) mention the file" if matches else None

        try:
            detail = wait_for(found, self.args.timeout, self.args.poll_interval)
        except Exception as error:  # urllib raises several unrelated types
            self.report.record("mattermost", "FAIL", str(error), started)
            return
        if detail:
            self.report.record("mattermost", "PASS", detail, started)
        else:
            self.report.record(
                "mattermost", "FAIL", "no post mentions the file", started
            )

    def cleanup(self) -> None:
        started = time.monotonic()
        if self.args.keep:
            self.report.record("cleanup", "SKIP", "--keep", started)
            return
        deleted, errors = [], []
        for bucket, key in dict.fromkeys(self.created):
            try:
                self.s3.delete_object(Bucket=bucket, Key=key)
                deleted.append(f"s3://{bucket}/{key}")
            except (ClientError, BotoCoreError) as error:
                errors.append(f"s3://{bucket}/{key}: {error}")
        if errors:
            self.report.record("cleanup", "FAIL", "; ".join(errors), started)
        else:
            self.report.record(
                "cleanup", "PASS", f"deleted {len(deleted)} object(s)", started
            )

    # -- helpers -----------------------------------------------------------

    def secret_json(self, name: str) -> dict:
        response = self.secrets.get_secret_value(SecretId=name)
        return json.loads(response["SecretString"])

    def dry_run(self) -> None:
        """Resolve every name and confirm read access without writing anything."""
        checks: list[tuple[str, Callable[[], str]]] = [
            (
                "incoming bucket",
                lambda: (
                    self.s3.head_bucket(Bucket=self.target.incoming_bucket)
                    and self.target.incoming_bucket
                ),
            ),
            (
                "instrument bucket",
                lambda: (
                    self.s3.head_bucket(Bucket=self.target.instrument_bucket)
                    and self.target.instrument_bucket
                ),
            ),
            (
                "timestream table",
                lambda: (
                    self.timestream.query(
                        QueryString=(
                            f'SELECT COUNT(*) FROM "{self.target.timestream_database}".'
                            f'"{self.target.timestream_table}" WHERE time > ago(1m)'
                        )
                    )
                    and f"{self.target.timestream_database}.{self.target.timestream_table}"
                ),
            ),
            (
                "mattermost secret",
                lambda: self.secrets.describe_secret(
                    SecretId=self.target.mattermost_secret
                )["Name"],
            ),
        ]
        if not self.args.skip_rds:
            checks.append(
                (
                    "rds secret",
                    lambda: self.secrets.describe_secret(
                        SecretId=self.target.rds_secret
                    )["Name"],
                )
            )
        for name, check in checks:
            started = time.monotonic()
            try:
                self.report.record(name, "PASS", check(), started)
            except (ClientError, BotoCoreError) as error:
                self.report.record(name, "FAIL", str(error), started)
        print(f"would upload {self.filename}")

    def run(self) -> None:
        print(
            f"Smoke test for {self.target.mission} ({self.target.environment}): "
            f"{self.filename}"
        )
        if self.args.dry_run:
            self.dry_run()
            return
        self.upload()
        if self.report.failed:
            return
        self.sorted_copy()
        self.processed_output()
        self.timestream_record()
        self.metatracker_row()
        self.mattermost_post()
        self.cleanup()


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--mission", default=os.environ.get("SWXSOC_MISSION", "demo"))
    parser.add_argument(
        "--instrument", default=os.environ.get("SMOKE_TEST_INSTRUMENT", "craft")
    )
    parser.add_argument("--environment", choices=["dev", "prod"], default="dev")
    parser.add_argument("--level", default="l0", help="data level of the input")
    parser.add_argument(
        "--incoming-bucket",
        help="defaults to <prefix><mission>-swsoc-incoming",
    )
    parser.add_argument(
        "--region",
        default=os.environ.get(
            "AWS_REGION", os.environ.get("AWS_DEFAULT_REGION", "us-east-1")
        ),
    )
    parser.add_argument(
        "--mattermost-url",
        default=os.environ.get("MATTERMOST_URL", DEFAULT_MATTERMOST_URL),
    )
    parser.add_argument(
        "--timeout", type=float, default=600, help="seconds to wait per stage"
    )
    parser.add_argument("--poll-interval", type=float, default=15)
    parser.add_argument("--skip-rds", action="store_true")
    parser.add_argument("--skip-mattermost", action="store_true")
    parser.add_argument(
        "--keep", action="store_true", help="leave the created objects in place"
    )
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    prefix = "" if args.environment == "prod" else "dev-"
    target = Target(
        mission=args.mission,
        instrument=args.instrument,
        environment=args.environment,
        level=args.level,
        region=args.region,
        incoming_bucket=args.incoming_bucket
        or f"{prefix}{args.mission.replace('_', '-')}-swsoc-incoming",
        mattermost_url=args.mattermost_url,
    )
    test = SmokeTest(target, args)
    test.run()
    print(test.report.summary())
    return 1 if test.report.failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
