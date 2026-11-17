# AI Agents (MCP)

`witerm mcp` lets AI agents such as Codex and Claude Code read and drive this Mac's Witerm terminals. It is a [Model Context Protocol](https://modelcontextprotocol.io) server on stdin and stdout. The agent starts it as a subprocess, and it talks to the same background service as the app and the `witerm` command. Everything an agent does happens in real Witerm terminals, so the user can watch it live in the app (or on a paired phone) and type into the same terminal at any time.

Orbit, Witerm's own assistant, uses the same tools with the user's OpenAI API key ([orbit.md](orbit.md)). Through the Orbit tools below, an outside agent can also see Orbit's tasks, guide one, or take one over.

## Setup

Install the command first (Witerm → Settings → Command Line → Install). The local terminal must be on.

**Codex** (`~/.codex/config.toml`):

```toml
[mcp_servers.witerm]
command = "/Users/you/.local/bin/witerm"
args = ["mcp"]
# Optional. Without it, Codex asks before each tool that types or ends a
# terminal (`codex exec` can't ask, so those calls fail there).
# default_tools_approval_mode = "approve"
```

or `codex mcp add witerm -- ~/.local/bin/witerm mcp`.

**Claude Code:** `claude mcp add witerm -- ~/.local/bin/witerm mcp`.

Use `witerm mcp --read-only` to offer only the reading tools.

## Tools

| Tool | What it does | Annotations |
|---|---|---|
| `list_terminals` | Every terminal: ID, name, size, folder, foreground program (none at the prompt), and who has it open | read-only |
| `read_terminal` | The screen as plain text. After the first look at a terminal, only what changed since (`full` for the whole screen), or up to 10,000 earlier lines with `history_lines` | read-only |
| `wait_for_terminal` | Waits until text appears on the screen, or until the prompt is back and the screen has settled; returns what changed | read-only |
| `run_command` | Types one command line at a shell prompt, presses Return, waits for the prompt (default 30 s, at most 600 s), and returns only the output since that command | destructive |
| `send_input` | Types text, then named keys (`enter`, `tab`, `escape`, arrows, `ctrl-c`, …), and returns what changed on the screen | destructive |
| `create_terminal` | Starts a terminal (named after the agent by default, in the home folder, 120 × 32 until a window attaches) | |
| `close_terminal` | Ends a terminal, but only one this connection created | destructive |
| `list_orbit_tasks`, `read_orbit_task` | Orbit's conversations and tasks: status, plan, memory, latest messages and actions | read-only |
| `guide_orbit_task` | Sends Orbit a message signed with the agent's name; Orbit reads it at its next step | |
| `take_over_orbit_task` | Stops Orbit working on a task, so the agent continues it with the terminal tools | destructive |
| `finish_orbit_task` | Marks a task the agent took over done or failed, with a summary for the user | |

The Orbit tools appear when `witerm mcp` runs from the installed app (or with `WITERM_ORBIT_DIRECTORY`). They answer "Orbit isn't running" until the user opens Orbit.

Terminals are named the way the command names them: ID, a unique ID prefix of at least 4 characters, or exact name.

**How `run_command` knows a command finished.** The service reports the terminal's foreground process group from the kernel (the `folder` request), so "at the prompt" means the shell itself is in the foreground again. `run_command` waits until that is true, the cursor has moved below the command's line, and the screen is unchanged for two looks 200 ms apart. A command that clears the screen counts as done once the prompt has been back for a second. The exit status isn't reported. An agent that needs it appends `; echo "exit=$?"`. A command still running at the timeout returns what is there so far and the program's name, and the agent can keep waiting or send `ctrl-c`.

**Reading.** Text comes from the service's local-only `capture` request ([protocol](../protocol/local-agent-v1.md)): tmux's own copy of the pane with wrapped lines joined and no escapes, at most 24 KiB per reply (the latest lines).

**Token use.** The first Codex run spent about 235,000 input tokens on 10 calls, mostly re-reading whole screens. Now:
- **What changed.** Each connection remembers what it last saw of each terminal, as the screen's lines and where the screen's top was in tmux's history. The next `read_terminal`, `wait_for_terminal` or `send_input` captures from that same line. It leaves out the lines that are the same as before ("[12 lines you've seen left out]") and says "No change since your last look." when nothing changed. A cleared screen or a different screen (a full-screen program) gets the whole screen.
- **Command output.** `run_command` captures from the line the cursor was on before typing, and counts as a look.
- **Long output.** Output over 160 lines keeps its first 30 and last 120 lines, and says how many were left out and how to read them.
- **Shorter replies.** The header is one line, and shows the cursor only when a program other than the shell has the terminal.
- **Fewer round trips.** Most of an agent's tokens are its own context, which it resends on every model turn, so the number of turns matters most. `create_terminal` returns the new shell's first screen. The instructions and `read_terminal`'s description say every tool already returns what changed.

| Same Codex task (2026-11-17) | Tool calls | Input tokens | Uncached |
|---|---:|---:|---:|
| First version | 10 | 235,301 | 16,933 |
| Reads return only changes | 10 | 274,529 | 34,657 |
| Plus fewer round trips | 6 | 156,598 | 7,990 |

The second row shows that smaller outputs alone didn't help: Codex still read the terminal after every action, and its turns differ from run to run. All tool output together was 1,000–3,000 characters per run either way.

## Rules

- **Same rules as any local writer.** Typing attaches as a short-lived writer at the terminal's current size, so the grid doesn't change. A paired device that doesn't allow typing alongside makes the terminal busy (the tool says so), and nothing takes control from it. Input waits for tmux's first redraw. Before that, tmux's client hasn't put the attachment's terminal in raw mode, and a Control-C would interrupt the client instead of reaching the shell.
- **Named, and waiting for people.** The attachment carries the agent's name (`agent` on `attach`), taken from the MCP client's own description: "Codex", "Claude Code", otherwise its title or name. Witerm shows "Codex is typing", and `witerm sessions` names it. While a person has typed in the same terminal within the last 2 seconds, the service refuses the agent's input (`session_busy`). The tool tells the agent to wait and read again. An agent never types into the middle of what a person is typing.
- **No new privilege.** The service socket is reachable only by this user, who can already do all of this with `witerm attach`. The MCP server adds nothing that the user's own processes couldn't do.
- **Ending terminals.** An agent can end only the terminals it created with `create_terminal`, and only on the same connection. The user's own terminals are never ended by an agent.
- **Where the text goes.** Terminal text that an agent reads goes to that agent and to whichever model service it uses, by the user's choice when they set it up. Witerm itself never logs it, and the relay and server never see it. Agents are told not to type passwords or other secrets (`instructions` in the `initialize` reply).
- **Local only.** `capture` and `witerm mcp` are never reachable through the relay. A paired phone can't read a terminal as text, or start an agent.

## Verified

- **Unit and integration tests.** `swift test --package-path apps/mac-agent --filter MCP` covers the handshake, tool lists, JSON-RPC errors, the read-only mode, and key names. It also runs the real `witerm mcp` binary against a private broker and tmux: create, run, a running-program refusal, Control-C, waiting, typing, reading history, unknown keys and terminals, and refusing to end a terminal the agent didn't create. `testCaptureReadsTheScreenAndHistoryAsText` covers the capture request itself.
- **Codex 0.167 (2026-11-17), against an isolated service** (its own state directory and tmux server, not the installed app's). The task was: create a terminal in `/private/tmp`, find the five largest files in `/usr/bin`, total them in an interactive `python3` REPL, exit, and close the terminal. Codex used `create_terminal`, `run_command`, `read_terminal`, `send_input` (the REPL) and `close_terminal`, and reported the right answer. With Codex's default approval mode, `codex exec` refused `run_command` and `close_terminal` ("requires approval, but approval policy is never") because they're marked destructive. The read-only tools and `create_terminal` ran without asking.
- **Cost.** Three runs of that task are in the table under "Token use". The latest took 6 tool calls and 156,598 input tokens.
