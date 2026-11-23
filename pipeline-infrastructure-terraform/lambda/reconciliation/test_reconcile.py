"""Unit tests for the pure parts of the reconciliation Lambda.

Run from this directory with ``python -m unittest``. They need neither AWS
nor a database; ``pgwire`` has its own tests in ``test_pgwire.py``.
"""

from __future__ import annotations

import json
import re
import unittest
from datetime import UTC, datetime, timedelta

import reconcile
from reconcile import S3Object

NOW = datetime(2026, 11, 9, 12, 0, tzinfo=UTC)
WINDOW = timedelta(hours=24)
GRACE = timedelta(minutes=60)


def obj(bucket: str, key: str, age: timedelta) -> S3Object:
    return S3Object(bucket, key, NOW - age)


class ClassifyIncoming(unittest.TestCase):
    def test_fresh_objects_are_not_unsorted_yet(self):
        objects = [obj("in", "ingest/a.dat", timedelta(minutes=5))]
        unsorted, backlog, in_window = reconcile.classify_incoming(
            objects, NOW, WINDOW, GRACE, None
        )
        self.assertEqual((unsorted, backlog, in_window), ([], 0, 1))

    def test_objects_past_grace_are_unsorted(self):
        objects = [obj("in", "ingest/a.dat", timedelta(hours=2))]
        unsorted, backlog, in_window = reconcile.classify_incoming(
            objects, NOW, WINDOW, GRACE, None
        )
        self.assertEqual((unsorted, backlog, in_window), (["ingest/a.dat"], 0, 1))

    def test_objects_older_than_window_are_backlog_only(self):
        objects = [obj("in", "old/a.dat", timedelta(days=30))]
        unsorted, backlog, in_window = reconcile.classify_incoming(
            objects, NOW, WINDOW, GRACE, None
        )
        self.assertEqual((unsorted, backlog, in_window), ([], 1, 0))

    def test_ignored_keys_are_not_counted_anywhere(self):
        objects = [
            obj("in", "index.html", timedelta(hours=2)),
            obj("in", "ingest/", timedelta(hours=2)),
            obj("in", "ingest/b.dat", timedelta(hours=2)),
        ]
        unsorted, backlog, in_window = reconcile.classify_incoming(
            objects, NOW, WINDOW, GRACE, re.compile(r"(^|/)(index\.html|list\.js)$|/$")
        )
        self.assertEqual((unsorted, backlog, in_window), (["ingest/b.dat"], 0, 1))


class ProcessedCandidates(unittest.TestCase):
    def test_only_level_prefixed_objects_in_the_judged_range(self):
        objects = [
            obj("padre-craft", "raw/2026/11/08/a.csv", timedelta(hours=3)),
            obj("padre-craft", "l1/x/2026/11/08/b.csv", timedelta(hours=3)),
            obj("padre-craft", "latest/latest_dirlist.csv", timedelta(hours=3)),
            obj("padre-craft", "ancillary/rmf.fits", timedelta(hours=3)),
            obj("padre-craft", "raw/2026/11/08/fresh.csv", timedelta(minutes=10)),
            obj("padre-craft", "raw/2025/01/01/old.csv", timedelta(days=9)),
            obj("padre-craft", "raw/", timedelta(hours=3)),
        ]
        chosen = reconcile.processed_candidates(
            objects, ["raw", "l0", "l1", "ql"], NOW, WINDOW, GRACE
        )
        self.assertEqual(
            [o.key for o in chosen], ["l1/x/2026/11/08/b.csv", "raw/2026/11/08/a.csv"]
        )


class MissingRecords(unittest.TestCase):
    candidates = (
        obj("padre-craft", "raw/2026/11/08/a_l0.csv", timedelta(hours=3)),
        obj("padre-craft", "l1/2026/11/08/b_l1.csv", timedelta(hours=3)),
        obj("padre-craft", "l1/2026/11/08/c_l1.csv", timedelta(hours=3)),
        obj("padre-craft", "raw/2026/11/08/d_l0.csv", timedelta(hours=3)),
    )

    def test_metatracker_matches_stem_full_key_or_bare_filename(self):
        missing = reconcile.missing_from_metatracker(
            self.candidates,
            filenames={"a_l0"},
            s3_keys={"b_l1.csv", "raw/2026/11/08/d_l0.csv"},
        )
        self.assertEqual(missing, ["s3://padre-craft/l1/2026/11/08/c_l1.csv"])

    def test_timestream_matches_full_key_or_basename(self):
        missing = reconcile.missing_from_timestream(
            self.candidates, {"raw/2026/11/08/a_l0.csv", "b_l1.csv"}
        )
        self.assertEqual(
            missing,
            [
                "s3://padre-craft/l1/2026/11/08/c_l1.csv",
                "s3://padre-craft/raw/2026/11/08/d_l0.csv",
            ],
        )


class Sql(unittest.TestCase):
    def test_metatracker_sql_quotes_values_and_identifiers(self):
        sql = reconcile.metatracker_sql("padre_science_file", "filename", ["a", "it's"])
        self.assertEqual(
            sql,
            'SELECT filename, s3_key FROM "padre_science_file" WHERE "filename" = '
            "ANY(ARRAY['a', 'it''s']::text[])",
        )

    def test_identifiers_are_validated(self):
        with self.assertRaises(ValueError):
            reconcile.metatracker_sql("padre_science_file; drop", "filename", ["a"])
        with self.assertRaises(ValueError):
            reconcile.failed_status_sql("x y", WINDOW)

    def test_window_sql(self):
        self.assertIn(
            "interval '86400 seconds'", reconcile.failed_status_sql("p_status", WINDOW)
        )
        self.assertIn("ago(26h)", reconcile.timestream_sql("db", "table", WINDOW))

    def test_a_fractional_window_is_not_shortened(self):
        window = timedelta(hours=1.5)
        self.assertIn(
            "interval '5400 seconds'", reconcile.failed_status_sql("p_status", window)
        )
        # The Timestream query reads past the window, never short of it.
        self.assertIn("ago(3h)", reconcile.timestream_sql("db", "table", window))

    def test_tables_exist_sql_asks_about_each_quoted_name(self):
        self.assertEqual(
            reconcile.tables_exist_sql(["demo_science_file", "demo_status"]),
            "SELECT to_regclass('\"demo_science_file\"') IS NOT NULL, "
            "to_regclass('\"demo_status\"') IS NOT NULL",
        )
        with self.assertRaises(ValueError):
            reconcile.tables_exist_sql(["demo_status; drop"])


class Metrics(unittest.TestCase):
    def test_report_publishes_a_run_marker_even_when_empty(self):
        metrics = reconcile.Report().metrics()
        self.assertEqual(metrics["ReconciliationRuns"], 1)
        self.assertEqual(metrics["MissingMetaTrackerRows"], 0)

    def test_settings_reject_bad_mission(self):
        with self.assertRaises(ValueError):
            reconcile.Settings.from_environment(
                {
                    "MISSION": "padre; drop",
                    "INCOMING_BUCKET": "b",
                    "INSTRUMENT_BUCKETS": "c",
                    "DATA_LEVELS": "raw",
                    "TIMESTREAM_DATABASE": "d",
                    "TIMESTREAM_TABLE": "t",
                    "METRIC_NAMESPACE": "n",
                }
            )

    def test_settings_parse_lists_and_durations(self):
        settings = reconcile.Settings.from_environment(
            {
                "MISSION": "swxsoc_pipeline",
                "INCOMING_BUCKET": "dev-swxsoc-pipeline-incoming",
                "INSTRUMENT_BUCKETS": "dev-swxsoc-pipeline-reach, dev-swxsoc-pipeline-craft",
                "DATA_LEVELS": "raw,l0,l1c",
                "TIMESTREAM_DATABASE": "d",
                "TIMESTREAM_TABLE": "t",
                "METRIC_NAMESPACE": "SWxSOC/Pipeline/dev-swxsoc_pipeline",
                "WINDOW_HOURS": "48",
                "GRACE_MINUTES": "30",
                "SKIP_RDS": "True",
            }
        )
        self.assertEqual(len(settings.instrument_buckets), 2)
        self.assertEqual(settings.data_levels, ["raw", "l0", "l1c"])
        self.assertEqual(settings.window, timedelta(hours=48))
        self.assertEqual(settings.grace, timedelta(minutes=30))
        self.assertTrue(settings.skip_rds)
        self.assertEqual(settings.science_file_table, "swxsoc_pipeline_science_file")


if __name__ == "__main__":
    unittest.main()


class FakeConnection:
    """Answers the reconciliation queries the way PostgreSQL would."""

    def __init__(self, tables: set[str], science_rows=(), failed: int = 0):
        self.tables = tables
        self.science_rows = list(science_rows)
        self.failed = failed
        self.queries: list[str] = []

    def query(self, sql: str) -> list[tuple[str | None, ...]]:
        self.queries.append(sql)
        if sql.startswith("SELECT to_regclass"):
            names = re.findall(r"to_regclass\('\"(\w+)\"'\)", sql)
            return [tuple("t" if name in self.tables else "f" for name in names)]
        table = re.search(r'FROM "(\w+)"', sql).group(1)
        if table not in self.tables:
            raise AssertionError(f"queried {table}, which does not exist")
        if sql.startswith("SELECT count(*)"):
            return [(str(self.failed),)]
        return self.science_rows


class CheckMetatracker(unittest.TestCase):
    SETTINGS = reconcile.Settings.from_environment(
        {
            "MISSION": "demo",
            "INCOMING_BUCKET": "dev-demo-incoming",
            "INSTRUMENT_BUCKETS": "dev-demo-craft",
            "DATA_LEVELS": "raw",
            "TIMESTREAM_DATABASE": "d",
            "TIMESTREAM_TABLE": "t",
            "METRIC_NAMESPACE": "SWxSOC/Pipeline/dev-demo",
        }
    )
    CANDIDATES = (
        obj("dev-demo-craft", "raw/2026/11/demo_craft_1.csv", timedelta(hours=2)),
        obj("dev-demo-craft", "raw/2026/11/demo_craft_2.csv", timedelta(hours=3)),
    )

    def check(self, connection, candidates):
        report = reconcile.Report()
        reconcile.check_metatracker(connection, self.SETTINGS, candidates, report)
        return report

    def test_an_empty_workspace_without_tables_is_skipped_not_failed(self):
        connection = FakeConnection(tables=set())
        report = self.check(connection, [])
        self.assertEqual(report.check_errors, [])
        self.assertEqual(report.missing_metatracker, [])
        self.assertEqual(report.failed_processing, 0)
        self.assertEqual(len(report.skipped), 2)
        self.assertIn("demo_science_file does not exist yet", report.skipped[0])
        self.assertIn("demo_status does not exist yet", report.skipped[1])
        # Only the existence question was asked.
        self.assertEqual(len(connection.queries), 1)

    def test_objects_without_a_table_are_all_missing_their_rows(self):
        report = self.check(FakeConnection(tables=set()), list(self.CANDIDATES))
        self.assertEqual(
            report.missing_metatracker,
            [
                "s3://dev-demo-craft/raw/2026/11/demo_craft_1.csv",
                "s3://dev-demo-craft/raw/2026/11/demo_craft_2.csv",
            ],
        )
        self.assertEqual(report.metrics()["MissingMetaTrackerRows"], 2)

    def test_existing_tables_are_reconciled_and_counted(self):
        connection = FakeConnection(
            tables={"demo_science_file", "demo_status"},
            science_rows=[("demo_craft_1", "raw/2026/11/demo_craft_1.csv")],
            failed=3,
        )
        report = self.check(connection, list(self.CANDIDATES))
        self.assertEqual(
            report.missing_metatracker,
            ["s3://dev-demo-craft/raw/2026/11/demo_craft_2.csv"],
        )
        self.assertEqual(report.failed_processing, 3)
        self.assertEqual(report.skipped, [])


class AffectedKeys(unittest.TestCase):
    def test_batches_keep_every_key_in_order_within_the_size_limit(self):
        keys = [f"s3://dev-demo-craft/l0/2026/11/file_{n:05d}.csv" for n in range(900)]
        batches = list(reconcile.key_batches(keys, max_bytes=4000))
        self.assertGreater(len(batches), 1)
        self.assertEqual([key for batch in batches for key in batch], keys)
        for batch in batches:
            self.assertLessEqual(len(json.dumps(batch)), 4000)

    def test_an_oversized_key_is_logged_alone_rather_than_dropped(self):
        keys = ["a", "b" * 500, "c"]
        self.assertEqual(
            list(reconcile.key_batches(keys, max_bytes=100)),
            [["a"], ["b" * 500], ["c"]],
        )

    def test_entries_list_keys_the_bounded_summary_leaves_out(self):
        count = reconcile.MAX_LOGGED_KEYS + 150
        report = reconcile.Report(
            missing_metatracker=[f"s3://bucket/l0/{n:04d}.csv" for n in range(count)],
            unsorted=["ingest/a.dat"],
        )
        self.assertEqual(
            len(report.summary()["missing_metatracker"]), reconcile.MAX_LOGGED_KEYS
        )
        entries = list(reconcile.affected_key_entries("demo", report))
        logged = {
            check: [
                key for e in entries if e["affected_keys"] == check for key in e["keys"]
            ]
            for check in ("unsorted", "missing_metatracker", "missing_timestream")
        }
        self.assertEqual(logged["missing_metatracker"], report.missing_metatracker)
        self.assertEqual(logged["unsorted"], ["ingest/a.dat"])
        self.assertEqual(logged["missing_timestream"], [])
        for entry in entries:
            self.assertEqual(entry["mission"], "demo")
            self.assertLessEqual(
                len(json.dumps(entry)), reconcile.KEY_BATCH_BYTES + 1000
            )
        metatracker = [
            e for e in entries if e["affected_keys"] == "missing_metatracker"
        ]
        self.assertEqual({e["total"] for e in metatracker}, {count})
        self.assertEqual(
            [e["batch"] for e in metatracker],
            list(range(1, metatracker[0]["batches"] + 1)),
        )
