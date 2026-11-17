# Orbit

Orbit is Witerm's assistant. It understands and summarizes terminal output, operates terminals when asked in plain language, and carries out delegated tasks on its own. It works in two ways:

- **In Witerm, with the user's OpenAI API key.** That mode is described here.
- **Through an outside agent** (Codex, Claude Code) using `witerm mcp`. See [agents.md](agents.md).

The wire format is in [protocol/orbit-v1.md](../protocol/orbit-v1.md).

## Decisions

These were made with the owner on 2026-11-17.

| Question | Decision |
|---|---|
| Where the conversation runs | In a helper process on the Mac, `witerm orbit serve`, started from the app's existing signed `witerm` helper. It is not part of the app window or of `witerm-agent`. Delegated tasks keep running when the window closes, and the terminal service stays small. Reading a terminal is local-only, so Orbit must run on the Mac. |
| What a conversation is | A thread. A chat answers and stops. A task plans (`update_plan`), works until it calls `finish_task`, and otherwise ends `waiting` for the user. A thread started from a terminal names it, and "this terminal" means that one; Orbit can still use every terminal. |
| Which terminals | All of them. Orbit runs commands and types in any terminal on this Mac. It can end only the terminals it created for that thread, so the user's own terminals are never ended by Orbit. Confirmed by the owner on 2026-11-18: every terminal stays open to agents, with no per-terminal switch to keep them out. |
| When Orbit runs | Since 2026-11-18. With a key in the Keychain, Witerm starts Orbit when it launches. `witerm mcp` starts Orbit when an agent needs it and it isn't running. While Witerm has a key, it watches Orbit's folder (a file-system event, not polling) and gives the key and model to any Orbit that starts. Orbit still exits after 15 idle minutes. So a Codex handoff works right after an install, without opening Orbit first. |
| Who types when | Orbit types as a short-lived writer named "Orbit". The service refuses its input while a person typed in the same terminal within 2 seconds, and the tool tells the model to wait and read again. The sidebar shows "Orbit is typing". |
| Storage | On this Mac only, in Orbit's private folder. Threads are removed after 30 days without use, and Settings ▸ Orbit can delete them all. Nothing goes to Witerm's server. |
| The API key | Stored in the data protection Keychain (this device only, readable while unlocked) only when the user leaves "Keep in Keychain on This Mac" on. Otherwise it stays in memory until Witerm quits. The app hands it to Orbit over the private socket, and Orbit keeps it in memory only. An Orbit started by `witerm mcp` gets none of the agent's environment but `HOME`, `PATH`, `WITERM_ORBIT_DIRECTORY` and `WITERM_AGENT_SOCKET`. In particular it gets no `WITERM_ORBIT_OPENAI_URL`, so an agent can't point the Orbit that Witerm will key at another endpoint. |
| Provider | The OpenAI Responses API only. The default model is `gpt-6.1-sol`, changeable in Settings. |
| Handoff | `witerm mcp` adds `list_orbit_tasks`, `read_orbit_task`, `guide_orbit_task`, `take_over_orbit_task` and `finish_orbit_task`. A take-over stops Orbit's run, so only one agent drives a task. Guidance from that agent, or a message from the user, hands it back to Orbit. |
| iPhone and iPad | In progress (Round 32): chat clients through the end-to-end encrypted relay, for devices allowed to type in every terminal. The protocol and the Mac side are done; the iOS views are next. See [design/orbit-ios.md](design/orbit-ios.md) and [relay-v1](../protocol/relay-v1.md#orbit). |

## Context management

The whole record stays in the thread's file. Each request (`store: false`) is built fresh from it:

1. Instructions and tools come first and never change within a thread, so the API caches that prefix (`prompt_cache_key` is the thread's ID).
2. Orbit's memory (its own summary of older turns), when there is one.
3. The turns since then, verbatim, with three exceptions:
   - **Old tool output.** Output from before the current run is cut to its first line plus a note to read the terminal again.
   - **Current run.** Only the latest 8 outputs of the current run are sent whole.
   - **Reasoning.** It is sent back (encrypted, `include: ["reasoning.encrypted_content"]`) only within the run that produced it.
4. A call cut off by Stop gets a "Stopped before this finished" answer, so the history stays valid.

**Summarizing.** When the input passes about 120,000 characters, everything before the current run is summarized by the model into its memory (at most 300 words, no secrets), and the thread notes it.

**Reading less.** Terminal reads already send less (see [agents.md](agents.md)): a second look at a terminal returns only what changed, and long output keeps its first 30 and last 120 lines.

**Limits.** A run stops after 50 model requests and waits for the user. Usage is summed per thread and shown in the API reply.

## In the app

- **Sidebar ▸ Orbit.** Threads on the left. The chosen thread on the right shows its plan, messages, and each action ("Ran `swift build` in api"), with its output a click away and a Show link to the terminal.
- **Composer.** For a new thread you choose Ask or Delegate a Task, and which terminal it's about. While Orbit works, messages guide it, and Stop ends the run.
- **Ask Orbit About This Terminal.** In a terminal's context menu and in Open Quickly.
- **Settings ▸ Orbit.** The API key (Keychain or this session), the model, and Delete All Conversations.
- **Privacy note.** The composer says that Orbit can read and type in every terminal, and that what it reads goes to OpenAI.

## Verified (2026-11-17)

**Without an API key.** No key was available during development, so the loop is checked against a scripted fake of the Responses API:

- **Unit tests** (`swift test --package-path apps/mac-agent --filter Orbit`) cover:
  - a chat answering, and a task planning and finishing, including the order of reasoning, calls and outputs in the request;
  - a missing key, and API errors (401, 429, 500);
  - Stop, then a new run;
  - another agent taking over, guiding and finishing, and other agents being refused;
  - what the input keeps and cuts, and summarizing into memory;
  - storage, retention and clearing;
  - the real daemon process: its socket and folder modes, its lock, and the client round trip.
- **By hand.** A mock server and the real daemon, against an isolated terminal service, ran a scripted task:
  - plan, create a terminal, run `echo orbit-$((6*7))`, and finish;
  - the requests had `store: false`, encrypted reasoning only within the run, and a stable cache key;
  - `witerm mcp` listed the task, read it, took it over and finished it.

**With the owner's key (2026-11-18).** This was the installed app, with `gpt-6.1-sol`. The task: create "Orbit check" in `/private/tmp`, report the macOS version and the number of entries there, then end the terminal.
- **Result.** Orbit set a two-step plan, created the terminal, and ran `sw_vers -productVersion; /bin/ls -A1 /private/tmp | /usr/bin/wc -l` once. It reported 27.2.1 and 21 entries, ended its terminal, and finished the task `done`.
- **Cost.** 34 s, 4 requests, 11,018 input and 362 output tokens.
- **No caching, then fixed.** That run had 0 cached tokens. Swift dictionaries have no stable key order, so the tools were serialized differently on each request, including the order of their parameters, and the prompt prefix never matched. Requests now encode with sorted keys, and a test checks that the tools are the same bytes on every request. - **Cached after the fix (installed 2026-11-18 00:11).** A longer task created a terminal and ran `sw_vers`, `uptime` and `df -h /` one per step. It then typed `2**64` into an interactive `python3`, exited it, reported, and ended its terminal. That was 8 tool calls in 46 s, `done`, with 23,037 of 25,700 input tokens cached (90%) and 705 output tokens.
