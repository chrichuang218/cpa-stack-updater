from __future__ import annotations

import json
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from contextlib import closing
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
BACKUP_SCRIPT = (
    REPO_ROOT / "skills" / "cpa-safe-upgrade" / "scripts" / "backup_sqlite.py"
)


class BackupSqliteTests(unittest.TestCase):
    def run_backup(self, source: Path, destination: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(BACKUP_SCRIPT),
                "--source",
                str(source),
                "--destination",
                str(destination),
            ],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_live_wal_snapshot_is_standalone_and_verified(self) -> None:
        with tempfile.TemporaryDirectory() as temp_directory:
            root = Path(temp_directory)
            source = root / "source" / "usage.sqlite"
            destination = root / "snapshot" / "usage.sqlite"
            source.parent.mkdir()

            writer = sqlite3.connect(source)
            try:
                self.assertEqual(
                    "wal", str(writer.execute("PRAGMA journal_mode=WAL").fetchone()[0])
                )
                writer.executescript(
                    """
                    CREATE TABLE usage_events (
                        id INTEGER PRIMARY KEY,
                        timestamp_ms INTEGER NOT NULL
                    );
                    CREATE TABLE settings (name TEXT PRIMARY KEY, value TEXT);
                    INSERT INTO usage_events (timestamp_ms) VALUES (1000), (2000);
                    INSERT INTO settings (name, value) VALUES ('collector', 'enabled');
                    """
                )
                writer.commit()

                self.assertGreater(Path(str(source) + "-wal").stat().st_size, 0)
                self.assertTrue(Path(str(source) + "-shm").is_file())

                completed = self.run_backup(source, destination)
                self.assertEqual(0, completed.returncode, completed.stderr or completed.stdout)
                result = json.loads(completed.stdout)

                self.assertTrue(result["success"])
                self.assertTrue(result["invariants"]["source_quick_check_ok"])
                self.assertTrue(result["invariants"]["snapshot_quick_check_ok"])
                self.assertTrue(result["invariants"]["usage_events_preserved"]["ok"])
                self.assertEqual(2, result["snapshot"]["usage_events"]["count"])
                self.assertEqual(2, result["snapshot"]["usage_events"]["max_id"])
                self.assertEqual(
                    2000, result["snapshot"]["usage_events"]["max_timestamp_ms"]
                )
                self.assertEqual(0, result["snapshot"]["wal_size_bytes"])
                self.assertEqual(0, result["snapshot"]["shm_size_bytes"])
                self.assertFalse(Path(str(destination) + "-wal").exists())
                self.assertFalse(Path(str(destination) + "-shm").exists())
                self.assertGreater(Path(str(source) + "-wal").stat().st_size, 0)
                self.assertTrue(Path(str(source) + "-shm").is_file())

                immutable_uri = destination.resolve().as_uri() + "?mode=ro&immutable=1"
                with closing(sqlite3.connect(immutable_uri, uri=True)) as snapshot:
                    self.assertEqual("ok", snapshot.execute("PRAGMA quick_check").fetchone()[0])
                    self.assertEqual(
                        (2, 2, 2000),
                        snapshot.execute(
                            "SELECT count(*), max(id), max(timestamp_ms) "
                            "FROM usage_events"
                        ).fetchone(),
                    )

                self.assertFalse(Path(str(destination) + "-wal").exists())
                self.assertFalse(Path(str(destination) + "-shm").exists())
            finally:
                writer.close()

    def test_preexisting_destination_sidecar_is_not_deleted(self) -> None:
        with tempfile.TemporaryDirectory() as temp_directory:
            root = Path(temp_directory)
            source = root / "source.sqlite"
            destination = root / "snapshot" / "usage.sqlite"
            destination.parent.mkdir()

            with closing(sqlite3.connect(source)) as connection:
                connection.execute("CREATE TABLE settings (name TEXT)")
                connection.commit()

            existing_sidecar = Path(str(destination) + "-wal")
            existing_sidecar.write_bytes(b"not-created-by-backup")

            completed = self.run_backup(source, destination)
            self.assertEqual(2, completed.returncode, completed.stderr or completed.stdout)
            result = json.loads(completed.stdout)
            self.assertFalse(result["success"])
            self.assertEqual("FileExistsError", result["error"]["type"])
            self.assertEqual(b"not-created-by-backup", existing_sidecar.read_bytes())
            self.assertFalse(destination.exists())


if __name__ == "__main__":
    unittest.main()
