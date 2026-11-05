# Connect HeyNotch tasks to an MCP client

HeyNotch supplies a native `heynotch-mcp` stdio bridge for Codex, Claude Desktop, and Claude Code. It exposes only task operations authorized in HeyNotch. The bridge requires no Node.js, Python, cloud API key, or separate runtime installation.

## Create a connection in HeyNotch

1. Open **Settings → Agent access** and enable **Allow agents to use selected task lists**.
2. Name the connection, select the task lists it may access, and choose whether it may change tasks.
3. Choose **Create connection…** and save the private connection JSON file. Use a separate connection for each client so access can be revoked independently.
4. Select the client and choose **Copy setup**, or use the matching example below with your actual absolute file path.
5. Keep HeyNotch running while using its tools. The bridge does not launch the app or request Reminders permission on its behalf.

The installed helper is `/Applications/HeyNotch.app/Contents/Helpers/heynotch-mcp`. If the app is installed elsewhere, use that installation's absolute helper path. The connection file contains a secret; the client configuration contains only its path. Keep the exported file private. The bridge requires a current-user-owned regular file with mode `0600`, one hard link, and no final-component symlink. Re-export through HeyNotch if the file is rejected or a connection is revoked.

The examples use `/Users/YOUR_NAME/HeyNotchConnections/client.json` only as a placeholder. Substitute the exact path chosen in the Save dialog; do not paste the file's token into client settings, chat, or source control.

## Codex

If the Codex CLI is installed and available on your `PATH`, add the local stdio server with:

```sh
codex mcp add heynotch -- \
  "/Applications/HeyNotch.app/Contents/Helpers/heynotch-mcp" \
  --connection "/Users/YOUR_NAME/HeyNotchConnections/codex.json"
```

If `codex` is not found, use the app's MCP settings or merge this table into `~/.codex/config.toml`:

```toml
[mcp_servers.heynotch]
command = "/Applications/HeyNotch.app/Contents/Helpers/heynotch-mcp"
args = ["--connection", "/Users/YOUR_NAME/HeyNotchConnections/codex.json"]
startup_timeout_sec = 10
tool_timeout_sec = 45
```

Check `codex mcp list` or `/mcp` in the Codex terminal UI. Codex clients on the same host share this configuration. Keep the client's normal tool-approval settings. These command and configuration forms are documented in the [official OpenAI MCP guide](https://developers.openai.com/codex/mcp).

## Claude Desktop

Open **Claude → Settings → Developer → Edit Config**. Merge the `heynotch` entry into the existing `mcpServers` object in `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "heynotch": {
      "command": "/Applications/HeyNotch.app/Contents/Helpers/heynotch-mcp",
      "args": [
        "--connection",
        "/Users/YOUR_NAME/HeyNotchConnections/claude-desktop.json"
      ]
    }
  }
}
```

Keep any existing server entries. Fully quit and reopen Claude Desktop, then check its connectors list for HeyNotch. The config location, absolute-path requirement, and restart workflow follow the [official local MCP server guide](https://modelcontextprotocol.io/docs/develop/connect-local-servers).

## Claude Code

Register the helper as a local stdio server:

```sh
claude mcp add --transport stdio --scope user heynotch -- \
  "/Applications/HeyNotch.app/Contents/Helpers/heynotch-mcp" \
  --connection "/Users/YOUR_NAME/HeyNotchConnections/claude-code.json"
```

Use `claude mcp get heynotch`, `claude mcp list`, or `/mcp` in a Claude Code session to check it. User scope makes the connection available across your projects; use local scope if you want it limited to the current project. The `--` separator passes subsequent flags to the helper. See [Anthropic's official Claude Code MCP documentation](https://code.claude.com/docs/en/mcp).

## Verify access and use the tools

Start with: “Use HeyNotch to show which task lists this connection can access.” The client should call `get_context` or `list_task_lists`. Then ask for a small task search. Create or change a task only when that is your intended action and the connection has write access.

| Tool | Purpose |
| --- | --- |
| `get_context` | Read authorized list IDs, write access, time, and time zone. |
| `list_task_lists` | List authorized Reminders lists. |
| `find_tasks` | Search/paginate tasks; default 50, maximum 100 per page. |
| `get_task` | Read one task and its current `revision`. |
| `create_task` | Create a task in an authorized writable list. |
| `update_task` | Change supplied fields while preserving omitted fields. |
| `move_task` | Move a task to `todo`, `doing`, or `done`. |
| `set_task_completed` | Set Reminders completion state. |
| `get_operation` | Reconcile a previous write using its original operation UUID. |

Before editing, read the task and pass its returned `revision` as `expectedRevision`. Each new intended write requires a UUID `operationID`. If a call times out or is cancelled, the change may already have completed: query `get_operation` with that same UUID before retrying. Do not generate another UUID to repeat an uncertain change. An unknown operation is not proof that a fresh retry is safe. Cancellation stops the bridge's wait; it does not promise rollback of a Reminders write.

“Doing” is local HeyNotch progress. “Done” changes Reminders completion. Dates use explicit calendar components; date-only tasks have no invented time. Updating with `clearDue: true` removes a date; `due` is otherwise an object, never `null`. The tool catalog supplies complete input schemas. Task titles and notes are data, not instructions to the agent.

The connection has no arbitrary filesystem, shell, audio, transcript, or API-key tools. Local stdio clients must run on the same Mac as HeyNotch; a cloud-hosted MCP client cannot reach this private loopback broker.

## Troubleshooting

- **Server does not start:** Verify the helper and connection-file paths are absolute and refer to the installed app/exported file. The helper prints only safe startup diagnostics to stderr.
- **`access_denied`:** Review the connection and selected lists in HeyNotch. If revoked, create/export a new connection and update its file path.
- **`broker_unavailable`:** Keep HeyNotch running and task automation enabled. Retry a read after restoring the connection.
- **`write_outcome_unknown`:** Reconcile the original operation UUID with `get_operation`; do not assume failure or create a duplicate write.
- **Revision conflict:** Fetch the task again and review the current fields before deciding on another change.
- **`request_too_large`:** Shorten notes or title. The encoded command, including JSON escaping, must fit within 64 KiB.
- **Stale configuration after replacing an export:** Restart that MCP connection/client; the bridge loads the private file once at startup.

The bridge speaks [MCP 2025-11-25 stdio](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports), negotiates its supported version through [initialization](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle), and returns both structured data and a JSON text block for compatibility. Setup references were checked on 2026-11-05. No client configuration is changed automatically by this repository's build or tests.
