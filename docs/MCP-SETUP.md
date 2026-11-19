# Connect your agent to OpenTalon

Set up from the desktop apps. No Terminal required. Our app order is **Claude Code app first, Codex app second**, with Claude chat and command-line setup marked Advanced. This follows Inkspring’s MCP setup convention.

## Enable OpenTalon

1. Open [OpenTalon](</Volumes/Expand/Codex Media/opentalon/prototype/release/mac-arm64/OpenTalon.app>). Keep Expand mounted while using this build.
2. Click **Settings** in the sidebar and find **Work with your AI agent**.
3. Turn on **Let my agent use OpenTalon**. **Available on this Mac** means the embedded server is ready; your agent’s connector list confirms the actual client connection.

Connected agents can read and change all boards and tasks. Task storage stays local; your agent handles its own model connection.

## Claude Code app

1. Select **Claude Code app → Save project connection** in OpenTalon Settings. Choose the working folder you will open in Claude Code. OpenTalon creates or updates that folder’s `.mcp.json`, preserving other entries. If a different OpenTalon entry exists, review the replacement prompt.
2. Open the **Claude desktop app**, choose the **Code** tab, and start a new **local** session on **This computer** in that same folder.
3. Review Claude’s project MCP trust prompt and approve OpenTalon if you want to connect it.
4. Open the session’s **Connectors** panel, check OpenTalon, and ask it to list your boards. Start a new session if the folder was already open.

Cloud sessions and remote computers cannot reach this copy of OpenTalon. Existing global or Claude chat entries with the same name may take precedence. Official guides: [Claude Code desktop](https://code.claude.com/docs/en/desktop#connect-external-tools), [project MCP configuration and trust](https://code.claude.com/docs/en/mcp#project-scope).

## Codex app

1. In OpenTalon Settings, select **Codex app**, then **Open Codex**.
2. In Codex, choose **Settings → MCP servers → Add server**. Some versions label the desktop app ChatGPT.
3. Name it **opentalon** and choose **STDIO**.
4. Use OpenTalon’s individual **Copy** buttons for **Command**, each **Argument**, and both environment-variable values. Paste without extra quotes, each argument as its own entry. Use the exact environment-variable names shown.
5. Choose **Save**, then **Restart** for the server. Start a local chat and type **/mcp** to check it.

The fields use the current app installation and profile paths, with no connection key. See the [official OpenAI setup guide](https://learn.chatgpt.com/docs/extend/mcp?surface=desktop).

## Check reading and writing

Ask: **“Use OpenTalon to list my boards and tasks.”** Compare the answer with the app. Then ask:

- “On the board I choose, add a task called ‘Agent connection test’ with notes ‘Created from my agent app.’ Read it back.”
- “Change its notes to ‘Read and write verified,’ then move it to In progress.”
- “Mark ‘Agent connection test’ as Done.”

These prompts save a local task. Approve tool access if asked. The UI should reflect changes immediately. The STDIO bridge can start OpenTalon in the background, so you can continue from your agent with the board window closed.

## Advanced: Claude chat, other clients and Terminal

**Claude chat** is separate from Claude Code’s Code tab. Select **Claude chat · advanced**, then **Save Claude extension…**. In Claude, open **Settings → Desktop app → Extensions → Manage → Advanced settings → Install Extension…**, choose `OpenTalon.mcpb`, and follow the prompts. Older versions begin at **Settings → Extensions**. In a new chat, use **+ → Connectors** to check tools. If missing, quit Claude with **⌘Q** and reopen it. The extension contains the bridge and a reference to the private connection file, with no connection key or separately installed Node requirement. It targets this Mac’s current installation. See [Claude’s extension guide](https://support.claude.com/en/articles/10949351-getting-started-with-local-mcp-servers-on-claude-desktop).

For **other MCP clients**, expand **Advanced: other clients, HTTP & Terminal**. Copy STDIO JSON into their configuration editor. JSON is configuration, not a Terminal command. HTTP JSON contains a private key; keep it local. HTTP requires the app to run, and its generated address can change after restart.

For an already-installed **Claude Code CLI** or **Codex CLI**, select it under Advanced and choose **Copy command & open Terminal**. Click the prompt, press **⌘V**, review the command, then press **Return**. Opening Terminal does not paste or execute anything. Restart the server in your agent afterward. Commands use current installation paths and contain no key.

To revoke access, turn off **Let my agent use OpenTalon**. Resetting the key updates the bridge automatically; direct HTTP clients need fresh setup.

## Setup help

Use **Get App Help** in Settings or About OpenTalon to open or manage a support ticket. [Protomota Support for OpenTalon](https://protomota.com/support?app=opentalon)

## Verification boundary

The packaged app and installed Codex MCP runtime are tested in isolated profiles without changing personal registration. Exported Claude extensions are tested by unpacking and executing their bridge against the embedded server. Personal Claude installation or trust approval is not inferred from these tests.

### Claude extension startup compatibility

Current exports use a dedicated entry that starts when Claude imports it through the built-in runtime. The earlier November 10 bundle could install successfully but time out because a standalone-process startup guard skipped initialization. The installed copy and all supplied downloads were repaired, and Claude now discovers the full 19-tool catalog. No global permission changes or external Node installation are needed.

## Send a task to your default agent

Settings → Task agent supports both Claude Code and Codex. Choose a default and working folder, then move a task into Sent to agent. See [Send to agent](SEND-TO-AGENT.md) for the complete workflow. The current catalog has 24 tools, including report_agent_progress for return updates. Thread creation uses the selected installed launcher; MCP alone cannot force an arbitrary client to create a thread.


## Current personal Codex registration

At Brad’s request on November 10, Codex registered the packaged OpenTalon stdio bridge in the shared local Codex configuration. A fresh installed client read that saved entry, discovered all23tools and read the three existing boards without a model request or saved chat. This supersedes earlier statements that personal registration was unchanged. Existing app chats may need their MCP runtime refreshed to expose newly registered tools; new client sessions read the saved connection. No connection credentials belong in this repository.

Agents record work in Activity with `add_task_activity`. Comments are reserved for user-entered messages. Older `add_task_comment` clients are redirected to Activity. Read both streams for context.

When you have actually acted on a user comment, pass its `commentId` to `add_task_activity` and describe what changed. This links the report to the user comment. Do not acknowledge comments merely because you read them. `list_task_activity` accepts `commentId` for the related run/report and task changes. `list_task_comments` returns user comments only; earlier unattributed messages remain in Activity.

## Task plan documents

Save plans in `create_task.planMarkdown` or use `set_task_plan` with `id`, the exact `expectedMarkdown`, full new `markdown`, and a fresh `requestKey`. Read back `get_task.planMarkdown` to verify. Do not paste a plan or its path into Notes or Comments as a substitute. The native Plan section opens the task-ID `.md` document in Preview, with source editing and import/export. Version 1.0.20 recovers the latest complete legacy `--- Plan: ... ---` / `--- End plan ---` block into an empty Plan field; original notes, historical versions and existing Plan documents remain intact. Incomplete or fenced examples are not imported, and referenced paths are never read automatically.
