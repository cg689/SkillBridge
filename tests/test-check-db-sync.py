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

    def test_fix_reports_error_when_schema_lacks_directory(self):
        db = os.path.join(self.tmp.name, "legacy.db")
        conn = sqlite3.connect(db)
        conn.executescript(
            "CREATE TABLE skills ("
            "  id TEXT PRIMARY KEY, name TEXT, enabled_codex INTEGER);"
            "INSERT INTO skills (id, name, enabled_codex) VALUES ('gone', 'gone', 1);"
        )
        conn.commit()
        conn.close()
        write_skill(self.source, "keep-me")
        result = run_check(self.source, db, extra=["--fix"])
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("could not repair", result.stdout)
        conn = sqlite3.connect(db)
        count = conn.execute("SELECT COUNT(*) FROM skills").fetchone()[0]
        conn.close()
        self.assertEqual(count, 1)  # repair rolled back: only the original row

    def test_fix_removes_rows_keyed_by_name_when_directory_is_null(self):
        conn = sqlite3.connect(self.db)
        conn.execute(
            "INSERT INTO skills (id, name, directory, enabled_codex) "
            "VALUES ('ghost', 'ghost', NULL, 1)"
        )
        conn.commit()
        conn.close()
        write_skill(self.source, "keep-me")
        result = run_check(self.source, self.db, extra=["--fix"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        conn = sqlite3.connect(self.db)
        directories = [r[0] for r in conn.execute("SELECT directory FROM skills")]
        conn.close()
        self.assertEqual(directories, ["keep-me"])

    def test_fix_refuses_to_empty_the_database(self):
        """An empty skills folder is usually a wrong --source, not a real delete."""
        conn = sqlite3.connect(self.db)
        for name in ("alpha", "beta"):
            conn.execute(
                "INSERT INTO skills (id, name, directory, enabled_codex) VALUES (?,?,?,1)",
                ("local:" + name, name, name),
            )
        conn.commit()
        conn.close()
        result = run_check(self.source, self.db, extra=["--fix"])
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("refused", result.stdout)
        conn = sqlite3.connect(self.db)
        count = conn.execute("SELECT COUNT(*) FROM skills").fetchone()[0]
        conn.close()
        self.assertEqual(count, 2, "the refusal must not remove anything")
        self.assertFalse(
            os.path.isdir(os.path.join(self.tmp.name, "backups")),
            "a refused repair must not leave a backup behind",
        )

    def test_fix_allows_empty_source_when_asked(self):
        conn = sqlite3.connect(self.db)
        conn.execute(
            "INSERT INTO skills (id, name, directory, enabled_codex) "
            "VALUES ('gone', 'gone', 'gone', 1)"
        )
        conn.commit()
        conn.close()
        result = run_check(self.source, self.db, extra=["--fix", "--allow-empty-source"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        conn = sqlite3.connect(self.db)
        count = conn.execute("SELECT COUNT(*) FROM skills").fetchone()[0]
        conn.close()
        self.assertEqual(count, 0)

    def test_missing_db_exits_2(self):
        result = run_check(self.source, os.path.join(self.tmp.name, "nope.db"))
        self.assertEqual(result.returncode, 2)

    def test_report_only_never_writes_the_db(self):
        """The sync runs this without --fix: drift must not touch a single row.

        A row is the only record of a skill's origin, so "reporting" that leaves
        the file byte-identical (not just the same rows) is the whole contract.
        """
        write_skill(self.source, "keep-me")
        conn = sqlite3.connect(self.db)
        conn.execute(
            "INSERT INTO skills (id, name, directory, repo_owner, readme_url) "
            "VALUES ('gone', 'gone', 'gone', 'someone', 'https://example.com')"
        )
        conn.commit()
        conn.close()
        with open(self.db, "rb") as handle:
            before = handle.read()
        before_mtime = os.stat(self.db).st_mtime_ns

        result = run_check(self.source, self.db)

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("gone", result.stdout, "the drift is still listed")
        self.assertIn("nothing was changed", result.stdout)
        self.assertIn("--fix", result.stdout, "the hint names the manual repair")
        with open(self.db, "rb") as handle:
            after = handle.read()
        self.assertEqual(after, before)
        self.assertEqual(os.stat(self.db).st_mtime_ns, before_mtime)
        self.assertFalse(
            os.path.isdir(os.path.join(self.tmp.name, "backups")),
            "a report-only run must not create a backup either",
        )

    def test_fix_warns_about_the_origin_loss_before_deleting(self):
        """--fix is manual now; it must say what a delete costs before doing it."""
        write_skill(self.source, "keep-me")
        conn = sqlite3.connect(self.db)
        conn.execute(
            "INSERT INTO skills (id, name, directory, repo_owner, readme_url) "
            "VALUES ('gone', 'gone', 'gone', 'someone', 'https://example.com')"
        )
        conn.commit()
        conn.close()
        result = run_check(self.source, self.db, extra=["--fix"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("about to DELETE 1 row(s)", result.stdout)
        self.assertIn("only record of a skill's origin", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
