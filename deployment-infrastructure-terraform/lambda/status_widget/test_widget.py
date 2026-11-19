"""Unit tests for the pipeline status widget; no AWS access needed."""

from __future__ import annotations

import datetime as dt
import json
import unittest

import widget

NOW = dt.datetime(2026, 11, 18, 18, 40, tzinfo=dt.UTC)


def hours_ago(hours: float) -> dt.datetime:
    return NOW - dt.timedelta(hours=hours)


def alarm(name, state="OK", reason="", updated=None):
    return {
        "AlarmName": name,
        "StateValue": state,
        "StateReason": reason,
        "StateUpdatedTimestamp": updated or hours_ago(48),
    }


def history(name, new_state, when, old_state="OK"):
    return {
        "AlarmName": name,
        "Timestamp": when,
        "HistoryItemType": "StateUpdate",
        "HistoryData": json.dumps(
            {
                "newState": {"stateValue": new_state},
                "oldState": {"stateValue": old_state},
            }
        ),
    }


def workspace_alarms(prefix, **overrides):
    """A full set of pipeline health alarms for one workspace, all OK."""
    names = [
        "sorting-errors",
        "sorting-throttles",
        "sorting-duration",
        "sorting-log-errors",
        "processing-errors",
        "processing-throttles",
        "processing-duration",
        "processing-log-errors",
        "artifacts-errors",
        "artifacts-throttles",
        "artifacts-duration",
        "artifacts-log-errors",
        "craft-topic-delivery-failures",
        "craft-queue-age",
        "unsorted-incoming-objects",
        "missing-metatracker-rows",
        "missing-timestream-records",
        "reconciliation-check-errors",
        "reconciliation-not-running",
        "reconciliation-errors",
        "unhealthy",
    ]
    records = []
    for suffix in names:
        spec = overrides.get(suffix.replace("-", "_"), {})
        records.append(alarm(f"{prefix}{suffix}", **spec))
    return records


SAMPLE_ALARMS = (
    workspace_alarms(
        "padre-pipeline-",
        processing_log_errors={
            "state": "ALARM",
            "reason": "Threshold Crossed: 2 datapoints were greater than 0.",
            "updated": hours_ago(4.5),
        },
    )
    + workspace_alarms(
        "hermes-pipeline-",
        unsorted_incoming_objects={
            "state": "ALARM",
            "reason": "3612 objects remain after the sorting sweep.",
            "updated": NOW - dt.timedelta(days=8),
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
    history("padre-pipeline-processing-log-errors", "ALARM", hours_ago(4.5)),
    history("padre-pipeline-missing-metatracker-rows", "ALARM", hours_ago(81.5)),
    history("padre-pipeline-missing-metatracker-rows", "OK", hours_ago(80.6), "ALARM"),
    history("impax-pipeline-reconciliation-not-running", "ALARM", hours_ago(130)),
    history(
        "impax-pipeline-reconciliation-not-running", "OK", hours_ago(129.5), "ALARM"
    ),
    # OK without a preceding ALARM in the window: ignored.
    history("impax-pipeline-sorting-errors", "OK", hours_ago(200), "ALARM"),
    # Composite alarms are not part of the event list.
    history("padre-pipeline-unhealthy", "ALARM", hours_ago(4.5)),
]


class FakePaginator:
    def __init__(self, pages):
        self.pages = pages
        self.calls = []

    def paginate(self, **kwargs):
        self.calls.append(kwargs)
        return iter(self.pages)


class FakeCloudWatch:
    def __init__(self, alarms=SAMPLE_ALARMS, history_items=SAMPLE_HISTORY):
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


class BrokenCloudWatch:
    def get_paginator(self, name):
        raise RuntimeError("AccessDenied: not authorized to DescribeAlarms")


def snapshot(environment="prod", client=None):
    client = client or FakeCloudWatch()
    settings = widget.Settings("us-east-1", "us-east-1", 14)
    return widget.collect(client, environment, settings, NOW)


def mission(snap, name):
    return next(m for m in snap.missions if m.workspace.name == name)


def stage(mission_, key):
    return next(s for s in mission_.stages if s.key == key)


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
        prod = found[1]
        self.assertEqual(prod.prefix, "padre-pipeline-")
        self.assertEqual(prod.dashboard_name, "padre-pipeline")
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
        for kind in ("errors", "throttles", "duration", "log-errors"):
            self.check(f"sorting-{kind}", "sorting", "issue")
            self.check(f"processing-{kind}", "processing", "issue")
            self.check(f"artifacts-{kind}", "artifacts", "issue")
            self.check(f"concating-{kind}", "concating", "issue")
        self.check("meddea-topic-delivery-failures", "notification", "outage")
        self.check("sharp-queue-age", "notification", "outage")
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

    def test_missions_and_summary(self):
        snap = snapshot()
        self.assertEqual(
            [m.workspace.name for m in snap.missions],
            ["GDC-Trailblazer", "HERMES", "iMPAX", "PADRE", "SWxSOC Pipeline"],
        )
        padre = mission(snap, "PADRE")
        self.assertEqual(padre.status, "issue")
        self.assertEqual(stage(padre, "processing").status, "issue")
        self.assertEqual(stage(padre, "processing").since, hours_ago(4.5))
        self.assertEqual(stage(padre, "concating").status, "off")
        hermes = mission(snap, "HERMES")
        self.assertEqual(hermes.status, "outage")
        self.assertEqual(stage(hermes, "landing").status, "outage")
        gdctb = mission(snap, "GDC-Trailblazer")
        self.assertEqual(gdctb.status, "nodata")
        self.assertEqual(stage(gdctb, "landing").status, "nodata")
        self.assertEqual(stage(gdctb, "reconciliation").status, "nodata")
        # Processing has OK Lambda alarms and one INSUFFICIENT_DATA alarm.
        self.assertEqual(stage(gdctb, "processing").status, "available")
        self.assertEqual(mission(snap, "iMPAX").status, "available")
        self.assertEqual(
            widget.summarize(snap.missions),
            {"available": 26, "issue": 1, "outage": 1, "nodata": 2},
        )

    def test_dev_environment_is_separate(self):
        snap = snapshot("dev")
        self.assertEqual([m.workspace.name for m in snap.missions], ["Demo"])
        self.assertEqual(snap.missions[0].status, "available")


class HistoryTests(unittest.TestCase):
    def test_events_are_paired_and_ordered(self):
        snap = snapshot()
        described = [(e.alarm.name, e.ongoing, e.start, e.end) for e in snap.events]
        self.assertEqual(
            described,
            [
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
        self.assertEqual(snap.events[0].workspace.name, "PADRE")

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


class RenderTests(unittest.TestCase):
    def test_dark_and_light_render_every_mission(self):
        snap = snapshot()
        for theme in ("dark", "light"):
            page = widget.render(snap, theme, "us-east-1")
            self.assertIn("cwdb-no-default-styles", page)
            self.assertIn("Production Pipeline Status", page)
            for name in (
                "PADRE",
                "HERMES",
                "iMPAX",
                "GDC-Trailblazer",
                "SWxSOC Pipeline",
            ):
                self.assertIn(f">{name}</a>", page)
            self.assertIn("26 stages available", page)
            self.assertIn("1 current outage", page)
            self.assertIn("1 current issue", page)
            self.assertIn("2 stages reporting no data", page)
            self.assertIn("Recent events", page)
            self.assertIn("Ongoing · since Nov 18, 14:10 UTC", page)
            self.assertIn("Resolved · Nov 15, 09:10 – 10:04 UTC", page)
            self.assertIn(widget.PALETTES[theme]["bg"], page)
        self.assertIn(
            '<details class="group" open>', widget.render(snap, "dark", "us-east-1")
        )

    def test_links_point_at_the_console(self):
        page = widget.render(snapshot(), "dark", "us-west-2")
        self.assertIn(
            "https://us-west-2.console.aws.amazon.com/cloudwatch/home?region=us-west-2"
            "#alarmsV2:alarm/padre-pipeline-processing-log-errors",
            page,
        )
        self.assertIn("#dashboards:name=swxsoc-pipeline-pipeline", page)

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
            "us-east-1",
        )
        self.assertNotIn("<script>", page)
        self.assertIn(
            "&lt;script&gt;alert(&#x27;x&#x27;)&lt;/script&gt; &amp; more", page
        )

    def test_empty_environment(self):
        page = widget.render(
            snapshot("dev", FakeCloudWatch(alarms=[])), "dark", "us-east-1"
        )
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
        self.assertIn(">Demo</a>", page)


if __name__ == "__main__":
    unittest.main()
