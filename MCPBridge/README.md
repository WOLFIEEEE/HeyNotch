# HeyNotch native MCP bridge

Dependency-free Swift package for macOS 14+. Product: `heynotch-mcp`.

```sh
swift build --package-path MCPBridge -c release
swift test --package-path MCPBridge
python3 MCPBridge/tests/protocol_integration.py --binary MCPBridge/.build/release/heynotch-mcp
```

The executable accepts only `--connection /absolute/path/client.json` (or `--help`). The exported JSON contains `version: 1`, `endpoint: "http://127.0.0.1:49371"`, UUID `clientID`, and the private base64url `token`. Alternate canonical numeric loopback ports are accepted for isolated tests. The helper never starts HeyNotch or grants app permissions.

The endpoint is a private broker, not an HTTP MCP endpoint. The bridge converts MCP stdio calls to `POST /v1/command` with JSON `{tool, arguments}`, `Authorization: Bearer …`, and `X-HeyNotch-Client`. It disables redirects, proxies, cookies, and credential storage. App authorization remains authoritative on every command.

Limits: 16 KiB private credential file; 256 KiB newline-delimited input; 64 KiB encoded broker request; 2 MiB broker response; eight simultaneous calls; 30-second HTTP timeout. Credentials require current ownership, mode 0600, a regular file, a single hard link, and `O_NOFOLLOW` for the final component. Data is read from the validated descriptor and metadata is checked again afterward. stdout contains protocol messages only. Error diagnostics do not include the token.

The server implements MCP 2025-11-25 `initialize`, `notifications/initialized`, `ping`, `tools/list`, `tools/call`, and `notifications/cancelled`. It advertises no resources, prompts, logging, or background-task capability. Requests before initialization fail; notifications cannot trigger task writes; cancelled or shutdown calls emit no late response. A cancelled write may still commit in the app, so the client must reconcile its original operation ID. No command is automatically retried.

The release binary links system Swift/Foundation libraries; no Python/Node runtime is needed by the product. The parent app's build packages/signs the helper. This repository's GPL-3.0 license applies; preserve the root license and notices when distributing it.

## Verification

`swift test` covers private-file checks, link/FIFO rejection, endpoint/header validation, schema bounds, UTF-8 framing, lifecycle, concurrent requests, cancellation/reused-ID races, and shutdown.

`tests/protocol_integration.py` runs the actual native binary against a synthetic localhost broker with temporary credentials. It checks protocol/HTTP behavior, business errors, uncertain writes, no redirects, bounded responses, secret redaction, cancellation/reconciliation, body limits, and EOF. It accesses no Reminders/app data and changes no client settings.

An optional interoperability smoke test uses the official Python MCP SDK in a disposable environment:

```sh
python3 -m venv /tmp/heynotch-mcp-client-test
/tmp/heynotch-mcp-client-test/bin/pip install 'mcp>=1.26,<2'
/tmp/heynotch-mcp-client-test/bin/python MCPBridge/tests/official_sdk_smoke.py \
  --binary MCPBridge/.build/release/heynotch-mcp
```

Python is a test-only dependency. Run the smoke script with the same interpreter in which the SDK is installed. See [client setup](../docs/MCP_CLIENT_SETUP.md) for Codex and Claude configuration.
