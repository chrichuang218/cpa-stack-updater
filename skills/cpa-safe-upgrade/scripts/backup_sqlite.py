#!/usr/bin/env python3
"""Create a consistent SQLite snapshot with the stdlib online backup API.

The script never reads application rows. Its JSON output contains only file
metadata, SQLite health state, schema counts, and numeric usage_events
watermarks that can be used for post-migration compatibility checks.
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


FORMAT_VERSION = 1
SNAPSHOT_SIDECAR_SUFFIXES = ("-wal", "-shm")


class ValidationError(RuntimeError):
    """Raised when a snapshot is readable but fails safety assertions."""


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def read_only_uri(path: Path) -> str:
    return path.resolve().as_uri() + "?mode=ro"


def connect_read_only(path: Path, timeout_seconds: float) -> sqlite3.Connection:
    connection = sqlite3.connect(
        read_only_uri(path),
        uri=True,
        timeout=timeout_seconds,
    )
    connection.execute("PRAGMA query_only = ON")
    return connection


def quick_check(connection: sqlite3.Connection) -> dict[str, Any]:
    messages = [str(row[0]) for row in connection.execute("PRAGMA quick_check")]
    ok = len(messages) == 1 and messages[0].lower() == "ok"
    return {
        "ok": ok,
        "message_count": len(messages),
        "messages": messages[:20],
        "truncated": len(messages) > 20,
    }


def table_names(connection: sqlite3.Connection) -> list[str]:
    rows = connection.execute(
        """
        SELECT name
        FROM sqlite_schema
        WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
        ORDER BY name
        """
    )
    return [str(row[0]) for row in rows]


def usage_events_summary(connection: sqlite3.Connection) -> dict[str, Any]:
    exists = (
        connection.execute(
            """
            SELECT 1
            FROM sqlite_schema
            WHERE type = 'table' AND name = 'usage_events'
            """
        ).fetchone()
        is not None
    )
    if not exists:
        return {
            "exists": False,
            "count": 0,
            "max_id": None,
            "max_timestamp_ms": None,
        }

    columns = {
        str(row[1]) for row in connection.execute("PRAGMA table_info(usage_events)")
    }
    required = {"id", "timestamp_ms"}
    missing = sorted(required - columns)
    if missing:
        raise ValidationError(
            "usage_events is missing required watermark columns: "
            + ", ".join(missing)
        )

    count, max_id, max_timestamp_ms = connection.execute(
        "SELECT count(*), max(id), max(timestamp_ms) FROM usage_events"
    ).fetchone()
    return {
        "exists": True,
        "count": int(count),
        "max_id": int(max_id) if max_id is not None else None,
        "max_timestamp_ms": (
            int(max_timestamp_ms) if max_timestamp_ms is not None else None
        ),
    }


def critical_table_counts(connection: sqlite3.Connection) -> dict[str, int | None]:
    existing = set(table_names(connection))
    names = (
        "settings",
        "model_prices",
        "usage_account_model_rollups",
        "usage_rollup_checkpoints",
        "usage_dashboard_hourly_rollups",
    )
    result: dict[str, int | None] = {}
    for name in names:
        if name not in existing:
            result[name] = None
            continue
        quoted = name.replace('"', '""')
        result[name] = int(
            connection.execute(f'SELECT count(*) FROM "{quoted}"').fetchone()[0]
        )
    return result


def database_summary(connection: sqlite3.Connection) -> dict[str, Any]:
    tables = table_names(connection)
    return {
        "quick_check": quick_check(connection),
        "journal_mode": str(
            connection.execute("PRAGMA journal_mode").fetchone()[0]
        ).lower(),
        "page_size": int(connection.execute("PRAGMA page_size").fetchone()[0]),
        "page_count": int(connection.execute("PRAGMA page_count").fetchone()[0]),
        "application_table_count": len(tables),
        "usage_events": usage_events_summary(connection),
        "critical_table_counts": critical_table_counts(connection),
    }


def file_metadata(path: Path) -> dict[str, Any]:
    return {
        "path": str(path.resolve()),
        "size_bytes": path.stat().st_size,
        "wal_size_bytes": sidecar_size(path, "-wal"),
        "shm_size_bytes": sidecar_size(path, "-shm"),
    }


def sidecar_size(path: Path, suffix: str) -> int:
    sidecar = Path(str(path) + suffix)
    return sidecar.stat().st_size if sidecar.exists() else 0


def snapshot_sidecars(path: Path) -> tuple[Path, ...]:
    return tuple(Path(str(path) + suffix) for suffix in SNAPSHOT_SIDECAR_SUFFIXES)


def assert_snapshot_sidecars_absent(path: Path) -> None:
    existing = [sidecar for sidecar in snapshot_sidecars(path) if sidecar.exists()]
    if existing:
        names = ", ".join(sidecar.name for sidecar in existing)
        raise FileExistsError(
            f"destination SQLite sidecar already exists; refusing to overwrite: {names}"
        )


def remove_generated_snapshot_sidecars(path: Path) -> None:
    """Remove disposable sidecars created while validating a new snapshot.

    Opening a standalone WAL-mode snapshot read-only can create a shared-memory
    file and an empty WAL. A non-empty WAL is never disposable: it may contain
    committed pages that are not present in the main database.
    """

    wal_path, shm_path = snapshot_sidecars(path)
    if wal_path.exists() and wal_path.stat().st_size != 0:
        raise ValidationError(
            f"snapshot WAL contains data; refusing unsafe cleanup: {wal_path}"
        )

    for sidecar in (shm_path, wal_path):
        if sidecar.exists():
            sidecar.unlink()

    remaining = [sidecar for sidecar in (wal_path, shm_path) if sidecar.exists()]
    if remaining:
        names = ", ".join(sidecar.name for sidecar in remaining)
        raise ValidationError(f"snapshot SQLite sidecar cleanup failed: {names}")


def not_decreased(before: Any, after: Any) -> bool:
    if before is None:
        return True
    if after is None:
        return False
    return int(after) >= int(before)


def compare_usage_events(
    source: dict[str, Any], snapshot: dict[str, Any]
) -> dict[str, Any]:
    fields = ("count", "max_id", "max_timestamp_ms")
    field_results = {
        field: not_decreased(source.get(field), snapshot.get(field)) for field in fields
    }
    existence_preserved = not source.get("exists", False) or snapshot.get(
        "exists", False
    )
    return {
        "ok": existence_preserved and all(field_results.values()),
        "existence_preserved": existence_preserved,
        "fields": field_results,
    }


def compare_critical_table_counts(
    source: dict[str, int | None], snapshot: dict[str, int | None]
) -> dict[str, Any]:
    fields = {
        name: not_decreased(source.get(name), snapshot.get(name))
        for name in ("settings", "model_prices")
    }
    return {"ok": all(fields.values()), "fields": fields}


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create and validate a consistent SQLite online backup."
    )
    parser.add_argument("--source", required=True, help="Source SQLite database")
    parser.add_argument(
        "--destination",
        required=True,
        help="New snapshot path; it must not already exist",
    )
    parser.add_argument(
        "--timeout-seconds",
        type=float,
        default=30.0,
        help="SQLite busy timeout in seconds (default: 30)",
    )
    parser.add_argument(
        "--pages",
        type=int,
        default=256,
        help="Pages copied per backup step (default: 256)",
    )
    parser.add_argument(
        "--sleep-ms",
        type=float,
        default=50.0,
        help="Delay between busy backup retries in milliseconds (default: 50)",
    )
    args = parser.parse_args(argv)
    if args.timeout_seconds <= 0:
        parser.error("--timeout-seconds must be greater than zero")
    if args.pages <= 0:
        parser.error("--pages must be greater than zero")
    if args.sleep_ms < 0:
        parser.error("--sleep-ms must not be negative")
    return args


def run(args: argparse.Namespace) -> tuple[dict[str, Any], int]:
    source_path = Path(args.source).expanduser().resolve()
    destination_path = Path(args.destination).expanduser().resolve()

    if not source_path.is_file():
        raise FileNotFoundError(f"source database does not exist: {source_path}")
    if destination_path.exists():
        raise FileExistsError(
            f"destination already exists; refusing to overwrite: {destination_path}"
        )
    assert_snapshot_sidecars_absent(destination_path)
    if source_path == destination_path:
        raise ValidationError("source and destination must be different files")

    destination_path.parent.mkdir(parents=True, exist_ok=True)

    source_connection: sqlite3.Connection | None = None
    destination_connection: sqlite3.Connection | None = None
    source_summary: dict[str, Any] | None = None

    try:
        source_connection = connect_read_only(source_path, args.timeout_seconds)

        # Pin one read snapshot so the watermarks and online backup describe the
        # same point in time while a WAL-mode Manager keeps accepting writes.
        source_connection.execute("BEGIN")
        source_summary = database_summary(source_connection)
        if not source_summary["quick_check"]["ok"]:
            raise ValidationError("source database failed PRAGMA quick_check")

        destination_connection = sqlite3.connect(
            str(destination_path), timeout=args.timeout_seconds
        )
        source_connection.backup(
            destination_connection,
            pages=args.pages,
            sleep=args.sleep_ms / 1000.0,
        )
        destination_connection.commit()
    finally:
        if destination_connection is not None:
            destination_connection.close()
        if source_connection is not None:
            if source_connection.in_transaction:
                source_connection.rollback()
            source_connection.close()

    snapshot_connection: sqlite3.Connection | None = None
    try:
        snapshot_connection = connect_read_only(
            destination_path, args.timeout_seconds
        )
        snapshot_summary = database_summary(snapshot_connection)
    finally:
        if snapshot_connection is not None:
            snapshot_connection.close()
        # Close every SQLite handle before unlinking Windows sidecar files.
        remove_generated_snapshot_sidecars(destination_path)

    usage_invariant = compare_usage_events(
        source_summary["usage_events"], snapshot_summary["usage_events"]
    )
    table_count_invariant = compare_critical_table_counts(
        source_summary["critical_table_counts"],
        snapshot_summary["critical_table_counts"],
    )
    success = bool(
        snapshot_summary["quick_check"]["ok"]
        and usage_invariant["ok"]
        and table_count_invariant["ok"]
    )

    result = {
        "format_version": FORMAT_VERSION,
        "success": success,
        "operation": "sqlite_online_backup",
        "created_at_utc": utc_now(),
        "source": {
            **file_metadata(source_path),
            **source_summary,
        },
        "snapshot": {
            **file_metadata(destination_path),
            **snapshot_summary,
        },
        "invariants": {
            "source_quick_check_ok": source_summary["quick_check"]["ok"],
            "snapshot_quick_check_ok": snapshot_summary["quick_check"]["ok"],
            "usage_events_preserved": usage_invariant,
            "critical_table_counts_preserved": table_count_invariant,
        },
    }
    return result, 0 if success else 1


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        result, exit_code = run(args)
    except Exception as error:  # JSON-only failure output for PowerShell callers.
        result = {
            "format_version": FORMAT_VERSION,
            "success": False,
            "operation": "sqlite_online_backup",
            "created_at_utc": utc_now(),
            "error": {
                "type": type(error).__name__,
                "message": str(error),
            },
        }
        exit_code = 2
    print(json.dumps(result, ensure_ascii=True, sort_keys=True))
    return exit_code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
