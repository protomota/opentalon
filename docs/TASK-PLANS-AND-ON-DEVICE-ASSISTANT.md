# Plans and an on-device assistant

Shared implementation brief for OpenTalon and Inkspring. Requested by Brad on November 18, 2026 in the OpenTalon chat. OpenTalon owns task behavior; Inkspring should use the same document and interaction conventions for its own content. This brief describes requested work, not a completed feature.

## Plan document

- One optional UTF-8 Markdown document per task/content item, presented in a section named **Plan**, never Attachments.
- OpenTalon places Plan after Notes and Definition of Done, before comments and the bottom Archive/Trash controls. Show the section even when empty, with Create plan and Import Markdown actions.
- Task creation offers Include a plan. A request such as “create a task with a plan” should select it automatically. Keep Notes as the summary and Definition of Done as observable checks; put the detailed steps in Plan.
- Open a plan in rendered preview mode. Support headings, paragraphs, ordered/unordered lists, checklists and code blocks. Preview must not execute embedded HTML or scripts or load remote images automatically.
- A Preview/Markdown control switches to a source editor. Cancel is at the top right; Save is below the editor, with matching right edges and the app's existing themed pill style. Preserve unsaved text through interruptions and show save errors without losing the draft.
- Import and export actual `.md` files named from the item's user-facing ID. Copy imports into app-managed storage; do not depend on the original file's path or ongoing external-drive access.
- Plans must survive restart, project moves/ID changes, Archive, Trash, restore and full backup/export/import. Permanent deletion follows the parent item's explicit deletion flow.

## AI editing

- Provide Proofread and an instruction field such as “Add a testing checklist” or “Break this into smaller steps.” Use Apple Intelligence locally through Foundation Models and enable native Writing Tools in the editor.
- Generate a candidate without replacing the saved plan. Show the proposed document with Apply and Discard, preserving the original until Apply succeeds. Keep a previous revision for undo; reject a stale apply if another device changed the plan and retain both versions for review.
- Proofreading preserves facts, task intent, links and Markdown structure. Instructions to revise the plan must not silently mutate other task fields or dispatch agents.
- Clearly report unavailable Apple Intelligence, disabled settings, model readiness, cancellation, long-context limits and generation errors. Manual plan editing always works. Do not silently send content to a remote provider.

## In-app assistant chat

- Use **Ask OpenTalon** / **Ask Inkspring** with the same themed layout, message composer, progress/cancel state and action-result cards. Mobile is explicitly requested; match the pattern on Mac where supported.
- Use the system's available on-device Apple Intelligence model, with structured generation/tool calling. Build the assistant on existing application APIs, not arbitrary SQL, shell execution, filesystem paths or raw model-generated code.
- OpenTalon actions: find/read tasks, create tasks and projects, change project/priority/status/due date/notes, and create/revise a plan. Resolve user-facing IDs case-insensitively and display normalized uppercase IDs. Ask which task when a description is ambiguous; do not guess.
- Ordinary, reversible, explicitly requested edits can execute directly. Report the actual result and link to the affected item. Distinguish local save, queued-for-Mac and Mac-applied states; never claim the Mac applied an offline change.
- Plan revisions use the same proposed-document Apply/Discard flow. Agent dispatch must open the existing full agent/model/comment modal; chat must not bypass it. Trash/Archive keep the existing themed confirmation, and permanent or bulk deletion requires an exact reviewed confirmation.
- Treat notes, plans and task titles as untrusted content, not instructions to control the app. Enforce action validation, target IDs, field limits, supported operations and workspace identity in application code.
- Keep chat history locally, allow New chat, delete individual chats and delete all chat history. Do not delete user tasks or plans when deleting chat history.
- Inkspring uses its own equivalent content/project actions. Publishing, scheduling public posts, sending messages and spending money retain Inkspring's existing explicit authorization/review flows.

## Persistence and synchronization

- Use stable internal item IDs for plan identity. User-facing project/task IDs may change without breaking the plan.
- Store the Markdown content and document revision durably with the parent record, with a real `.md` representation for preview/import/export. Include it in existing backup and migration paths.
- Add versioned optional plan fields and capability flags to Mac/mobile sync. Older data decodes with no plan; an older desktop cannot receive an unsupported command silently.
- Mobile edits project immediately through the durable local queue, just like other task edits. Acknowledgements clear pending state only at the applied snapshot revision. Concurrent plan edits use document-level expected revisions or previous-content checks, not a workspace-wide lock.
- Include the current plan in agent dispatch context and MCP read/update operations so desktop agents work from the same plan the user reviewed.

## Acceptance

1. Create with a plan, open preview, edit Markdown, cancel without saving, save, restart and reopen.
2. Import/export `.md`; verify headings, lists, checklists, code, Unicode and long documents without executing HTML or loading external content.
3. Proofread/revise, review candidate, discard, apply, undo, cancel generation and recover from model errors. Real Apple Intelligence must be tested on a supported device; a simulator/mock is not proof of model execution.
4. Chat creates and updates the correct item; ambiguous targets ask for clarification; invalid actions, prompt injection and unsupported commands cannot mutate data.
5. Offline mobile save remains visible, reconnect applies once, repeated requests are idempotent, stale edits preserve both versions and Mac/mobile agree after sync.
6. Archive/Trash/restore, project moves and JSON/SQLite backups preserve the plan and its association.
7. Capture actual iPhone, iPad and Mac screenshots plus a workflow recording. Show Brad the changes before publishing new TestFlight builds. Keep the two apps' labels, layout, editing flow and AI review states consistent.

## References

- Apple Foundation Models: https://developer.apple.com/documentation/foundationmodels
- Tool calling: https://developer.apple.com/documentation/foundationmodels/tool
- SwiftUI Writing Tools: https://developer.apple.com/documentation/swiftui/writingtoolsbehavior
- OpenTalon's existing on-device drafting: `native/CompanionCore/Sources/CompanionCore/TaskDrafting.swift`.
