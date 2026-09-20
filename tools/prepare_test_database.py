"""Rebind only an offline test snapshot; never open the production DB writable."""
import json
import sqlite3
import sys
from contextlib import closing
from pathlib import Path


def prepare(root: Path, port: int) -> None:
    root = root.resolve(strict=True)
    marker = json.loads((root / ".cpa-stack-test.json").read_text(encoding="utf-8-sig"))
    if Path(marker["root"]).resolve() != root or marker["cpaPort"] != port:
        raise ValueError("Test marker mismatch")
    database = root / "data" / "manager-plus" / "usage.sqlite"
    if database.resolve(strict=True).parent != root / "data" / "manager-plus":
        raise ValueError("Test database escapes its root")
    url = f"http://127.0.0.1:{port}"
    with closing(sqlite3.connect(database.as_uri() + "?mode=rw", uri=True)) as connection, connection:
        rows = dict(connection.execute(
            "SELECT key,value FROM settings WHERE key IN ('manager_config_v1','setup')"
        ))
        if "manager_config_v1" not in rows:
            raise ValueError("Unsupported Manager snapshot: missing manager config")
        config = json.loads(rows["manager_config_v1"])
        config["cpaConnection"]["cpaBaseUrl"] = url
        config["collector"]["enabled"] = False
        config["externalUsageService"] = {"enabled": False, "serviceBase": ""}
        # Keep encrypted credentials and historical data, disable copied automation.
        if "codexInspection" in config:
            config["codexInspection"]["enabled"] = False
        connection.execute("UPDATE settings SET value=? WHERE key='manager_config_v1'",
                           (json.dumps(config),))
        if "setup" in rows:
            setup = json.loads(rows["setup"])
            if "cpaBaseUrl" not in setup:
                raise ValueError("Unsupported legacy setup schema")
            setup["cpaBaseUrl"] = url
            connection.execute("UPDATE settings SET value=? WHERE key='setup'", (json.dumps(setup),))
        automation = {"codexQuotaCooldownEnabled": False, "authIssueQueueEnabled": False,
                      "authIssueAutoDisableEnabled": False}
        connection.execute("INSERT INTO settings(key,value,updated_at_ms) VALUES(?,?,0) "
                           "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                           ("automation_settings_v1", json.dumps(automation)))
        if connection.execute("PRAGMA quick_check").fetchall() != [("ok",)]:
            raise ValueError("Test snapshot integrity check failed")


if __name__ == "__main__":
    prepare(Path(sys.argv[1]), int(sys.argv[2]))
    print("Test snapshot connection isolated; integrity check passed.")
