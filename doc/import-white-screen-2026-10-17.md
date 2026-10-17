# Backup import white screen

## Device evidence

- Android device: TAS-AN00; installed Prime version: 2.6.2 (2622).
- White screen reproduced by cold-starting the installed application without
  clearing its data or reinstalling it.
- Flutter logs were suppressed by the device's global `persist.log.tag=M`.
  Temporarily enabling `log.tag.flutter=V` exposed the first exception:
  `no such column: added_at`, from
  `SELECT * FROM read_later ORDER BY added_at DESC`.
- The call originates in `ReadLaterManager.getAll` while constructing the home
  page. Subsequent `RenderPhysicalModel` / `RenderSliver` errors follow that
  failure.

## Cause

The previously supplied `1792075800 (1).venera` contains a valid, empty
`read_later` table with `type` and `added_time` columns, nullable `subtitle`, and
no `tags` or `description`. Current code expects `comic_type`, `added_at`,
`tags`, and `description`. The existing migration only added `description`.
SQLite integrity checks therefore passed, but homepage queries failed.

The later `1792228143585082.venera` has the current read-later schema. Neither
archive's embedded source scripts were executed during this investigation.

## Fix and validation

- Rebuild the legacy table in a SQLite transaction, map the old field names,
  preserve identity and timestamps, and fill missing optional fields.
- Replace the old primary key and NOT NULL columns so future inserts work.
- Keep schema migration outside corrupt-database recovery: unsupported schemas
  fail initialization or trigger import rollback, preserving the original DB.
- Linux: 7 focused migration/backup tests passed, including native ZIP export.
- Connected Android device: 6 tests passed, 1 host-only WAL export test skipped.
  The isolated integration application verified empty/populated legacy tables,
  retained timestamps, duplicate rejection, writes, reopening, and backup import
  followed by core-manager reinitialization.
- Static analysis of the changed Dart files passed.

The installed production application was not replaced. The tests use synthetic
fixtures matching the original table definition; they do not constitute a full
restore of either original archive on the device. No version was bumped and no
release was published.
