#!/usr/bin/env python3
"""tests/test-check-db-sync.py — unit tests for check-db-sync.py against a temp DB."""
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "check-db-sync.py")

SCHEMA = """
CREATE TABLE skills (
  id TEXT PRIMARY KEY,
  name TEXT,
  description TEXT,
  directory TEXT,
  repo_owner TEXT,
  repo_name TEXT,
  repo_branch TEXT,
  readme_url TEXT,
  enabled_claude INTEGER,
  enabled_codex INTEGER,
  enabled_gemini INTEGER,
  enabled_opencode INTEGER,
  enabled_hermes INTEGER,
  enabled_grokbuild INTEGER,
  enabled_future INTEGER,
  installed_at INTEGER,
  content_hash TEXT,
  updated_at INTEGER
)
"""

SKILL_MD = """---
name: demo-skill
description: "A demo skill"
---

# Demo
"""


def run_check(source, db, extra=None):
    cmd = [sys.executable, SCRIPT, "--source", source, "--db", db]
    if extra:
        cmd.extend(extra)
    return subprocess.run(cmd, capture_output=True, text=True)


def write_skill(root, name, body=SKILL_MD):
    folder = os.path.join(root, name)
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, "SKILL.md"), "w", encoding="utf-8") as handle:
        handle.write(body)
    return folder


class CheckDbSyncTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.source = os.path.join(self.tmp.name, "skills")
        os.makedirs(self.source)
        self.db = os.path.join(self.tmp.name, "cc-switch.db")
        conn = sqlite3.connect(self.db)
        conn.executescript(SCHEMA)
        conn.close()

    def tearDown(self):
        self.tmp.cleanup()

    def test_in_sync_empty(self):
        result = run_check(self.source, self.db)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("in sync", result.stdout)

    def test_fs_only_reports_drift_without_fix(self):
        write_skill(self.source, "demo-skill")
        result = run_check(self.source, self.db)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("demo-skill", result.stdout)
        conn = sqlite3.connect(self.db)
        count = conn.execute("SELECT COUNT(*) FROM skills").fetchone()[0]
        conn.close()
        self.assertEqual(count, 0)

    def test_fix_registers_and_uses_defaults(self):
        write_skill(self.source, "demo-skill")
        result = run_check(self.source, self.db, extra=["--fix"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        conn = sqlite3.connect(self.db)
        row = conn.execute(
            "SELECT name, description, enabled_codex, enabled_hermes, "
            "enabled_claude, enabled_future FROM skills WHERE directory = ?",
            ("demo-skill",),
        ).fetchone()
        conn.close()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], "demo-skill")
        self.assertEqual(row[1], "A demo skill")
        self.assertEqual(row[2], 1)
        self.assertEqual(row[3], 1)
        self.assertEqual(row[4], 0)
        self.assertEqual(row[5], 0)  # unknown enabled_* column defaults to 0

    def test_fix_removes_db_only_and_skips_archive(self):
        write_skill(self.source, "keep-me")
        write_skill(self.source, "_archived")
        conn = sqlite3.connect(self.db)
        conn.execute(
            "INSERT INTO skills (id, name, directory, enabled_codex) "
            "VALUES ('gone', 'gone', 'gone', 1)"
        )
        conn.commit()
        conn.close()
        result = run_check(self.source, self.db, extra=["--fix"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        conn = sqlite3.connect(self.db)
        names = [r[0] for r in conn.execute("SELECT directory FROM skills")]
        conn.close()
        self.assertEqual(names, ["keep-me"])
        self.assertIn("gone", result.stdout)

    def test_missing_db_exits_2(self):
        result = run_check(self.source, os.path.join(self.tmp.name, "nope.db"))
        self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
