#!/usr/bin/env python3
"""Checks that development builds cannot inherit release publication settings."""

import plistlib
import re
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]


class ForkBaselineTests(unittest.TestCase):
    def test_enabled_workflows_cannot_publish_or_write_to_upstream(self) -> None:
        workflow_dir = REPOSITORY_ROOT / ".github" / "workflows"
        workflows = sorted(workflow_dir.glob("*.yml")) + sorted(workflow_dir.glob("*.yaml"))
        self.assertTrue(workflows)
        for workflow in workflows:
            with self.subTest(workflow=workflow.name):
                text = workflow.read_text(encoding="utf-8")
                self.assertNotIn("theboredteam", text.lower())
                self.assertIn("github.repository == 'WOLFIEEEE/HeyNotch'", text)
                self.assertNotRegex(
                    text,
                    r"(?m)^\s*(?:contents|pages|issues|pull-requests|id-token):\s*write\s*$",
                )
                self.assertNotRegex(text, r"\b(?:git\s+push|gh\s+release\s+create)\b")
                self.assertNotIn("disabled-workflows/", text)
                for checkout in re.finditer(r"uses:\s*actions/checkout@", text):
                    following_step = text[checkout.end():].split("\n      - ")[0]
                    self.assertIn("persist-credentials: false", following_step)

    def test_development_bundle_disables_updates_without_a_signing_key(self) -> None:
        with (REPOSITORY_ROOT / "HeyNotch" / "Info.plist").open("rb") as plist:
            configuration = plistlib.load(plist)
        self.assertIs(configuration["HeyNotchUpdatesEnabled"], False)
        self.assertIs(configuration["SUEnableAutomaticChecks"], False)
        self.assertIs(configuration["SUAutomaticallyUpdate"], False)
        self.assertNotIn("SUPublicEDKey", configuration)
        self.assertEqual(
            configuration["SUFeedURL"],
            "https://WOLFIEEEE.github.io/HeyNotch/appcast.xml",
        )

    def test_update_feed_has_no_inherited_release(self) -> None:
        feed = ET.parse(REPOSITORY_ROOT / "updater" / "appcast.xml")
        self.assertEqual(feed.getroot().tag, "rss")
        self.assertIsNotNone(feed.find("channel"))
        self.assertEqual(feed.findall(".//item"), [])
        self.assertEqual(feed.findall(".//enclosure"), [])

if __name__ == "__main__":
    unittest.main()
