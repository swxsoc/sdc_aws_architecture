"""Unit tests for the pipeline status widget; no AWS access needed."""

from __future__ import annotations

import datetime as dt
import json
import unittest

import widget

NOW = dt.datetime(2026, 11, 18, 18, 40, tzinfo=dt.UTC)
ACCOUNT = "123456789012"
REGION = "us-east-1"


def hours_ago(hours: float) -> dt.datetime:
    return NOW - dt.timedelta(hours=hours)


def crossed(value: float, threshold: float = 0.0) -> str:
    """A CloudWatch 'Threshold Crossed' reason with one datapoint."""
    return (
        f"Threshold Crossed: 1 out of the last 1 datapoints [{value} "
        f"(18/11/26 14:05:00)] was greater than the threshold ({threshold}) "
        "(minimum 1 datapoint for OK -> ALARM transition)."
    )


def alarm(name, state="OK", reason="", updated=None, **extra):
    record = {
        "AlarmName": name,
        "AlarmArn": f"arn:aws:cloudwatch:{REGION}:{ACCOUNT}:alarm:{name}",
        "StateValue": state,
        "StateReason": reason,
        "StateUpdatedTimestamp": updated or hours_ago(48),
        "Period": 300,
        "Threshold": 0.0,
    }
    record.update(extra)
    return record


def history(name, new_state, when, old_state="OK", reason=""):
    return {
        "AlarmName": name,
        "Timestamp": when,
        "HistoryItemType": "StateUpdate",
        "HistoryData": json.dumps(
            {
                "newState": {"stateValue": new_state, "stateReason": reason},
                "oldState": {"stateValue": old_state},
            }
        ),
    }


LAMBDA_KINDS = ("errors", "throttles", "duration", "log-errors")


def workspace_alarms(prefix, instruments=("craft",), concating=False, **overrides):
    """A full set of pipeline health alarms for one workspace, all OK.

    ``prefix`` is ``<env><slug>-pipeline-``. Dimensions, descriptions and
    thresholds follow pipeline_health.tf so link building can be tested.
    """
    base = prefix[: -len("pipeline-")]  # "<env><slug>-"
    function_stem = base[:-1].replace("-", "_")
    records = []

    def add(suffix, **fields):
        spec = dict(fields)
        spec.update(overrides.get(suffix.replace("-", "_"), {}))
        records.append(alarm(f"{prefix}{suffix}", **spec))

    stages = ["sorting", "processing", "artifacts"] + (
        ["concating"] if concating else []
    )
    for stage in stages:
        function = f"{function_stem}_sdc_aws_{stage}_lambda_function"
        for kind in LAMBDA_KINDS:
            fields = {
                "AlarmDescription": f"The {stage} Lambda of {base[:-1]} reported {kind}.",
            }
            if kind != "log-errors":
                fields["Dimensions"] = [{"Name": "FunctionName", "Value": function}]
            if kind == "duration":
                fields["Threshold"] = 810000.0
            add(f"{stage}-{kind}", **fields)
    for instrument in instruments:
        add(
            f"{instrument}-topic-delivery-failures",
            Dimensions=[
                {"Name": "TopicName", "Value": f"{base}{instrument}-sns-topic"}
            ],
            AlarmDescription=f"SNS could not deliver a {base}{instrument} notification.",
        )
        add(
            f"{instrument}-queue-age",
            Dimensions=[
                {"Name": "QueueName", "Value": f"{base}{instrument}-sqs-queue"}
            ],
            Threshold=3600.0,
            AlarmDescription=f"The oldest message in the {base}{instrument} queue is old.",
        )
    for suffix in (
        "unsorted-incoming-objects",
        "missing-metatracker-rows",
        "missing-timestream-records",
        "reconciliation-check-errors",
    ):
        # Only the unsorted-objects alarm names the bucket, as pipeline_health.tf does.
        where = f" in bucket {base}incoming" if suffix.startswith("unsorted") else ""
        add(
            suffix,
            Period=3600,
            AlarmDescription=(
                f"The last run reported {suffix} > 0{where}; the run's log entry "
                "lists the keys."
            ),
        )
    add("reconciliation-not-running", Period=3600, Threshold=1.0)
    add(
        "reconciliation-errors",
        Period=3600,
        Dimensions=[
            {
                "Name": "FunctionName",
                "Value": f"{function_stem}_pipeline_reconciliation",
            }
        ],
    )
    add("unhealthy")
    return records


SAMPLE_ALARMS = (
    workspace_alarms(
        "padre-pipeline-",
        instruments=("meddea", "sharp"),
        concating=True,
        processing_log_errors={
            "state": "ALARM",
            "reason": crossed(2.0),
            "updated": hours_ago(4.5),
        },
    )
    + workspace_alarms(
        "hermes-pipeline-",
        unsorted_incoming_objects={
            "state": "ALARM",
            "reason": crossed(3612.0),
            "updated": NOW - dt.timedelta(days=8),
            # HERMES lands in a bucket whose name does not follow the mission's.
            "AlarmDescription": (
                "The last hermes reconciliation run reported UnsortedIncomingObjects "
                "> 0 in bucket swsoc-incoming; the run's log entry lists the keys."
            ),
        },
        craft_queue_age={
            "state": "ALARM",
            "reason": crossed(9000.0, 3600.0),
            "updated": hours_ago(2),
        },
    )
    + workspace_alarms("impax-pipeline-")
    + workspace_alarms(
        "gdctb-pipeline-",
        missing_metatracker_rows={"state": "INSUFFICIENT_DATA"},
        missing_timestream_records={"state": "INSUFFICIENT_DATA"},
        reconciliation_check_errors={"state": "INSUFFICIENT_DATA"},
        reconciliation_not_running={"state": "INSUFFICIENT_DATA"},
        reconciliation_errors={"state": "INSUFFICIENT_DATA"},
        unsorted_incoming_objects={"state": "INSUFFICIENT_DATA"},
    )
    + workspace_alarms("swxsoc-pipeline-pipeline-")
    + workspace_alarms("dev-demo-pipeline-")
    + [alarm("unrelated-alarm", "ALARM"), alarm("padre-pipeline-unhealthy", "ALARM")]
)

SAMPLE_HISTORY = [
    history(
        "padre-pipeline-processing-log-errors",
        "ALARM",
        hours_ago(4.5),
        reason=crossed(2.0),
    ),
    history(
        "padre-pipeline-missing-metatracker-rows",
        "ALARM",
        hours_ago(81.5),
        reason=crossed(4.0),
    ),
    history("padre-pipeline-missing-metatracker-rows", "OK", hours_ago(80.6), "ALARM"),
    history("impax-pipeline-reconciliation-not-running", "ALARM", hours_ago(130)),
    history(
        "impax-pipeline-reconciliation-not-running", "OK", hours_ago(129.5), "ALARM"
    ),
    history(
        "hermes-pipeline-craft-queue-age",
        "ALARM",
        hours_ago(2),
        reason=crossed(9000.0, 3600.0),
    ),
    # OK without a preceding ALARM in the window: ignored.
    history("impax-pipeline-sorting-errors", "OK", hours_ago(200), "ALARM"),
    # Composite alarms are not part of the event list.
    history("padre-pipeline-unhealthy", "ALARM", hours_ago(4.5)),
]


# Latest health-check counts per namespace: what GetMetricData returns, as
# (IncomingObjectsInWindow, ReconciledObjects, MissingMetaTrackerRows,
# MissingTimestreamRecords, FailedProcessingFiles). GDC-Trailblazer has not
# published yet, so it has no entry.
SAMPLE_COUNTS = {
    "SWxSOC/Pipeline/prod-padre": (142, 140, 0, 0, 2),
    "SWxSOC/Pipeline/prod-hermes": (0, 0, 0, 0, 0),
    "SWxSOC/Pipeline/prod-impax": (1, 1, 1, 0, 0),
    "SWxSOC/Pipeline/prod-swxsoc-pipeline": (3612, 3612, 0, 0, 0),
    "SWxSOC/Pipeline/dev-demo": (5, 5, 0, 0, 1),
}
COUNT_METRIC_ORDER = (
    "IncomingObjectsInWindow",
    "ReconciledObjects",
    "MissingMetaTrackerRows",
    "MissingTimestreamRecords",
    "FailedProcessingFiles",
)


def metric_data_results(queries, counts=SAMPLE_COUNTS):
    """MetricDataResults for ``queries``: newest first, empty when unpublished."""
    results = []
    for query in queries:
        metric = query["MetricStat"]["Metric"]
        values = counts.get(metric["Namespace"])
        if values is None:
            results.append(
                {
                    "Id": query["Id"],
                    "Timestamps": [],
                    "Values": [],
                    "StatusCode": "Complete",
                }
            )
            continue
        value = float(values[COUNT_METRIC_ORDER.index(metric["MetricName"])])
        results.append(
            {
                "Id": query["Id"],
                "Label": metric["MetricName"],
                # Two periods of data, newest first, as ScanBy=TimestampDescending gives.
                "Timestamps": [hours_ago(0.5), hours_ago(1.5)],
                "Values": [value, value + 1000],
                "StatusCode": "Complete",
            }
        )
    return results


class FakePaginator:
    def __init__(self, pages):
        self.pages = pages
        self.calls = []

    def paginate(self, **kwargs):
        self.calls.append(kwargs)
        return iter(self.pages)


class FakeCloudWatch:
    def __init__(
        self, alarms=SAMPLE_ALARMS, history_items=SAMPLE_HISTORY, counts=SAMPLE_COUNTS
    ):
        self.counts = counts
        self.metric_calls = []
        metric = [a for a in alarms if not a["AlarmName"].endswith("unhealthy")]
        composite = [a for a in alarms if a["AlarmName"].endswith("unhealthy")]
        self.paginators = {
            "describe_alarms": FakePaginator(
                [
                    {"MetricAlarms": metric[:10]},
                    {"MetricAlarms": metric[10:], "CompositeAlarms": composite},
                ]
            ),
            "describe_alarm_history": FakePaginator(
                [{"AlarmHistoryItems": history_items}]
            ),
        }

    def get_paginator(self, name):
        return self.paginators[name]

    def get_metric_data(self, **kwargs):
        self.metric_calls.append(kwargs)
        if self.counts is None:
            raise RuntimeError("AccessDenied: not authorized to GetMetricData")
        return {
            "MetricDataResults": metric_data_results(
                kwargs["MetricDataQueries"], self.counts
            )
        }


class BrokenCloudWatch:
    def get_paginator(self, name):
        raise RuntimeError("AccessDenied: not authorized to DescribeAlarms")


def snapshot(environment="prod", client=None):
    client = client or FakeCloudWatch()
    settings = widget.Settings(REGION, REGION, 14)
    return widget.collect(client, environment, settings, NOW)


def mission(snap, name):
    return next(m for m in snap.missions if m.workspace.name == name)


def stage(mission_, key):
    return next(s for s in mission_.stages if s.key == key)


def links_for(alarm_, mission_, start=None, end=None):
    start = start or alarm_.updated
    return {
        link.label: link
        for link in widget.evidence_links(alarm_, mission_, REGION, start, end)
    }


class DiscoveryTests(unittest.TestCase):
    def test_workspaces_from_composite_alarms(self):
        found = widget.discover_workspaces(
            [
                "padre-pipeline-unhealthy",
                "dev-padre-pipeline-unhealthy",
                "swxsoc-pipeline-pipeline-unhealthy",
                "padre-pipeline-sorting-errors",
                "-pipeline-unhealthy",
                "dev--pipeline-unhealthy",
            ]
        )
        self.assertEqual(
            [(w.environment, w.slug) for w in found],
            [("dev", "padre"), ("prod", "padre"), ("prod", "swxsoc-pipeline")],
        )
        self.assertEqual(found[1].prefix, "padre-pipeline-")
        self.assertEqual(found[1].dashboard_name, "padre-pipeline")
        self.assertEqual(found[0].prefix, "dev-padre-pipeline-")

    def test_display_names(self):
        self.assertEqual(widget.Workspace("prod", "gdctb").name, "GDC-Trailblazer")
        self.assertEqual(
            widget.Workspace("prod", "swxsoc-pipeline").name, "SWxSOC Pipeline"
        )
        self.assertEqual(widget.Workspace("dev", "new-mission").name, "New Mission")


class ClassificationTests(unittest.TestCase):
    workspace = widget.Workspace("prod", "padre")

    def check(self, suffix, stage_key, severity):
        self.assertEqual(
            widget.classify(f"padre-pipeline-{suffix}", self.workspace),
            (stage_key, severity),
            suffix,
        )

    def test_every_alarm_kind(self):
        self.check("unsorted-incoming-objects", "landing", "outage")
        for kind in LAMBDA_KINDS:
            self.check(f"sorting-{kind}", "sorting", "issue")
            self.check(f"processing-{kind}", "processing", "issue")
            self.check(f"artifacts-{kind}", "artifacts", "issue")
            self.check(f"concating-{kind}", "concating", "issue")
        self.check("meddea-topic-delivery-failures", "notification", "outage")
        # The queue is drained by an external consumer; SWxSOC processing runs
        # from the topic, so a full queue is not an outage.
        self.check("sharp-queue-age", "notification", "issue")
        self.check("missing-metatracker-rows", "processing", "outage")
        self.check("missing-timestream-records", "artifacts", "outage")
        self.check("reconciliation-not-running", "reconciliation", "issue")
        self.check("reconciliation-errors", "reconciliation", "issue")
        self.check("reconciliation-check-errors", "reconciliation", "issue")

    def test_unknown_and_foreign_alarms(self):
        self.assertIsNone(widget.classify("padre-pipeline-unhealthy", self.workspace))
        self.assertIsNone(
            widget.classify("padre-pipeline-something-new", self.workspace)
        )
        self.assertIsNone(
            widget.classify("dev-padre-pipeline-sorting-errors", self.workspace)
        )
        self.assertIsNone(
            widget.classify("hermes-pipeline-sorting-errors", self.workspace)
        )

    def test_headlines_fill_stage_and_instrument(self):
        snap = snapshot()
        (queue,) = stage(mission(snap, "HERMES"), "notification").firing
        self.assertEqual(
            widget.headline(queue), "The CRAFT download queue is not being emptied"
        )
        (logs,) = stage(mission(snap, "PADRE"), "processing").firing
        self.assertEqual(
            widget.headline(logs), "Processing failed on some files, data still flowing"
        )


class StatusTests(unittest.TestCase):
    def test_stage_status_precedence(self):
        issue = widget.Alarm("a", "ALARM", severity="issue")
        outage = widget.Alarm("b", "ALARM", severity="outage")
        ok = widget.Alarm("c", "OK")
        nodata = widget.Alarm("d", "INSUFFICIENT_DATA")
        self.assertEqual(widget.stage_status([]), "off")
        self.assertEqual(widget.stage_status([ok, nodata]), "available")
        self.assertEqual(widget.stage_status([nodata, nodata]), "nodata")
        self.assertEqual(widget.stage_status([ok, issue]), "issue")
        self.assertEqual(widget.stage_status([issue, outage, nodata]), "outage")

    def test_missions_sorted_by_severity_and_not_checked_does_not_count(self):
        snap = snapshot()
        self.assertEqual(
            [(m.workspace.name, m.status) for m in snap.missions],
            [
                ("HERMES", "outage"),
                ("PADRE", "issue"),
                ("GDC-Trailblazer", "available"),
                ("iMPAX", "available"),
                ("SWxSOC Pipeline", "available"),
            ],
        )
        gdctb = mission(snap, "GDC-Trailblazer")
        self.assertEqual(stage(gdctb, "landing").status, "nodata")
        self.assertEqual(stage(gdctb, "reconciliation").status, "nodata")
        self.assertEqual(stage(gdctb, "processing").status, "available")
        self.assertEqual(
            widget.mission_subtitle(gdctb, NOW),
            "Data flowing normally · 2 checks not active yet",
        )
        padre = mission(snap, "PADRE")
        self.assertEqual(stage(padre, "processing").since, hours_ago(4.5))
        self.assertEqual(stage(padre, "concating").status, "available")
        self.assertEqual(stage(mission(snap, "iMPAX"), "concating").status, "off")
        hermes = mission(snap, "HERMES")
        self.assertEqual(stage(hermes, "landing").status, "outage")
        self.assertEqual(stage(hermes, "notification").status, "issue")
        self.assertEqual(hermes.since, NOW - dt.timedelta(days=8))

    def test_mission_status_rules(self):
        info = widget.STAGE_BY_KEY
        self.assertEqual(
            widget.mission_status(
                [
                    widget.Stage(info["sorting"], "available"),
                    widget.Stage(info["landing"], "nodata"),
                ]
            ),
            "available",
        )
        self.assertEqual(
            widget.mission_status(
                [
                    widget.Stage(info["sorting"], "nodata"),
                    widget.Stage(info["concating"], "off"),
                ]
            ),
            "nodata",
        )
        self.assertEqual(
            widget.mission_status([widget.Stage(info["concating"], "off")]), "off"
        )

    def test_mission_functions_come_from_dimensions(self):
        padre = mission(snapshot(), "PADRE")
        self.assertEqual(
            padre.functions["processing"], "padre_sdc_aws_processing_lambda_function"
        )
        self.assertEqual(
            padre.functions["reconciliation"], "padre_pipeline_reconciliation"
        )

    def test_dev_environment_is_separate(self):
        snap = snapshot("dev")
        self.assertEqual([m.workspace.name for m in snap.missions], ["Demo"])
        self.assertEqual(snap.missions[0].status, "available")


class WordsTests(unittest.TestCase):
    def test_verdict(self):
        self.assertEqual(
            widget.verdict(snapshot()),
            "HERMES has not been getting data through for 8 days. "
            "PADRE has errors (data still flowing) for 4 h 30 min. "
            "GDC-Trailblazer, iMPAX and SWxSOC Pipeline are fine.",
        )
        self.assertEqual(
            widget.verdict(snapshot("dev")), "Demo is receiving and processing data."
        )

    def test_mission_subtitles(self):
        snap = snapshot()
        self.assertEqual(
            widget.mission_subtitle(mission(snap, "HERMES"), NOW),
            "Outage · Files arrived but were not sorted into instrument buckets "
            "· 8 days · +1 more",
        )
        self.assertEqual(
            widget.mission_subtitle(mission(snap, "PADRE"), NOW),
            "Issue · Processing failed on some files, data still flowing · 4 h 30 min",
        )
        self.assertEqual(
            widget.mission_subtitle(mission(snap, "iMPAX"), NOW),
            "Data flowing normally",
        )

    def test_measure_reads_the_datapoint(self):
        snap = snapshot()
        hermes = mission(snap, "HERMES")
        (unsorted,) = stage(hermes, "landing").firing
        self.assertEqual(widget.measure(unsorted), "3,612 files")
        (queue,) = stage(hermes, "notification").firing
        self.assertEqual(widget.measure(queue), "waiting 2.5 h")
        (logs,) = stage(mission(snap, "PADRE"), "processing").firing
        self.assertEqual(widget.measure(logs), "2 in the last 5 min")
        duration_kind = next(
            k for k in widget.ALARM_KINDS if k.pattern.pattern.endswith("-duration$")
        )
        duration = widget.Alarm(
            "padre-pipeline-sorting-duration",
            "ALARM",
            crossed(812345.0, 810000.0),
            threshold=810000.0,
            kind=duration_kind,
            stage="sorting",
        )
        self.assertEqual(widget.measure(duration), "ran 812 s, alarm line 810 s")
        # Hand-written reasons pass through; threshold text with no datapoint hides.
        unsorted.reason = "3612 objects remain after the sorting sweep."
        self.assertEqual(widget.measure(unsorted), unsorted.reason)
        unsorted.reason = "Threshold Crossed: no datapoints were received"
        self.assertEqual(widget.measure(unsorted), "")

    def test_durations(self):
        self.assertEqual(widget._ago(NOW - dt.timedelta(seconds=30), NOW), "just now")
        self.assertEqual(widget._ago(NOW - dt.timedelta(minutes=35), NOW), "35 min")
        self.assertEqual(widget._ago(hours_ago(4.5), NOW), "4 h 30 min")
        self.assertEqual(widget._ago(hours_ago(4), NOW), "4 h")
        self.assertEqual(widget._ago(hours_ago(20), NOW), "20 h")
        self.assertEqual(widget._ago(hours_ago(24 * 8), NOW), "8 days")
        self.assertEqual(widget._ago(hours_ago(30), NOW), "30 h")
        self.assertEqual(widget._ago(hours_ago(40), NOW), "2 days")
        self.assertEqual(widget._lasted(hours_ago(81.5), hours_ago(80.6)), "54 min")
        self.assertEqual(widget._lasted(hours_ago(5), hours_ago(2.5)), "2 h 30 min")
        self.assertEqual(widget._lasted(hours_ago(100), NOW), "4 days")
        self.assertEqual(widget._when(hours_ago(4.5), NOW), "Nov 18, 14:10 UTC")
        self.assertEqual(
            widget._when(dt.datetime(2025, 12, 31, 23, 0, tzinfo=dt.UTC), NOW),
            "Dec 31 2025, 23:00 UTC",
        )


class LinkTests(unittest.TestCase):
    def test_log_errors_link_uses_sibling_function_and_metric_filter_pattern(self):
        snap = snapshot()
        padre = mission(snap, "PADRE")
        (logs,) = stage(padre, "processing").firing
        links = links_for(logs, padre)
        log = links["Processing log (errors only)"]
        self.assertTrue(
            log.url.startswith(
                "https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1"
                "#logsV2:log-groups/log-group/$252Faws$252Flambda$252F"
                "padre_sdc_aws_processing_lambda_function/log-events$3FfilterPattern$3D"
            )
        )
        # ?"Error Processing Event" ?"'status': 'ERROR'" in the console's escaping
        self.assertIn("$253F$2522Error$2520Processing$2520Event$2522", log.url)
        start = int((hours_ago(4.5) - dt.timedelta(minutes=15)).timestamp() * 1000)
        self.assertIn(f"$26start$3D{start}", log.url)
        self.assertNotIn("end$3D", log.url)
        self.assertEqual(
            log.title, "/aws/lambda/padre_sdc_aws_processing_lambda_function"
        )
        self.assertEqual(
            links["Alarm"].url,
            "https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1"
            "#alarmsV2:alarm/padre-pipeline-processing-log-errors",
        )
        self.assertTrue(links["Alarm"].mono)

    def test_reconciliation_count_alarm_links_to_the_affected_keys(self):
        snap = snapshot()
        hermes = mission(snap, "HERMES")
        (unsorted,) = stage(hermes, "landing").firing
        log = links_for(unsorted, hermes)["List of affected files"]
        self.assertIn("$252Fhermes_pipeline_reconciliation/log-events", log.url)
        self.assertIn("filterPattern$3Daffected_keys$2520unsorted", log.url)
        # Three periods of lead time for an hourly check.
        start = int((unsorted.updated - dt.timedelta(hours=3)).timestamp() * 1000)
        self.assertIn(f"start$3D{start}", log.url)

    def test_unsorted_alarm_links_to_the_bucket_named_in_its_description(self):
        snap = snapshot()
        hermes = mission(snap, "HERMES")
        (unsorted,) = stage(hermes, "landing").firing
        links = links_for(unsorted, hermes)
        self.assertEqual(
            list(links), ["List of affected files", "Incoming bucket", "Alarm"]
        )
        self.assertEqual(
            links["Incoming bucket"].url,
            "https://s3.console.aws.amazon.com/s3/buckets/swsoc-incoming"
            "?region=us-east-1&tab=objects",
        )
        self.assertEqual(links["Incoming bucket"].title, "swsoc-incoming")
        # An older alarm whose description does not name the bucket gets no pill.
        unsorted.description = "The last run reported UnsortedIncomingObjects > 0."
        self.assertNotIn("Incoming bucket", links_for(unsorted, hermes))

    def test_bucket_in_description(self):
        for text, expected in (
            (
                "reported 3 > 0 in bucket padre-incoming; the log lists the keys.",
                "padre-incoming",
            ),
            ("Objects in bucket my.dotted-bucket.", "my.dotted-bucket"),
            ("in bucket swsoc-incoming", "swsoc-incoming"),
            ("no bucket here", ""),
            ("", ""),
        ):
            self.assertEqual(widget.bucket_in_description(text), expected, text)

    def test_queue_alarm_links_to_the_queue_and_not_to_logs(self):
        snap = snapshot()
        hermes = mission(snap, "HERMES")
        (queue,) = stage(hermes, "notification").firing
        links = links_for(queue, hermes)
        self.assertEqual(list(links), ["Queue", "Alarm"])
        self.assertEqual(
            links["Queue"].url,
            "https://us-east-1.console.aws.amazon.com/sqs/v3/home?region=us-east-1"
            "#/queues/https%3A%2F%2Fsqs.us-east-1.amazonaws.com%2F123456789012"
            "%2Fhermes-craft-sqs-queue",
        )

    def test_topic_alarm_links_to_topic_bucket_and_processing_log(self):
        alarms = workspace_alarms(
            "padre-pipeline-",
            instruments=("meddea",),
            meddea_topic_delivery_failures={
                "state": "ALARM",
                "reason": crossed(1.0),
                "updated": hours_ago(1),
            },
        )
        snap = snapshot(client=FakeCloudWatch(alarms=alarms, history_items=[]))
        padre = mission(snap, "PADRE")
        (topic,) = stage(padre, "notification").firing
        links = links_for(topic, padre)
        self.assertEqual(
            list(links),
            ["Processing log (errors only)", "Topic", "Instrument bucket", "Alarm"],
        )
        self.assertEqual(
            links["Topic"].url,
            "https://us-east-1.console.aws.amazon.com/sns/v3/home?region=us-east-1"
            "#/topic/arn:aws:sns:us-east-1:123456789012:padre-meddea-sns-topic",
        )
        self.assertEqual(
            links["Instrument bucket"].url,
            "https://s3.console.aws.amazon.com/s3/buckets/padre-meddea"
            "?region=us-east-1&tab=objects",
        )

    def test_throttles_link_to_lambda_monitoring(self):
        alarms = workspace_alarms(
            "padre-pipeline-",
            sorting_throttles={
                "state": "ALARM",
                "reason": crossed(3.0),
                "updated": hours_ago(1),
            },
        )
        snap = snapshot(client=FakeCloudWatch(alarms=alarms, history_items=[]))
        padre = mission(snap, "PADRE")
        (throttled,) = stage(padre, "sorting").firing
        links = links_for(throttled, padre)
        self.assertEqual(list(links), ["Lambda monitoring", "Alarm"])
        self.assertEqual(
            links["Lambda monitoring"].url,
            "https://us-east-1.console.aws.amazon.com/lambda/home?region=us-east-1"
            "#/functions/padre_sdc_aws_sorting_lambda_function?tab=monitoring",
        )

    def test_no_log_link_without_a_known_function(self):
        alarms = [
            a
            for a in workspace_alarms(
                "padre-pipeline-",
                unsorted_incoming_objects={
                    "state": "ALARM",
                    "reason": crossed(2.0),
                    "updated": hours_ago(1),
                },
            )
            if not a["AlarmName"].endswith("reconciliation-errors")
        ]
        snap = snapshot(client=FakeCloudWatch(alarms=alarms, history_items=[]))
        padre = mission(snap, "PADRE")
        (unsorted,) = stage(padre, "landing").firing
        # The bucket pill comes from the description, so it needs no function.
        self.assertEqual(list(links_for(unsorted, padre)), ["Incoming bucket", "Alarm"])

    def test_resolved_event_window_has_an_end(self):
        snap = snapshot()
        resolved = next(e for e in snap.events if not e.ongoing)
        links = links_for(
            resolved.alarm, resolved.mission, resolved.start, resolved.end
        )
        end = int((resolved.end + dt.timedelta(minutes=15)).timestamp() * 1000)
        self.assertIn(f"$26end$3D{end}", links["List of affected files"].url)


class CountsTests(unittest.TestCase):
    def test_one_batched_get_metric_data_call_per_environment(self):
        client = FakeCloudWatch()
        snap = snapshot(client=client)
        self.assertEqual(len(client.metric_calls), 1)
        call = client.metric_calls[0]
        queries = call["MetricDataQueries"]
        self.assertEqual(len(queries), 5 * len(snap.missions))
        self.assertEqual(len({q["Id"] for q in queries}), len(queries))
        for query in queries:
            self.assertRegex(query["Id"], r"^[a-z][a-zA-Z0-9_]*$")
            self.assertEqual(query["MetricStat"]["Stat"], "Maximum")
            self.assertEqual(query["MetricStat"]["Period"], 3600)  # the alarms' period
            self.assertTrue(query["ReturnData"])
        self.assertEqual(
            {q["MetricStat"]["Metric"]["Namespace"] for q in queries},
            {
                "SWxSOC/Pipeline/prod-padre",
                "SWxSOC/Pipeline/prod-hermes",
                "SWxSOC/Pipeline/prod-impax",
                "SWxSOC/Pipeline/prod-gdctb",
                "SWxSOC/Pipeline/prod-swxsoc-pipeline",
            },
        )
        self.assertEqual(
            {q["MetricStat"]["Metric"]["MetricName"] for q in queries},
            set(COUNT_METRIC_ORDER),
        )
        # Two reconciliation periods, newest datapoint first.
        self.assertEqual(call["StartTime"], NOW - dt.timedelta(hours=2))
        self.assertEqual(call["EndTime"], NOW)
        self.assertEqual(call["ScanBy"], "TimestampDescending")

    def test_dev_namespaces_carry_the_dev_prefix(self):
        client = FakeCloudWatch()
        snapshot("dev", client=client)
        (call,) = client.metric_calls
        self.assertEqual(
            {q["MetricStat"]["Metric"]["Namespace"] for q in call["MetricDataQueries"]},
            {"SWxSOC/Pipeline/dev-demo"},
        )

    def test_counts_are_parsed_per_mission_from_the_newest_datapoint(self):
        snap = snapshot()
        padre = mission(snap, "PADRE").counts
        self.assertEqual(
            (
                padre.arrived,
                padre.checked,
                padre.missing_metatracker,
                padre.missing_timestream,
                padre.failed,
            ),
            (142, 140, 0, 0, 2),
        )
        self.assertEqual(padre.missing, 0)
        self.assertEqual(mission(snap, "iMPAX").counts.missing, 1)
        # Never published: no counts at all, rather than zeros.
        self.assertIsNone(mission(snap, "GDC-Trailblazer").counts)

    def test_partial_results_leave_fields_none(self):
        workspace = widget.Workspace("prod", "padre")
        lookup = {
            "m0_arrived": (workspace, "arrived"),
            "m0_failed": (workspace, "failed"),
        }
        counts = widget.parse_counts(
            [
                {"Id": "m0_arrived", "Values": [7.0]},
                {"Id": "m0_failed", "Values": []},
                {"Id": "unknown", "Values": [1.0]},
            ],
            lookup,
        )
        self.assertEqual(counts[workspace].arrived, 7)
        self.assertIsNone(counts[workspace].failed)
        self.assertIsNone(counts[workspace].missing)
        self.assertEqual(widget.parse_counts([], lookup), {})

    def test_words(self):
        words = widget.counts_words(widget.Counts(142, 140, 0, 0, 2))
        self.assertEqual(
            [text for text, _ in words],
            [
                "142 files arrived",
                "140 checked",
                "0 missing records",
                "2 failed processing",
            ],
        )
        self.assertEqual([tip for _, tip in words], ["", "", "", ""])
        singular = widget.counts_words(widget.Counts(1, 1, 1, 0, 1))
        self.assertEqual(
            [text for text, _ in singular],
            ["1 file arrived", "1 checked", "1 missing record", "1 failed processing"],
        )
        quiet = widget.counts_words(widget.Counts(0, 0, 0, 0, 0))
        self.assertEqual(quiet[0], ("0 files arrived", widget.QUIET_DAY_NOTE))
        big = widget.counts_words(widget.Counts(3612, 3612, None, None, None))
        self.assertEqual(
            [text for text, _ in big], ["3,612 files arrived", "3,612 checked"]
        )

    def test_no_call_without_missions(self):
        client = FakeCloudWatch(alarms=[])
        snap = snapshot(client=client)
        self.assertEqual(snap.missions, [])
        self.assertEqual(client.metric_calls, [])

    def test_counts_failure_degrades_to_no_line(self):
        client = FakeCloudWatch(counts=None)
        snap = snapshot(client=client)
        self.assertEqual(len(snap.missions), 5)
        self.assertTrue(all(m.counts is None for m in snap.missions))
        page = widget.render(snap, "dark", REGION)
        self.assertNotIn("Last 24 h", page)
        self.assertIn("<h1>Production Pipeline Status</h1>", page)

    def test_missing_get_metric_data_permission_still_renders(self):
        class NoMetricData(FakeCloudWatch):
            def get_metric_data(self, **kwargs):
                raise PermissionError(
                    "not authorized to perform: cloudwatch:GetMetricData"
                )

        with self.assertLogs("status_widget", level="WARNING") as captured:
            snap = snapshot(client=NoMetricData())
        self.assertIn("daily counts unavailable", captured.output[0])
        self.assertIn(
            '<div class="gname">PADRE</div>', widget.render(snap, "dark", REGION)
        )


class HistoryTests(unittest.TestCase):
    def test_events_are_paired_and_ordered(self):
        snap = snapshot()
        described = [(e.alarm.name, e.ongoing, e.start, e.end) for e in snap.events]
        self.assertEqual(
            described,
            [
                ("hermes-pipeline-craft-queue-age", True, hours_ago(2), None),
                ("padre-pipeline-processing-log-errors", True, hours_ago(4.5), None),
                # In ALARM for longer than the history window: ongoing from its
                # own state timestamp.
                (
                    "hermes-pipeline-unsorted-incoming-objects",
                    True,
                    NOW - dt.timedelta(days=8),
                    None,
                ),
                (
                    "padre-pipeline-missing-metatracker-rows",
                    False,
                    hours_ago(81.5),
                    hours_ago(80.6),
                ),
                (
                    "impax-pipeline-reconciliation-not-running",
                    False,
                    hours_ago(130),
                    hours_ago(129.5),
                ),
            ],
        )
        self.assertEqual(snap.events[1].workspace.name, "PADRE")
        # The reason recorded when the alarm fired travels with the event.
        self.assertEqual(snap.events[3].reason, crossed(4.0))
        self.assertIs(snap.events[3].mission, mission(snap, "PADRE"))

    def test_history_is_not_fetched_without_workspaces(self):
        client = FakeCloudWatch(alarms=[alarm("unrelated", "ALARM")])
        snap = snapshot(client=client)
        self.assertEqual(snap.missions, [])
        self.assertEqual(client.paginators["describe_alarm_history"].calls, [])

    def test_history_window_and_filters(self):
        client = FakeCloudWatch()
        snapshot(client=client)
        (call,) = client.paginators["describe_alarm_history"].calls
        self.assertEqual(call["HistoryItemType"], "StateUpdate")
        self.assertEqual(call["StartDate"], NOW - dt.timedelta(days=14))
        self.assertEqual(call["EndDate"], NOW)
        self.assertEqual(
            client.paginators["describe_alarms"].calls[0]["AlarmTypes"],
            ["CompositeAlarm", "MetricAlarm"],
        )

    def test_malformed_history_is_skipped(self):
        alarms = {
            "padre-pipeline-sorting-errors": widget.Alarm(
                "padre-pipeline-sorting-errors", "OK"
            )
        }
        items = [
            {
                "AlarmName": "padre-pipeline-sorting-errors",
                "Timestamp": NOW,
                "HistoryData": "nope",
            }
        ]
        self.assertEqual(
            widget.pair_history(
                items, alarms, [widget.Workspace("prod", "padre")], NOW
            ),
            [],
        )


class TimestampTests(unittest.TestCase):
    def test_transition_time_is_preferred_over_update_time(self):
        records = [
            {
                "AlarmName": "padre-pipeline-sorting-errors",
                "StateValue": "ALARM",
                "StateTransitionedTimestamp": hours_ago(30),
                "StateUpdatedTimestamp": hours_ago(1),
            },
            {
                "AlarmName": "padre-pipeline-sorting-throttles",
                "StateValue": "OK",
                "StateUpdatedTimestamp": hours_ago(2),
            },
        ]
        client = FakeCloudWatch(alarms=records, history_items=[])
        by_name = {a.name: a for a in widget.fetch_alarms(client)}
        self.assertEqual(
            by_name["padre-pipeline-sorting-errors"].updated, hours_ago(30)
        )
        self.assertEqual(
            by_name["padre-pipeline-sorting-throttles"].updated, hours_ago(2)
        )


class InsufficientDataEventTests(unittest.TestCase):
    def test_open_incident_whose_alarm_lost_data_shows_not_checked(self):
        alarms = workspace_alarms(
            "padre-pipeline-",
            missing_metatracker_rows={
                "state": "INSUFFICIENT_DATA",
                "updated": hours_ago(1),
            },
        )
        items = [
            history("padre-pipeline-missing-metatracker-rows", "ALARM", hours_ago(3)),
            history(
                "padre-pipeline-missing-metatracker-rows",
                "INSUFFICIENT_DATA",
                hours_ago(1),
                "ALARM",
            ),
        ]
        snap = snapshot(client=FakeCloudWatch(alarms=alarms, history_items=items))
        (event,) = snap.events
        self.assertTrue(event.ongoing)
        self.assertEqual(event.start, hours_ago(3))
        page = widget.render(snap, "dark", REGION)
        self.assertIn(
            '<span class="st-nodata">Not checked yet</span> · PADRE · Processing', page
        )
        self.assertNotIn('<span class="st-outage">Outage</span> · PADRE', page)
        self.assertEqual(
            stage(mission(snap, "PADRE"), "processing").status, "available"
        )


class RenderTests(unittest.TestCase):
    def test_dark_and_light_render_every_mission(self):
        snap = snapshot()
        for theme in ("dark", "light"):
            page = widget.render(snap, theme, REGION)
            self.assertIn("cwdb-no-default-styles", page)
            self.assertIn("<h1>Production Pipeline Status</h1>", page)
            self.assertIn(
                "HERMES has not been getting data through for 8 days. PADRE has errors "
                "(data still flowing) for 4 h 30 min. GDC-Trailblazer, iMPAX and SWxSOC "
                "Pipeline are fine.",
                page,
            )
            self.assertIn(
                "Checked Nov 18, 18:40 UTC · refreshes with the dashboard", page
            )
            for name in (
                "PADRE",
                "HERMES",
                "iMPAX",
                "GDC-Trailblazer",
                "SWxSOC Pipeline",
            ):
                self.assertIn(f'<div class="gname">{name}</div>', page)
            # Problem list under the verdict, worst first.
            self.assertLess(
                page.index("Arrival: Files arrived but were not sorted"),
                page.index("Processing: Processing failed on some files"),
            )
            self.assertIn("Recent events", page)
            self.assertIn("Ongoing · 4 h 30 min", page)
            self.assertIn("Nov 15 · lasted 54 min", page)
            self.assertIn("3,612 files", page)
            self.assertIn(widget.PALETTES[theme]["bg"], page)
        page = widget.render(snap, "dark", REGION)
        # Only missions with a problem start expanded; HERMES first.
        self.assertEqual(page.count('<details class="group" open>'), 2)
        self.assertLess(
            page.index('<div class="gname">HERMES</div>'),
            page.index('<div class="gname">PADRE</div>'),
        )
        self.assertIn("Daily files is not part of this mission's pipeline.", page)
        self.assertIn("Started 4 h 30 min ago (Nov 18, 14:10 UTC)", page)
        self.assertIn('<summary class="pill">What to do</summary>', page)
        self.assertIn("Open the Processing log filtered to the error lines", page)
        self.assertIn('title="OK: working normally"', page)
        self.assertIn("The health check has not reported for this mission yet.", page)
        self.assertIn('title="Reconciliation"', page)

    def test_counts_line_under_each_mission_header(self):
        page = widget.render(snapshot(), "dark", REGION)
        self.assertIn(
            '<div class="gcounts" title="Counted by the latest health-check run">'
            "Last 24 h: 142 files arrived · 140 checked · 0 missing records · "
            "2 failed processing</div>",
            page,
        )
        # The line sits inside the header, under the subtitle, so it shows
        # while the group is collapsed.
        padre = page.index('<div class="gname">PADRE</div>')
        self.assertLess(padre, page.index("Last 24 h: 142 files arrived"))
        self.assertLess(
            page.index("Last 24 h: 142 files arrived"), page.index("</summary>", padre)
        )
        # A quiet day is not a status: muted, with the caveat as a tooltip.
        self.assertIn(
            '<span class="quiet" title="No alarm: a quiet day and a stopped uploader '
            'look the same to the pipeline">0 files arrived</span> · 0 checked · '
            "0 missing records · 0 failed processing",
            page,
        )
        self.assertIn("Last 24 h: 1 file arrived · 1 checked · 1 missing record", page)
        self.assertIn("3,612 files arrived · 3,612 checked", page)
        # No line for a mission whose health check has not published yet.
        gdctb = page.index('<div class="gname">GDC-Trailblazer</div>')
        self.assertNotIn("Last 24 h", page[gdctb : page.index("</summary>", gdctb)])
        self.assertEqual(page.count('class="gcounts"'), 4)

    def test_legend_sits_before_the_first_mission(self):
        page = widget.render(snapshot(), "dark", REGION)
        self.assertLess(
            page.index('class="legend"'), page.index('<details class="group"')
        )
        self.assertIn("<b>Not checked yet</b>", page)

    def test_links_point_at_the_console_region(self):
        page = widget.render(snapshot(), "dark", "us-west-2")
        self.assertIn(
            "https://us-west-2.console.aws.amazon.com/cloudwatch/home?region=us-west-2"
            "#alarmsV2:alarm/padre-pipeline-processing-log-errors",
            page,
        )
        self.assertIn("#dashboards:name=swxsoc-pipeline-pipeline", page)
        self.assertIn(
            "#alarmsV2:?search=hermes-pipeline&amp;alarmStateFilter=ALARM", page
        )

    def test_reasons_are_escaped(self):
        alarms = workspace_alarms(
            "padre-pipeline-",
            sorting_errors={
                "state": "ALARM",
                "reason": "<script>alert('x')</script> & more",
                "updated": hours_ago(1),
            },
        )
        page = widget.render(
            snapshot(client=FakeCloudWatch(alarms=alarms, history_items=[])),
            "dark",
            REGION,
        )
        self.assertNotIn("<script>", page)
        self.assertIn(
            "&lt;script&gt;alert(&#x27;x&#x27;)&lt;/script&gt; &amp; more", page
        )

    def test_dev_title_and_contact_line(self):
        page = widget.render(
            snapshot("dev"), "dark", REGION, contact="#swxsoc-ops on Mattermost"
        )
        self.assertIn('<h1 class="sub">Development Pipeline Status</h1>', page)
        self.assertIn("Test environment · not science data", page)
        self.assertIn("Questions about an outage: #swxsoc-ops on Mattermost", page)
        self.assertIn("Demo is receiving and processing data.", page)
        self.assertIn("Nothing has gone wrong in the last two weeks.", page)

    def test_empty_environment(self):
        page = widget.render(snapshot("dev", FakeCloudWatch(alarms=[])), "dark", REGION)
        self.assertIn("No mission pipelines are reporting for Development yet", page)
        self.assertNotIn("Recent events", page)


class HandlerTests(unittest.TestCase):
    def test_describe(self):
        text = widget.handler({"describe": True}, None)
        self.assertIn("``` yaml\nenvironment: prod\n```", text)

    def test_unknown_environment(self):
        page = widget.handler({"environment": "staging"}, None)
        self.assertIn("unknown environment &#x27;staging&#x27;", page)

    def test_aws_failure_renders_error_panel(self):
        original = widget.cloudwatch_client
        widget.cloudwatch_client = lambda region: BrokenCloudWatch()
        try:
            page = widget.handler(
                {"environment": "prod", "widgetContext": {"theme": "light"}}, None
            )
        finally:
            widget.cloudwatch_client = original
        self.assertIn(
            "could not read CloudWatch: RuntimeError: AccessDenied: not authorized",
            page,
        )
        self.assertIn(widget.PALETTES["light"]["bg"], page)

    def test_handler_renders_with_a_working_client(self):
        original = widget.cloudwatch_client
        widget.cloudwatch_client = lambda region: FakeCloudWatch()
        try:
            page = widget.handler({"environment": "dev"}, None)
        finally:
            widget.cloudwatch_client = original
        self.assertIn("Development Pipeline Status", page)
        self.assertIn('<div class="gname">Demo</div>', page)
        self.assertIn("Last 24 h: 5 files arrived · 5 checked", page)


if __name__ == "__main__":
    unittest.main()
