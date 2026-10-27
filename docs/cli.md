# Command Line

`witerm` starts, shares, and attaches to Mac terminal sessions from any terminal. It talks to the same background service as the Mac app, so sessions, sharing, and control are the same whichever you use. A session you start from the command line appears in the app's sidebar at once, and the reverse.

## Install

In Witerm, open **Settings → Command Line** and choose **Install**. This links `~/.local/bin/witerm` to the copy inside the app, so the command updates with the app.

If your shell can't find `witerm`, add the folder to your `PATH`:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

The command needs the app's local terminal to be on (Settings → General).

## Commands

```sh
witerm new                 # Start a session in this folder and attach to it
witerm new --share         # ...and let paired devices reach it
witerm share               # Share the session you're in (or name one)
witerm unshare [session]   # Stop sharing; paired devices disconnect, the session keeps running
witerm sessions            # List sessions, sharing, and who is attached
witerm attach <session>    # Attach with control; --view to watch
witerm status              # Background service, tmux, and remote access
```

Name a session by its ID, a unique ID prefix (at least 4 characters), or its exact name. `new` names the session after the folder unless you pass `--name`.

**What `new` does.** It starts a *new* shell in the current folder. It can't take over the shell you typed it in, along with that shell's running programs or variables. Your environment and virtual environments aren't copied; the new shell starts from your login profile.

**Attached.** Your terminal's size becomes the session's size.

- Press Enter, then `~.` to detach. The session keeps running.
- `~?` lists escapes, and `~~` types a `~`.
- `--escape <char>` picks a different escape character; `--escape none` turns escapes off.
- Detaching, suspending, or closing the window always restores your terminal.

**Control.** One device controls a session at a time. If another device has control, `attach` stops with exit code 5 rather than taking over; use `--view` to watch. Detaching releases control at once, so a phone can take it.

## Sharing

Sessions are private until shared. Sharing lets **already paired** devices list and open the session, within the permission each device was granted. The command line never pairs or approves devices; do that in the app.

`share` reports what is actually true:

| Remote access | Meaning |
|---|---|
| `ready` | A server has accepted this Mac. Paired devices can open the session now. |
| `waiting` | Allow Remote Access is on, but no server has accepted the Mac yet. |
| `off` | Allow Remote Access is off. The session is shared but nobody can reach it. |

`witerm share --wait 30` waits up to 30 seconds for `ready`.

**Ending things.**
- Detaching leaves you, and the session keeps running.
- `unshare` disconnects paired devices, and the session keeps running.
- Only **End Session** in the app ends the shell and its programs.

## Scripting

- `--json` prints one JSON value on stdout and never attaches.
- Errors go to stderr as `{"error":{"code","message","exit"}}`.
- Nothing is interactive unless you are attaching in a real terminal.
- `WITERM_AGENT_SOCKET` (or `--socket`) points at a different service socket, for development.

| Exit code | Meaning |
|---|---|
| 0 | Success |
| 1 | Other failure |
| 2 | Usage error, or a request the service rejected |
| 3 | Background service unavailable or not installed |
| 4 | No such session or folder |
| 5 | Another device controls the session |
| 6 | tmux isn't installed |
| 7 | `--wait` ended before remote access was ready |

Example:

```sh
id=$(witerm new --share --detach --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["session"]["id"])')
witerm share "$id" --wait 30 && echo "Open it on your phone"
```

## Testing

```sh
swift test --package-path apps/mac-agent --filter CLI
```

The tests run the real `witerm` binary against a private broker and tmux server. One drives `attach` through a real pseudo-terminal: it types, resizes, detaches with `~.`, and checks that the terminal is restored and control released.
