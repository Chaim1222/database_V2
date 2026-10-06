"""היסטוריית מסד שונה חייבת לעצור לפני כל קובץ SQL, גם בלי --check."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class MigrationGuardTests(unittest.TestCase):
    def test_unknown_applied_migration_blocks_writes(self):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            psql = tmp / "psql"
            psql.write_text('#!/bin/sh\ncase "$*" in\n *"select version"*) printf "0001\\n0031\\n" ;;\n *) touch "$AUDIT_WRITE_MARKER" ;;\nesac\n')
            psql.chmod(0o755)
            marker = tmp / "sql_was_applied"
            env = {**os.environ, "PATH": str(tmp) + os.pathsep + os.environ["PATH"],
                   "DATABASE_URL": "postgresql://example.invalid/test", "AUDIT_WRITE_MARKER": str(marker)}
            for flags in ([], ["--check"]):
                result = subprocess.run(["bash", str(root / "ops/apply_migrations.sh"), *flags],
                                        env=env, text=True, capture_output=True)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("0031", result.stdout)
                self.assertFalse(marker.exists(), "guard applied SQL before rejecting drift")
