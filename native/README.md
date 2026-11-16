# Native apps

The SwiftUI Mac app uses a bundled Node.js service for SQLite, local agents and MCP. The iPhone and iPad app communicates with the Mac through a private iCloud database.

The [project README](../README.md) has the build and test commands. For development, an ad hoc Mac build and a separate local profile let you try OpenTalon without opening an existing workspace. A device build that uses iCloud needs a CloudKit container and provisioning under your own Apple Developer team.

The Mac applies queued mobile changes while OpenTalon is running. Agent requests need a supported agent installed and configured on the Mac. See the [agent task guide](../docs/SEND-TO-AGENT.md) for the workflow and the [backup guide](../docs/BACKUPS.md) for keeping your data.
