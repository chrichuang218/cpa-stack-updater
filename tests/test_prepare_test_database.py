import importlib.util
import json
import sqlite3
import tempfile
import unittest
from contextlib import closing
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "prepare_test_database", Path(__file__).resolve().parents[1] / "tools" / "prepare_test_database.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class TestSnapshotIsolation(unittest.TestCase):
    def test_rebind_preserves_history_and_secrets_and_requires_marker(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            data = root / "data" / "manager-plus"
            data.mkdir(parents=True)
            database = data / "usage.sqlite"
            with closing(sqlite3.connect(database)) as connection, connection:
                connection.execute("CREATE TABLE settings(key TEXT PRIMARY KEY,value TEXT,updated_at_ms INTEGER)")
                connection.execute("CREATE TABLE usage_events(id INTEGER)")
                connection.execute("INSERT INTO usage_events VALUES(123)")
                for key, value in {
                    "manager_config_v1": {"cpaConnection": {"cpaBaseUrl": "http://127.0.0.1:8317", "managementKey": "encrypted-fixture"}, "collector": {"enabled": True}},
                    "setup": {"cpaBaseUrl": "http://127.0.0.1:8317", "managementKey": "encrypted-fixture"},
                }.items():
                    connection.execute("INSERT INTO settings VALUES(?,?,0)", (key, json.dumps(value)))
            original = database.read_bytes()
            with self.assertRaises(FileNotFoundError):
                module.prepare(root, 28317)
            self.assertEqual(database.read_bytes(), original)
            (root / ".cpa-stack-test.json").write_text(json.dumps({"root": str(root), "cpaPort": 28317}))
            module.prepare(root, 28317)
            with closing(sqlite3.connect(database)) as connection:
                config = json.loads(connection.execute("SELECT value FROM settings WHERE key='manager_config_v1'").fetchone()[0])
                self.assertEqual(config["cpaConnection"]["cpaBaseUrl"], "http://127.0.0.1:28317")
                self.assertEqual(config["cpaConnection"]["managementKey"], "encrypted-fixture")
                self.assertFalse(config["collector"]["enabled"])
                self.assertEqual(connection.execute("SELECT id FROM usage_events").fetchall(), [(123,)])


if __name__ == "__main__":
    unittest.main()
