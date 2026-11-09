"""Unit tests for the pure parts of the reconciliation Lambda.

Run from this directory with ``python -m unittest``. They need neither AWS
nor a database; ``pgwire`` is covered separately against a live PostgreSQL.
"""

from __future__ import annotations

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
    candidates = [
        obj("padre-craft", "raw/2026/11/08/a_l0.csv", timedelta(hours=3)),
        obj("padre-craft", "l1/2026/11/08/b_l1.csv", timedelta(hours=3)),
        obj("padre-craft", "l1/2026/11/08/c_l1.csv", timedelta(hours=3)),
        obj("padre-craft", "raw/2026/11/08/d_l0.csv", timedelta(hours=3)),
    ]

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
            "interval '24 hours'", reconcile.failed_status_sql("p_status", WINDOW)
        )
        self.assertIn("ago(26h)", reconcile.timestream_sql("db", "table", WINDOW))


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
