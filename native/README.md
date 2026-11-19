# Native apps

The SwiftUI Mac app uses a bundled Node.js service for SQLite, local agents and MCP. The iPhone and iPad app communicates with the Mac through a private iCloud database.

The [project README](../README.md) has the build and test commands. For development, an ad hoc Mac build and a separate local profile let you try OpenTalon without opening an existing workspace. A device build that uses iCloud needs a CloudKit container and provisioning under your own Apple Developer team.

The Mac applies queued mobile changes while OpenTalon is running. Agent requests need a supported agent installed and configured on the Mac. See the [agent task guide](../docs/SEND-TO-AGENT.md) for the workflow and the [backup guide](../docs/BACKUPS.md) for keeping your data.

## Plans and Apple Intelligence

Each task has a **Plan** section after Notes and Definition of Done. Open it to preview Markdown, edit the source, or import/export a UTF-8 `.md` file. New tasks can include a plan. Plans stay with their task through project changes, Archive, Trash, restore and full backups, and are included when sending the task to an agent.

On supported devices with Apple Intelligence enabled, **Proofread** and **Revise plan** generate a proposed revision. Review it, choose **Apply to draft**, then **Save**. Cancel preserves the saved plan; interrupted editing keeps a local draft. A conflicting edit from another device is rejected without overwriting it. Manual editing remains available when the on-device model is unavailable.

On iPhone and iPad, the sparkle button opens **Ask OpenTalon**. Ask about tasks, create a task or project, change a task's fields, or propose a plan revision. Ordinary edits save locally and queue for the Mac. Sending to an agent opens the agent/model/comment dialog; Archive and Trash keep their confirmation flows. Chat history is local, with new chats, individual deletion and delete-all controls. Deleting chat history does not delete tasks or plans. Both devices need the updated app for plan synchronization. Apple Intelligence requires supported hardware and OS version 26 or later; no remote model is used as a fallback.


## Issue types and revision history

Tasks can be **Issue** or **Bug**. Bug labels appear on cards and details, and the type is included in the agent handoff. Creating a Bug does not send it to an agent automatically.

**View revision history** in task details shows saved changes to fields, project, status, order and the Markdown plan. Preview a revision before restoring it. A restore creates a new entry and retains newer history and current comments. It stops active agent work and reopens archived tasks; a saved Sent to agent status restores as To do. Restore a trashed task before restoring its fields. Existing tasks start with a migration baseline; edits made before this update cannot be reconstructed.

History is stored in the Mac's SQLite database and both full backup formats. Mobile syncs the newest revision and can request older pages from the Mac. Cached revisions remain readable offline; older pages and acknowledged restores require the Mac to be online. History is removed only when its task is permanently deleted or the workspace is replaced from a backup.

## Task Activity and user Comments

Task details separate **Activity** from **Comments** on Mac, iPhone and iPad. Activity automatically records task edits, moves, ordering, Archive/Trash actions, agent pickup and progress. Open **View all activity** for the timeline, expandable details and older entries. **View revision history** remains available for previewing and restoring saved task content.

Comments are only messages explicitly entered by the user. Agents use `add_task_activity` for updates and `report_agent_progress` for completion proof. Existing `add_task_comment` clients are redirected to Activity. Known older agent reports and screenshots are migrated to Activity; older messages without reliable authorship are preserved there as earlier messages. Activity and screenshots survive JSON and SQLite backups. Both the Mac and mobile app need this update for Activity synchronization.

The task’s main view keeps Activity collapsed behind **View activity**. Only user comments appear inline. **Acted on · View activity** opens the response and recorded task changes associated with that comment, without unrelated runs. Pickup alone is not treated as acted on. Older snapshots without reliable authorship keep their mixed messages behind **View earlier activity**. Comments explicitly written on this phone remain visible after acknowledgement from an older Mac. Update both apps for linked comment activity.

Saved plans appear as task-ID `.md` documents in **Plan**, with one-click Preview and Markdown editing. Version 1.0.20 recovers the latest complete legacy plan block copied into Notes when Plan is empty. Source notes and previous revisions are preserved; existing Plan documents are never replaced.

## First launch on iPhone and iPad

New installs show a short introduction to task boards, plans and agents, followed by Mac setup: install OpenTalon on an Apple silicon Mac with macOS 14 or later, use the same Apple Account with iCloud Drive, and keep the Mac app open. Agent setup is optional. The guide can be skipped and reopened from **Settings → Support → Getting started**. Existing installations with a saved workspace continue directly to their tasks.

Before the first Mac sync, **Get started** provides the Mac download, setup guide, sync status and a **Save an idea** editor. One starter idea is stored on that device and survives relaunch. After the Mac connects, **Create task** opens the normal task editor with that idea prefilled. Cancel keeps the idea; successfully queueing the task clears it. Saving the idea alone does not create a project, sync it or dispatch an agent.
