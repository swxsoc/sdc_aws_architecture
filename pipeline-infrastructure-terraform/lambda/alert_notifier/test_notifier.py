"""Unit tests for the Mattermost alert notifier. Run with ``python -m unittest``."""

from __future__ import annotations

import json
import unittest

import notifier


class FormatMessage(unittest.TestCase):
    def test_metric_alarm(self):
        message = notifier.format_message(
            json.dumps(
                {
                    "AlarmName": "prod-padre-pipeline-processing-log-errors",
                    "AlarmDescription": "processing log errors",
                    "NewStateValue": "ALARM",
                    "NewStateReason": "Threshold Crossed: 1 datapoint [3.0]",
                    "StateChangeTime": "2026-11-09T12:00:00.000+0000",
                }
            )
        )
        self.assertIn(
            ":rotating_light: **prod-padre-pipeline-processing-log-errors** is **ALARM**",
            message,
        )
        self.assertIn("Reason: Threshold Crossed", message)
        self.assertIn("At: 2026-11-09", message)

    def test_composite_alarm_lists_children(self):
        message = notifier.format_message(
            json.dumps(
                {
                    "AlarmName": "prod-padre-pipeline-unhealthy",
                    "NewStateValue": "OK",
                    "TriggeringChildren": [
                        {
                            "Arn": "arn:aws:cloudwatch:us-east-1:1:alarm:prod-padre-pipeline-sorting-errors"
                        }
                    ],
                }
            )
        )
        self.assertIn(":white_check_mark:", message)
        self.assertIn("Triggered by: prod-padre-pipeline-sorting-errors", message)

    def test_non_json_is_posted_verbatim(self):
        self.assertEqual(
            notifier.format_message("plain text", "Subject"), "Subject\nplain text"
        )
        self.assertEqual(notifier.format_message("plain text"), "plain text")


if __name__ == "__main__":
    unittest.main()
