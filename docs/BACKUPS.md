# Export and restore your OpenTalon data

## Export Backup

1. Open OpenTalon and click **Settings** at the bottom of the sidebar.
2. Under **Your data & backups**, click **Export Backup…**.
3. Choose a filename and location in the Save dialog, then click **Save**. Keep a copy on another drive or another location you control so it survives loss of this Mac.
4. Wait for **Backup saved** and the saved path.

The single readable JSON file contains a format version, app version, export date, all boards, fixed columns, tasks, priorities, definitions of done, due dates, notes, manual order, board/task relationships, created/updated/deleted dates, Trash, appearance, selected board, task-agent settings and run history (agent, folder, conversation ID, state and result). Agent transcripts remain in their own apps. Comments, completion reports and screenshot image bytes are included directly in the single backup. Connection credentials, tokens, enablement, ports, pending permission payloads and retry receipts are excluded. No account or hosted service is needed to export or restore. Version 5 adds nullable calendar due dates; version 4 added priority and definition of done. Version 1–4 JSON/SQLite backups remain supported, defaulting missing priorities/criteria/dates to No priority, blank and no due date. Restored active/queued runs become interrupted, pending/queued comments require review, and neither starts automatically. Board sort/filter choices are local display preferences and are not included in the portable backup.

## Import / Restore

1. Open OpenTalon, including on a clean installation after data loss.
2. Click **Settings → Your data & backups → Import / Restore…**.
3. Choose your exported JSON file and click **Open**. Older `.opentalon` and `.sqlite` backups also work.
4. OpenTalon validates format, supported version, records, relationships and preferences before showing the review. Malformed or unsupported files are rejected without replacing current data.
5. Review the filename and counts. **Restore backup** replaces the whole workspace; it does not merge records or add duplicate copies. Click **Cancel** to keep the current workspace.
6. If the preview is correct, click **Restore backup**. OpenTalon saves a safety backup of the current workspace first and restores in one database transaction. Changed data/files invalidate an old review, so select and review again if asked.
7. Wait for the success message and safety-backup path. The restored boards and tasks appear immediately. Reconnect an agent separately if setting up a new Mac; credentials are not imported.

Record IDs, relationships, dates, order, notes and Trash are preserved. Internal record revisions are renewed to protect against stale agent edits. Exported data is personal and readable; store the file somewhere you trust.

## Agent access

The existing `create_backup` tool accepts `format: "json"` for the same portable format. Its default remains SQLite for older clients. `inspect_backup` validates both formats, and `preview_destructive_action` / `confirm_destructive_action` provide the same review and safety-backup safeguards. The app still exposes 19 public tools.
