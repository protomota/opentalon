# OpenTalon agent connection

OpenTalon is a single-user macOS task manager with local SQLite storage and an embedded MCP server. The current desktop build is a local preview, unsigned and not a public downloadable release. Public distribution, signing/notarization and directory approval are separate work; do not advertise a listing or installation package before it exists.

## Connect from your agent app

1. Open OpenTalon → Settings → Work with your AI agent. Enable **Let my agent use OpenTalon**.
2. **Claude Code app:** choose **Save project connection**. Open that same folder in Claude desktop's Code tab in a local session on This computer. Review its MCP trust prompt and verify OpenTalon in Connectors. Existing connections in the project file are preserved; replacing a different OpenTalon entry requires review.
3. **Codex app:** choose **Codex app** in OpenTalon. In Codex, open Settings → MCP servers → Add server. Name it `opentalon`, choose STDIO, and use the individual Copy buttons for Command, Argument and environment fields. Paste each argument separately, without extra quotes. Save, restart the server and check `/mcp` in a local chat.
4. Ask the client to list your boards. Create a disposable task on a board you select, read it back, change its notes and move it between manual statuses. These operations change local task data.

Claude Code is listed first and Codex second in the app. Terminal is an optional advanced route. Cloud sessions and remote computers cannot access this local server.

## Runtime fields

Use the generated fields for the current installation; these are conventions, not literal paths to paste:

| Field       | Value                                                                           |
| ----------- | ------------------------------------------------------------------------------- |
| Name        | `opentalon`                                                                     |
| Transport   | STDIO                                                                           |
| Command     | The installed OpenTalon executable                                              |
| Argument    | The bundled `Contents/Resources/app.asar/electron/mcp-bridge.cjs` absolute path |
| Environment | `ELECTRON_RUN_AS_NODE=1`                                                        |
| Environment | `OPENTALON_MCP_CONFIG` set to this installation's private connection-file path  |

The bundled Electron runtime runs the bridge; no separate Node installation is required. The stdio bridge reads the owner-only private connection file and can start the app in the background. The bridge fields contain no connection key. Do not publish a user's generated paths or connection file. Direct HTTP is advanced: its loopback address can change and its authorization key is private.

## Supported tools

The current catalog has **24 public tools**:

- Availability and boards: `get_app_status`, `list_boards`, `create_board`, `rename_board`, `set_board_icon`, `delete_board`. Boards carry an optional sidebar icon from a fixed set; `create_board` also accepts one.
- Tasks: `list_tasks`, `get_task`, `create_task`, `update_task`, `move_task`, `trash_task`, `list_trash`, `restore_task`.
- Comments and progress: `list_task_comments`, `add_task_comment`, `read_comment_image`, `report_agent_progress`.
- Preferences and backup: `get_preferences`, `set_preferences`, `create_backup`, `inspect_backup`, `preview_destructive_action`, `confirm_destructive_action`.

Mutations use durable request keys; record updates require their last-read revision. Search, pagination, priority, due date, notes and completion criteria are supported. Trash is recoverable. Restore and permanent removal use validated previews and confirmation tokens; restore also saves a safety backup. UI-only setup, launcher, clipboard, folder picker and ordering helpers are not public MCP tools.

## Agent dispatch

To do, In progress and Done are manual by default. Only Sent to agent delegates, using the default Claude Code or Codex selected in Settings. The app starts a saved conversation with that installed first-party launcher; MCP alone does not make arbitrary clients create threads. Missing prerequisites open a setup-and-send dialog without changing the task. Pickup moves it to In progress. Comments and up to three screenshot attachments are checked every five minutes and resume the same assigned conversation. Done requires concrete proof and definition-of-done confirmation, posted on the ticket before completion. Moving an assigned task manually to a standard status clears the current assignment. Restored work never launches automatically.

## Privacy, permissions and revocation

Task data, comments, screenshot bytes, settings and backups stay on the Mac. Connecting grants the agent access to all boards and tasks in that local workspace, including Trash; access is not limited to a single board. The MCP interface exposes structured task/backup actions, not a generic shell or arbitrary-file editor. Agent execution uses the provider's existing sign-in, network service and normal permissions. OpenTalon stores no model API key. It does not independently certify the truth of an agent's submitted proof.

Disable **Let my agent use OpenTalon** to revoke MCP access. Stop a current dispatched run with **Stop run**; revoking the connector does not undo actions the agent already performed. Resetting the local connection key updates the stdio bridge automatically; direct HTTP clients need updated setup. Exports exclude connection credentials and pending approval payloads.

## Packages and support

Claude chat extension export is advanced and contains the original icon, bundled bridge and a reference to this Mac's private connection file. It contains no key, but is generated for the current machine and is not a universal public installer. Project setup and Codex Copy fields are generated per installation. Portable JSON or SQLite backups contain work data, not an MCP installation or credentials.

Setup assistance: [Protomota contact](https://protomota.com/services#contact). Paid setup requires a confirmed time and fixed fee before booking. Optional support: [Buy Me a Coffee](https://buymeacoffee.com/protomotalab). Updates: [Protomota newsletter](https://newsletter.protomota.com/).

## Acceptance evidence

The November 10, 2026 full test run passed **40 tests, zero failures and zero skips**. It included an installed Codex client initialized against an isolated profile, all 23 tools discovered, representative read/write/ordering/backup/restore and persistence checks, and an unchanged personal client configuration hash. Separate real Claude Code and Codex model turns completed disposable MCP tasks and same-thread screenshot feedback with completion proof. Native recording verified both saved-default drag launches, first-send recovery, automatic pickup, the actual five-minute watcher, comments/images, manual tracking, metadata, filters/sorting, Trash/restore, backups and the dashboard. Detailed local evidence is tracked in VALIDATION.md; provider thread IDs and private machine paths are not public installation instructions.
