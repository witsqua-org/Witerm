# Local Agent v1

The Mac background service (`witerm-agent`) hosts shells in a private tmux server and serves them over a Unix socket. The Mac app is one client; the [relay](relay-v1.md) forwards a subset of the same messages to iOS.

## Process and files

**Install path.** The service ships as `WitermMac.app/Contents/Library/LaunchServices/WitermAgent.app` and runs through the LaunchAgent `com.witerm.agent` (with `AbandonProcessGroup=true`).

- It runs as the user, never as root, and both the app and the service are unsandboxed.
- The two share the App Group `group.com.witerm.$(DEVELOPMENT_TEAM)`.

**Arguments.**
- `--app-group <id>` uses that group container's `local/` directory.
- `--state-directory <path>` overrides it for development and tests.
- `--tmux-path` and `--shell-path` exist only for tests. tmux defaults to `/opt/homebrew/bin/tmux` or `/usr/local/bin/tmux`; the shell defaults to the user's login shell.

**State directory.**
- It must be owned by the user, mode 0700, and not a symlink.
- The service locks `agent.lock` before binding `agent.sock` (mode 0600).
- Both sides check the peer's user ID. A live socket is never removed.

**tmux.**
- Uses `tmux.sock` in that directory with `-f /dev/null`, separate from the user's own tmux.
- Sessions are named `witerm-<uuid>`. Display names live in `sessions.json`, never in tmux commands.
- Commands run from argument arrays, never shell strings.

## Terminal model

- **Viewers.** Each viewer is a normal tmux client on a real PTY. Attaching gives a full redraw, including alternate screens like vim and top. A text capture is never shown as the terminal.
- **Control.** One controller per session; extra viewers attach read-only. A second controller gets `session_busy`, and there is no forced takeover. Only the controller can type or resize.
- **Sizing.** tmux uses manual window sizing and no status bar. Viewers attach with `read-only,ignore-size`.
- **Lifetime.** Disconnecting keeps the shell. Quitting the service detaches clients without killing sessions. Only `close` destroys a session.

**Limits.**
- 16 sessions and 32 connections.
- Input up to 16 KiB, JSON lines up to 64 KiB, output chunks up to 8 KiB.
- 256 KiB of pending output per connection.
- A slow consumer is closed with `backpressure` and must reattach to get a redraw. Bytes are never dropped. Terminal bytes, commands, environment, and clipboard are never logged.

## Wire format

One UTF-8 JSON object per line, `version` 1. Byte fields are standard Base64, dates are RFC 3339 UTC, and IDs are lowercase UUIDs. Unknown versions, unknown operations, missing fields, and oversized lines are rejected.

**Requests** have `version`, `id` (a UUID echoed in the response), `operation`, and optionally `session_id`, `name`, `columns`, `rows`, `mode`, and `data`.

| Operation | Fields | Reply |
|---|---|---|
| `status` | | `status` |
| `list` | | `sessions` (always an array) |
| `create` | `name` (1–64 scalars, no controls), `columns` 20–500, `rows` 5–200 | `session` |
| `close` | `session_id` | ok; ends only sessions this service created |
| `attach` | `session_id`, `columns`, `rows`, `mode` (`control` or `view`) | `session` and `mode`, then events |
| `input` | `data` (on an attached connection, controller only) | ok |
| `resize` | `columns`, `rows` (controller only) | ok, once the shell sees the new size |
| `detach` | | ok, after control is released; the connection then closes |

**Detach.** Once the `detach` acknowledgement arrives, another client can take control immediately. Late requests on the old connection can never regain it.

**Frames** have `version`, `kind` (`response`, `geometry`, `output`, or `closed`), and optionally `id`, `ok`, `error`, `status`, `sessions`, `session`, `mode`, and `data`.

- `status` is `{version, tmux_available}`. Without tmux, `status` still answers and everything else returns `dependency_missing`.
- `session` is `{id, name, created_at, columns, rows}`.
- The `attach` response always comes before the first output event.
- A session ending sends `closed`. A lost connection surfaces as a client error.

**Errors.** One of `invalid_request`, `unsupported_version`, `not_found`, `session_busy`, `read_only`, `dependency_missing`, `unavailable`, or `backpressure`. Raw process errors never appear.

**Not allowed.** There are no fields for executables, working directories, environment, or shell commands.

## Geometry

When the grid changes, every attached client gets a `geometry` frame carrying the full `session`, before the redraw at that size. A new controller attaching at a different size triggers the same frame. Viewers apply it directly and never send a resize back.

The geometry frame carries no `id`, `data`, `mode`, or `status`. The session's ID, name, and creation date stay the same.

The service confirms a resize only after the shell's PTY reports the new size. If it never does:
1. All of that session's connections close.
2. The session records the size the shell actually has.

Attaching always starts from the shell's real size. Shared examples: `fixtures/terminal-geometry-v1.json`.

## Swift client

`LocalAgentClient` in `packages/WitermCore` wraps the protocol. An attachment exposes either `events` (output plus geometry, used by renderers) or `output` (output only, for older callers), never both.

**Subscribe immediately.** Until a consumer subscribes, an attachment buffers at most 64 events. Overflowing that buffer closes the attachment.
