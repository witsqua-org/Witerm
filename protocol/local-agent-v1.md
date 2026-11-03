# Local Agent v1

The Mac background service (`witerm-agent`) hosts shells in a private tmux server and serves them over a Unix socket. The Mac app and the `witerm` command are local clients. The [relay](relay-v1.md) forwards a subset of the same messages to iOS, and those reach only shared sessions.

## Process and files

**Install path.** The service ships as `Witerm.app/Contents/Library/LaunchServices/WitermAgent.app` and runs through the LaunchAgent `com.witerm.agent` (with `AbandonProcessGroup=true`).

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
- **Typing.** Attachments in `control` mode are writers; several may share a session. Another writer is accepted only when every writer allows typing alongside: local clients always do, a paired device when its `access` entry says `co_typing` (an invitation's grant always does). Otherwise it gets `session_busy`; there is no forced takeover. Only writers type or resize.
- **Grid owner.** The first writer to attach, then whichever writer last typed, owns the grid. Input from a writer that doesn't own it first resizes the session to that writer's last requested grid (its attach or `resize` size), with the usual `geometry` frames, then delivers the input, but only once the owner has sent no input for 2 seconds, so interleaved keys never resize the session back and forth. Input with `automatic: true` (a terminal's own answer to a query in its output, such as tmux's on attach) is delivered without changing the owner. A writer joining others keeps their grid.
- **Sizing.** tmux uses manual window sizing and no status bar. Viewers attach with `read-only,ignore-size`.
- **Lifetime.** Disconnecting keeps the shell. Quitting the service detaches clients without killing sessions. Only `close` destroys a session.

**Limits.**
- 16 sessions and 32 connections.
- Input up to 16 KiB, JSON lines up to 64 KiB, output chunks up to 8 KiB.
- 256 KiB of pending output per connection. While a connection's queue is that full, the service stops reading the session's PTY for it, so tmux holds the output and coalesces the screen for that client; nothing is dropped and nothing is reordered. A client that takes nothing for 45 seconds is closed with `backpressure` and must reattach to get a redraw.
- Clients read the same way: past 1 MiB of unread output they stop reading the socket until their consumer catches up, and they give up (`backpressure`) only after 30 seconds without progress. Terminal bytes, commands, environment, and clipboard are never logged.

## Wire format

One UTF-8 JSON object per line, `version` 1. Byte fields are standard Base64, dates are RFC 3339 UTC, and IDs are lowercase UUIDs. Unknown versions, unknown operations, missing fields, and oversized lines are rejected.

**Requests** have `version`, `id` (a UUID echoed in the response), `operation`, and optionally `session_id`, `name`, `columns`, `rows`, `mode`, `data`, `cwd`, `shared`, `keep_private`, `remote_typing`, `access`, `guest`, `pairing_id`, `proof`, `history`, and `peer`.

| Operation | Fields | Reply |
|---|---|---|
| `status` | | `status` |
| `list` | optional `peer` | `sessions` (always an array) |
| `create` | `name` (1–64 scalars, no controls), `columns` 20–500, `rows` 5–200; optional `cwd`, `shared` | `session` with `sharing` |
| `close` | `session_id` | ok; ends only sessions this service created |
| `share` | `session_id` and at least one of `shared`, `keep_private`, `remote_typing` (`shared` and `keep_private` can't both be true) | `session` with `sharing` |
| `access` | optional `access` (`{device_id, scope: all\|shared, permission: view\|control, co_typing, session_ids?}`) to store first; every listed session must exist, at most 64 | `accesses`: every stored policy |
| `guest` | optional `guest` (`{pairing_id, session_id, permission, expires_at, key}`, key 32 bytes, at most 24 hours) to record, optional `pairing_id` to forget | `guests`, without keys |
| `redeem` | `proof` (32 bytes) and `peer` with `pairing_id` and `public_key` | ok, or `not_found` for any failure |
| `rename` | `session_id`, `name` (1–64 scalars, no controls) | `session` with `sharing`; the shell, attachments, and tmux's internal name are unchanged |
| `attach` | `session_id`, `columns`, `rows`, `mode` (`control` or `view`); optional `history`, `peer` | `session` and `mode`, then events |
| `input` | `data`, optional `automatic` (on an attached connection, writers only) | ok |
| `resize` | `columns`, `rows` (writers only) | ok, once the shell sees the new size; from a writer that doesn't own the grid, ok after recording it, preceded by a `geometry` frame with the grid in use when that differs |
| `detach` | | ok, after control is released; the connection then closes |

**Detach.** Once the `detach` acknowledgement arrives, another client can take control immediately. Late requests on the old connection can never regain it.

**Frames** have `version`, `kind` (`response`, `geometry`, `output`, or `closed`), and optionally `id`, `ok`, `error`, `status`, `sessions`, `session`, `mode`, and `data`.

- `status` is `{version, tmux_available, relays}`. `relays` has one `{server, state}` per server with remote access on, where `state` is `connecting` or `ready` (the server accepted this Mac); it is empty when remote access is off. Without tmux, `status` still answers and everything else returns `dependency_missing`.
- `session` is `{id, name, created_at, columns, rows}`. Local `list`, `create`, `share`, and `rename` replies add `sharing`: `{shared, keep_private, remote_typing, attachments: [{mode, device}]}`, where `device` is `{device_id, name}` for a paired device and absent for this Mac. Several attachments may have mode `control`. A `list` for a `peer` adds `access` (`view` or `control`) instead: the most that device may do there. A `list` for a paired device (not an invitation's guest) also adds `writers`: the others who can type in that session now, each `{name}` with the other paired device's name, or `{}` for this Mac (its app, another window, or the `witerm` command); never their keys or pairings. Older services omit it, and clients then say only that another device is typing.
- **History.** With `history: true` the client is a renderer with its own scrollback, never a real terminal. After the `attach` response (and any `geometry`) come `output` events holding up to 1,000 earlier lines (128 KiB) as VT with colors, each ending in a reset and CRLF, then as many line feeds as the grid has rows; then tmux's redraw. Nothing is sent while the pane is on its alternate screen. That attachment's stream never contains tmux's switch to or from the outer alternate screen (`ESC [ ? 1049 h/l`), so its output scrolls into the renderer's scrollback.
- The `attach` response always comes before the first output event.
- A session ending sends `closed`. A lost connection surfaces as a client error.

**Errors.** One of `invalid_request`, `unsupported_version`, `not_found`, `session_busy`, `read_only`, `dependency_missing`, `unavailable`, or `backpressure`. Raw process errors never appear.

**Not allowed.** There are no fields for executables, environment, or shell commands. The only caller-chosen launch detail is a local `create`'s start folder (`cwd`, under [Sharing](#sharing)).

## Sharing

Which paired devices reach a session is decided here, per device and per session. Each is stored in the state directory (0600) and survives restarts: `sharing.json` and `private.json` (session IDs), `device-access.json` (policies), `guests.json` (invitations). An unreadable file reaches less, never more. Pausing remote typing is kept in memory only.

- **`peer`.** Only the Mac's relay endpoint sends it, naming the paired device it acts for (`device_id`, `name`), the pairing of the grant the request arrived on (`pairing_id`), and that device's identity key (`public_key`). Remote devices can't set it: the relay accepts only the remote operations and fields in [relay-v1](relay-v1.md).
- **Reach.** A session kept private is reachable by nobody. Otherwise, a grant from a recorded invitation reaches only its session, once redeemed and until `expires_at`. Any other device reaches shared sessions, the sessions its policy lists in `session_ids`, and every session when its policy's `scope` is `all`. When a session ends, the service removes it from every `session_ids`, so a later session never inherits that access. A policy without `session_ids` lists none. A device without a policy has `{scope: shared, permission: control, co_typing: true}`.
- **Typing.** A device may type when its policy (or invitation) permission is `control` and the session's remote typing isn't paused; the relay endpoint further limits it to the signed grant.
- **With `peer`:**
  - `list` returns only reachable sessions, without `sharing`, with `access`.
  - `attach` to an unreachable session returns `not_found`; a control attach the device may not make returns `read_only`.
- **Narrowing** a policy, keeping a session private, stopping sharing, pausing remote typing, or an invitation expiring (checked every 2 seconds) closes exactly the paired-device attachments that are no longer allowed, with a `closed` frame carrying `not_found` (unreachable), `read_only` (may no longer type), or `session_busy` (may no longer type alongside). Local attachments and the shell keep running.
- **Invitations.** `guest` records an invitation before its link exists, so its grant never reaches more. `redeem` verifies HMAC-SHA256(key, `witerm-session-invite-v1\n<pairing_id>\n<public_key>`) in constant time, marks the invitation redeemed, and drops the key. The Mac's relay endpoint revokes grants of expired invitations and of ended sessions on the server, then forgets them.
- **Creating locally.**
  - `cwd` is the shell's absolute start folder. It must exist and be readable: a missing folder is `not_found`; a relative path, a non-directory, or `.`/`..` segments are `invalid_request`.
  - The service launches tmux *in* that folder instead of passing `-c`, because tmux expands formats there (`#{…}`, and `#(…)` runs a command). If tmux then reports a different start folder, the request fails.
  - The shell gets `WITERM_SESSION_ID` in its environment. No other environment is copied from the caller.
- **Never remote.** `create`, `close`, `share`, `rename`, `access`, `guest`, `cwd`, and `peer` can't arrive through the relay. Paired devices see a new name the next time they list sessions.

## Geometry

When the grid changes, every attached client gets a `geometry` frame carrying the full `session`, before the redraw at that size. A new controller attaching at a different size triggers the same frame. Viewers apply it directly and never send a resize back.

The geometry frame carries no `id`, `data`, `mode`, or `status`. The session's ID and creation date stay the same; its name is the current one, which a rename while attached may have changed.

The service confirms a resize only after the shell's PTY reports the new size. If it never does:
1. All of that session's connections close.
2. The session records the size the shell actually has.

Attaching always starts from the shell's real size. Shared examples: `fixtures/terminal-geometry-v1.json`.

## Swift client

`LocalAgentClient` in `packages/WitermCore` wraps the protocol. An attachment exposes either `events` (output plus geometry, used by renderers) or `output` (output only, for older callers), never both.

**Subscribe immediately.** Until a consumer subscribes, an attachment buffers at most 64 events. Overflowing that buffer closes the attachment.
