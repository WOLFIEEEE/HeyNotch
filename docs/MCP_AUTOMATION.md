# HeyNotch task automation

HeyNotch exposes task tools to local MCP clients through a bundled native executable. The app owns the Reminders connection and task changes; the executable translates MCP messages into authenticated commands to the running app.

## User setup

1. Install the signed HeyNotch app in a stable location, normally Applications, and open it.
2. Connect Apple Reminders in **Settings → Tasks**.
3. Open **Settings → Agent access** and enable access.
4. Name a connection, select its lists, choose read-only or read/write access, and choose **Create connection…**. Save the connection file in a private local folder.
5. Choose Codex, Claude Code, or Claude Desktop and copy the generated setup. Each connection should belong to one client. Keep HeyNotch open while using it.

The connection file contains a bearer credential, is exported with owner-only permissions, and must not be committed to source control or shared. Client setup commands include its path, not its contents. The app stores its copy of each secret in Keychain. Revoke a connection to invalidate all exported copies immediately. Existing user/client tool approvals still apply.

See [MCP client setup](MCP_CLIENT_SETUP.md) for client-specific instructions and troubleshooting.

## Tools

| Tool | Behavior |
| --- | --- |
| `get_context` | Current time, timezone, client identity, allowed lists, and write permission. |
| `list_task_lists` | Lists available to this connection. |
| `find_tasks` | Scoped search with completed filter and bounded pagination. |
| `get_task` | Canonical task, kanban column, and revision. |
| `create_task` | Create in an explicitly selected list; verify saved contents. |
| `update_task` | Edit title, notes, due date, or alarms with a matching revision. |
| `move_task` | Move to To do, Doing, or Done; Doing is local to this Mac. |
| `set_task_completed` | Complete or reopen a task with a matching revision. |
| `get_operation` | Recover a previous operation's outcome after a timeout or lost response. |

No shell, file browsing, recording, provider-key, deletion, or permission-granting tools are exposed. The connection never prompts for Reminders permission from a background tool request. Repeating reminders must be completed or reopened in Apple Reminders, where the next occurrence can be handled correctly; the tool returns an explicit error for that case.

## Dates and revisions

Dates are structured calendar components. A date-only due date contains `year`, `month`, and `day`. A timed date must also include `hour`, `minute`, and an explicit `timeZoneIdentifier`. Invalid dates and nonexistent local times are rejected. Clients resolve relative language using `get_context` and should clarify ambiguous intent.

Edits, kanban moves, and completion require the revision returned by a recent read. A changed task produces `revision_conflict` instead of silently overwriting a known stale state. UI and agent mutations share a per-task queue. EventKit has no global compare-and-swap operation across every Reminders client; an external app can still change a reminder during a write. Saved values are read back before success is acknowledged.

## Retry and recovery contract

Every write requires a UUID `operationID`, scoped to its connection. The app saves a durable journal entry before invoking the repository. Repeating that ID with identical arguments returns its original response. Reusing it with different arguments fails. A separate internal UUID prevents collisions between two clients using the same operation ID.

If a write might have happened but cannot be verified or its result cannot be persisted, it is marked uncertain. **Do not retry with a new operation ID.** Query `get_operation`, inspect the task, and resolve the uncertainty. A pending entry recovered after restart stays uncertain and is never automatically re-executed. An MCP cancellation or transport timeout does not imply rollback.

The journal runs on a separate actor so file reads, JSON encoding, and fsync do not block the UI actor. It is bounded to 10,000 operations or 64 MiB and rejects new writes if full instead of forgetting active idempotency keys. Revoking a connection also retires its journal namespace, freeing capacity. Revocation takes effect before cleanup, including when cleanup fails.

## Transport and access boundaries

The MCP executable uses newline-delimited JSON-RPC over stdio. It accepts a private connection file, validates its owner/type/permissions, and connects only to a canonical numeric loopback address. It disables redirects, proxies, cookie storage, and credential challenges. It never logs the credential or automatically retries writes.

The app's private broker binds only `127.0.0.1:49371`. It accepts authenticated `POST /v1/command` requests with bounded headers/body/connections, rejects browser Origin headers and ambiguous HTTP framing, and closes idle connections. This broker is an internal transport, not a public Streamable HTTP MCP endpoint. The listener is disabled by default and has no background polling. Turning access off closes it. The existing XPC insertion helper's signing/trust boundary is unchanged.

Authorization is checked after queueing and asynchronous reads, before mutations after journal persistence, and before returning task details. A write already committed at revocation time may finish; its response is withheld from a revoked client. Bearer credentials protect against unauthorized callers, but do not create isolation from malicious software already running as the same user with access to the exported file.

## Build and verification

The Xcode app build compiles `MCPBridge` for the requested architectures, embeds `Contents/Helpers/heynotch-mcp`, and signs it. The release-candidate script requires a universal Developer ID signed helper with hardened runtime. There is no Node or Python runtime dependency for normal app/connector usage.

The test suite includes an isolated in-memory task repository and an actual stdio subprocess → HTTP broker → task engine → readback round trip across all nine tools. Build the debug bridge before running that integration test:

```sh
swift build --package-path MCPBridge
swift test --package-path MCPBridge
xcodebuild test -project HeyNotch.xcodeproj -scheme HeyNotch \
  -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

The fixture does not touch personal reminders or production Keychain items. Native Codex/Claude setup against a user's real list is a separate acceptance check after the user grants list access. Protocol/fixture success alone does not establish that a real client has been installed or paired.
