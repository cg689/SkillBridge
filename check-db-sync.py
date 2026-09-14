#!/usr/bin/env python3
"""check-db-sync.py - keep CC Switch's skill database in step with the skills folder.

CC Switch maintains its own skill list in ~/.cc-switch/cc-switch.db (table
`skills`) and does NOT rescan the filesystem. A skill that arrives by copying a
folder, or by being generated locally, is therefore never registered: it stays
out of the Codex sync and never appears in the CC Switch UI.

This script closes that gap. It compares the skills folder against the database
and reports the drift, or repairs it with --fix.

Called automatically at the end of sync-skills.ps1 / sync-skills.sh (unless
`check_db` is false in config.json). Can also be run by hand.

Usage:
    python check-db-sync.py [--fix] [--quiet] [--log FILE] [--source DIR] [--db FILE]

Exit codes:
    0  in sync, or drift repaired
    1  drift found but not repaired (no --fix)
    2  could not run (missing paths, unreadable database)
"""
import argparse
import hashlib
import os
import shutil
import sqlite3
import sys
import time

DEFAULT_SOURCE = os.path.join(os.path.expanduser("~"), ".cc-switch", "skills")
DEFAULT_DB = os.path.join(os.path.expanduser("~"), ".cc-switch", "cc-switch.db")

# Destination toggles used when registering a skill that CC Switch never saw.
# SkillBridge's own job is the filesystem links; these flags only affect
# whether CC Switch also pushes the skill to its built-in destinations.
# Codex and Hermes default on because unregistered local skills were dropping
# out of those two; unknown future `enabled_*` columns default to 0.
DEFAULT_ENABLED = {
    "enabled_claude": 0,
    "enabled_codex": 1,
    "enabled_gemini": 0,
    "enabled_opencode": 0,
    "enabled_hermes": 1,
    "enabled_grokbuild": 0,
}


class _Tee:
    """Mirror stdout into a log file.

    Written from Python rather than by the caller on purpose: piping this
    script's output through PowerShell re-encodes it and garbles non-ASCII
    characters (Chinese skill descriptions, in particular).
    """

    def __init__(self, stream, path):
        self._stream = stream
        self._file = open(path, "a", encoding="utf-8")

    def write(self, data):
        self._stream.write(data)
        self._file.write(data)

    def flush(self):
        self._stream.flush()
        self._file.flush()


def parse_frontmatter(path):
    """Return {'name': ..., 'description': ...} from a SKILL.md, best effort.

    Deliberately not a YAML parser: skill frontmatter only ever needs these two
    scalar fields, and PyYAML may not be installed. Values wrapped in quotes are
    unwrapped; multi-line values are not supported (none in the wild so far).
    """
    out = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            text = handle.read()
    except OSError:
        return out
    stripped = text.lstrip()
    if not stripped.startswith("---"):
        return out
    body = stripped[3:]
    end = body.find("\n---")
    frontmatter = body[:end] if end != -1 else body
    for line in frontmatter.splitlines():
        for key in ("name", "description"):
            prefix = key + ":"
            if line.startswith(prefix) and key not in out:
                value = line[len(prefix):].strip()
                if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                    value = value[1:-1]
                out[key] = value
    return out


def compute_hash(skill_md):
    """Stable placeholder for CC Switch's content_hash.

    CC Switch uses SHA-256, but its exact input is not reproducible from the
    outside (verified against raw bytes, LF-normalised text, per-file and
    concatenated digests). A mismatch only makes CC Switch think the skill
    changed and resync it, which is harmless, so a stable value is enough.
    """
    with open(skill_md, "rb") as handle:
        raw = handle.read().decode("utf-8", errors="replace")
    return hashlib.sha256(raw.replace("\r\n", "\n").encode("utf-8")).hexdigest()


def scan_source(source_dir):
    """Map skill directory name -> SKILL.md path, skipping non-skill folders.

    Underscore-prefixed directories are archives (`_archived/...`), never skills.
    """
    found = {}
    if not os.path.isdir(source_dir):
        return found
    for name in sorted(os.listdir(source_dir)):
        if name.startswith("_"):
            continue
        directory = os.path.join(source_dir, name)
        if not os.path.isdir(directory):
            continue
        skill_md = os.path.join(directory, "SKILL.md")
        if os.path.isfile(skill_md):
            found[name] = skill_md
    return found


def scan_db(db_path):
    """Map directory name -> full row dict from the `skills` table."""
    conn = sqlite3.connect(db_path)
    try:
        columns = [row[1] for row in conn.execute("PRAGMA table_info(skills)")]
        rows = {}
        for row in conn.execute("SELECT * FROM skills"):
            record = dict(zip(columns, row))
            rows[record.get("directory") or record.get("name")] = record
        return columns, rows
    finally:
        conn.close()


def main():
    parser = argparse.ArgumentParser(description="CC Switch skills/DB consistency check")
    parser.add_argument("--fix", action="store_true", help="repair the drift (backs up the DB first)")
    parser.add_argument("--quiet", action="store_true", help="print nothing when already in sync")
    parser.add_argument("--log", metavar="FILE", help="also append output to FILE (UTF-8)")
    parser.add_argument("--source", default=DEFAULT_SOURCE, help="skills folder to check")
    parser.add_argument("--db", default=DEFAULT_DB, help="path to cc-switch.db")
    args = parser.parse_args()

    if args.log:
        sys.stdout = _Tee(sys.stdout, args.log)

    if not os.path.isdir(args.source):
        print(f"[error] skills folder not found: {args.source}")
        return 2
    if not os.path.isfile(args.db):
        print(f"[error] database not found: {args.db}")
        return 2

    source = scan_source(args.source)
    try:
        columns, database = scan_db(args.db)
    except sqlite3.Error as exc:
        print(f"[error] cannot read {args.db}: {exc}")
        return 2

    fs_only = sorted(set(source) - set(database))
    db_only = sorted(set(database) - set(source))

    if not fs_only and not db_only:
        if not args.quiet:
            print(f"OK  in sync: {len(source)} skill folders / {len(database)} db rows")
        return 0

    print(f"DRIFT  filesystem {len(source)} folders / database {len(database)} rows")
    if fs_only:
        print(f"\n[in filesystem only - {len(fs_only)} to register]")
        for name in fs_only:
            print(f"  + {name}")
    if db_only:
        print(f"\n[in database only - {len(db_only)} to remove; folder is gone]")
        for name in db_only:
            print(f"  - {name}")

    if not args.fix:
        print("\nhint: rerun with --fix to repair (the database is backed up first)")
        return 1

    backup_dir = os.path.join(os.path.dirname(args.db), "backups")
    os.makedirs(backup_dir, exist_ok=True)
    stamp = time.strftime("%Y%m%d_%H%M%S")
    backup = os.path.join(backup_dir, f"db_backup_{stamp}_before_skill_db_fix.db")
    shutil.copy2(args.db, backup)
    print(f"\ndatabase backed up -> {backup}")

    conn = sqlite3.connect(args.db)
    try:
        placeholders = ",".join("?" * len(columns))
        for name in fs_only:
            skill_md = source[name]
            frontmatter = parse_frontmatter(skill_md)
            record = {
                "id": f"local:{frontmatter.get('name') or name}",
                "name": frontmatter.get("name") or name,
                "description": frontmatter.get("description", ""),
                "directory": name,
                "repo_owner": None,
                "repo_name": None,
                "repo_branch": None,
                "readme_url": None,
                "installed_at": int(os.stat(skill_md).st_ctime),
                "content_hash": compute_hash(skill_md),
                "updated_at": 0,
            }
            record.update(DEFAULT_ENABLED)
            for column in columns:
                if column.startswith("enabled_") and column not in record:
                    record[column] = 0
            conn.execute(
                f"INSERT OR REPLACE INTO skills ({','.join(columns)}) VALUES ({placeholders})",
                [record.get(column) for column in columns],
            )

        for name in db_only:
            conn.execute("DELETE FROM skills WHERE directory = ?", (name,))

        conn.commit()
        total = conn.execute("SELECT COUNT(*) FROM skills").fetchone()[0]
        integrity = conn.execute("PRAGMA integrity_check").fetchone()[0]
    finally:
        conn.close()

    print(f"repaired: {len(fs_only)} registered, {len(db_only)} removed "
          f"| database now {total} rows | integrity={integrity}")
    return 0


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, OSError):
        pass
    sys.exit(main())
