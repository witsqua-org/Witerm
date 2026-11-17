# Orbit v1

`witerm orbit serve` runs Orbit, Witerm's assistant, on the Mac. Its local clients are the Mac app and `witerm mcp` (for agents that guide or take over Orbit's tasks). Design and context management: [docs/orbit.md](../docs/orbit.md).

## Process and files

- **Starting.** It runs from `Witerm.app/Contents/Helpers/witerm`, started by the app at launch (with a key in the Keychain) or when Orbit is opened, by `witerm mcp` for an agent, or by the relay endpoint for a paired device. It runs as the user, in its own session (`setsid`), and exits after 15 minutes with no thread running and no requests. There is no LaunchAgent.
- **Folder.** `orbit/` in the app group container (beside the terminal service's `local/`), or `WITERM_ORBIT_DIRECTORY` for development and tests. It is mode 0700, owned by the user, and never a symlink.
- **One instance per folder.** It holds `orbit.lock` (`flock`). A second instance exits with status 0, and a socket left by a dead instance is replaced.
- **Socket.** `orbit.sock`, mode 0600. Both sides check the peer's user ID (`getpeereid`).
- **Threads.** `threads/<id>.json`, mode 0600, replaced atomically.
  - Threads untouched for 30 days are removed when Orbit starts. At most 200 are kept.
  - A thread that was running when Orbit stopped loads as `stopped` (a task) or `idle` (a chat).
- **What isn't stored.** The API key is never written anywhere; Orbit holds it in memory only. Nothing is logged.
- **Development only.** `WITERM_ORBIT_OPENAI_URL` points Orbit at another Responses endpoint. It must be HTTPS, or HTTP on this Mac only.

## Wire format

- **One exchange per connection.** The client sends one UTF-8 JSON line (at most 4 MiB), Orbit sends one line back, and the connection closes.
- **Encoding.** `version` is 1, dates are RFC 3339 UTC, and IDs are lowercase UUIDs.
- **Requests** have `version`, `id` (echoed in the reply) and `operation`. Optional fields: `thread_id`, `text` (1 byte to 32 KiB after trimming), `kind` (`chat` or `task`), `terminal_id`, `api_key`, `model`, `agent` (1–64 characters, no controls) and `success`.
- **Replies** have `version`, `id` and `ok`, and optionally `error`, `status`, `threads` and `thread`.

| Operation | Fields | Reply |
|---|---|---|
| `status` | | `status` |
| `configure` | optional `api_key` (printable ASCII, at most 512; empty forgets the key), optional `model` (letters, digits, `.-_:`, at most 64) | `status` |
| `threads` | | `threads`, most recently updated first |
| `thread` | `thread_id` | `thread` |
| `start` | `text`, `kind`, optional `terminal_id` (the terminal "this terminal" means) | `thread`; a run starts |
| `send` | `thread_id`, `text`, optional `agent` | `thread`. The message is read at the run's next step, or starts a run. It is `busy` when another agent has taken the thread over. A message from the user, or from the agent holding the thread, gives the thread back to Orbit. |
| `stop` | `thread_id` | `thread`; the run ends (`stopped` for a task, `idle` for a chat) |
| `take_over` | `thread_id`, `agent` | `thread` with status `taken_over`; Orbit's run ends. It is `busy` when another agent holds the thread. |
| `finish` | `thread_id`, `agent` (the one holding it), `text` (summary), optional `success` | `thread`, `done` or `failed` |
| `delete` | `thread_id` | ok; a running thread stops first |
| `clear` | | ok; every thread stops and is deleted |

**Errors:** `invalid_request`, `unsupported_version`, `not_found`, `busy`, `unavailable`.

**Objects:**
- `status` is `{version, has_key, model, running}`.
- `threads` entries are `{id, title, kind, status, terminal_id?, updated_at, revision, taken_over_by?}`. `revision` grows with every change, so clients refetch only what changed.
- `status` values: `idle`, `running`, `waiting` (Orbit needs the user, or a task ended without finishing), `done`, `failed`, `stopped`, `taken_over`.
- `thread` is `{summary, plan, entries, earlier_entries, usage, memory?}`:
  - `plan` holds the steps Orbit last set: `{text, status: pending|active|done}`, at most 20.
  - `entries` holds at most the latest 300 entries; `earlier_entries` counts those left out.
  - `usage` is `{input_tokens, cached_tokens, output_tokens}`, summed over the thread.
  - `memory` is Orbit's own summary of turns it no longer sends verbatim.
- **Entries** are `{id, at, kind, …}`. They're what people see; tool output beyond a 2,000-character excerpt and reasoning stay in the thread's file. By `kind`:
  - `user`: `text`, and `from` when an agent sent it.
  - `assistant`: `text`.
  - `action`: `tool`, `terminal` (a name), `command` (what was run or typed), `detail` (the excerpt) and `failed`.
  - `note`: `note`, which is `stopped`, `taken_over`, `finished_by_agent`, `step_limit` or `summarized`, with `from` and `text` where they apply.
  - `error`: `failure`, which is `missing_key`, `key_rejected`, `limited`, `api`, `network` or `terminals_unavailable`, with the API's message in `text`.
- **Localization.** Notes and failures are names, not words, so the app shows them in the user's language.

Example: `fixtures/orbit-v1.json`.

## From paired devices

Orbit's socket is reachable only on this Mac. Since Round 32 the Mac's relay endpoint forwards a narrow part of it for paired devices that may type in every terminal: `status`, `threads`, `thread`, `start`, `send` and `stop`, never `configure`, `take_over`, `finish`, `delete` or `clear`, and never an `api_key`, `model`, `agent` or `success` field. See [relay-v1](relay-v1.md#orbit). The endpoint starts Orbit when it isn't running and gives it the user's Keychain key when it has none.
