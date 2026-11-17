# Orbit on iPhone and iPad (Round 32, design)

Orbit runs on the Mac. iPhone and iPad become chat clients for it: they list Orbit's conversations and tasks, read one, start one, reply, and stop a run. Orbit keeps doing the work on the Mac, in the Mac's terminals, with the Mac's OpenAI key. The phone never holds the key and never talks to OpenAI.

## Who can use it

Only a paired device that can **watch and type in all terminals** (a control grant, with the Mac's access for that device set to All terminals). Orbit can read and type in every terminal on the Mac, so a device limited to some terminals, or to watching, would gain through Orbit what its pairing withholds. Invitations (Shared with You) never reach Orbit. The Mac checks this on every request, from its own records; the phone's view of it only decides whether to show Orbit.

## Wire

One new remote operation in the encrypted relay ([relay-v1](../../protocol/relay-v1.md)), carried like `list`: one request and one reply per tunnel, with a fresh handshake and grant check each time.

- **Request:** `{"version":1,"id","operation":"orbit","orbit":<request>}`, where `<request>` is an [Orbit v1](../../protocol/orbit-v1.md) request limited to `status`, `threads`, `thread`, `start`, `send` and `stop`, with only the fields those take. It never carries `api_key`, `model`, `agent` or `success`, and never `configure`, `take_over`, `finish`, `delete` or `clear`.
- **Reply:** `{"version":1,"id","ok","orbit":<reply>}`, Orbit's own reply. `status` includes the model's name, which isn't secret.
- **Refusals:** `read_only` for a device that may not use Orbit. Orbit's own errors, `unavailable` when it can't be started included, pass through inside `orbit`.
- **Size.** A thread reply is cut to fit the 49,152-byte record: the latest entries first, with `earlier_entries` counting the rest, and each action's excerpt shortened before an entry is dropped.

The server is unchanged and learns nothing new: it still forwards opaque records. No capability is added to `/v1/info`.

## Mac side

The relay bridge in `witerm-agent` accepts `orbit` only after `RelayTerminalPolicy` admits it and the device's access (all terminals, typing, not an invitation) checks out, and forwards it to `orbit.sock` in the app group (`OrbitGateway`), as the app does. A message started or sent from a device is the user's own, like one typed on the Mac.

If Orbit isn't running, the service starts it from the app's own `Contents/Helpers/witerm`, as `witerm mcp` does. If Orbit has no key, the service gives it the Keychain key (below).

## iPhone and iPad

- **Where:** in Terminals, each Mac's section gains an **Orbit** row when that Mac allows this device every terminal. It opens the conversation list for that Mac; a conversation opens full screen on iPhone and beside the list on iPad.
- **Conversation:** Orbit's plan, messages and actions, as on the Mac (the actions name the terminal, and Show opens it here when this device can reach it), with a composer: Ask or Delegate a Task for a new one, then Reply, and Stop while Orbit works.
- **Updates:** no stream. While a conversation that is running is on screen, the phone asks for it every 5 seconds; otherwise the list every 15 seconds while shown, and nothing in the background. That is at most 12 tunnel opens a minute against the device's 30, beside the terminal list's 6, and it uses a single tunnel at a time, so the 3 kept terminals still leave one free.
- **Words:** the phone shows "Orbit on *Mac name*", and that what Orbit reads goes to OpenAI from the Mac.

## Decided: the background service gives Orbit the key (2026-11-18)

Orbit gets its key from the Witerm app (at launch, and whenever Orbit starts while the app is open), but a phone usually reaches a Mac whose window is closed. The owner chose that `witerm-agent`, which already reads the Mac's identity through the app's Keychain group (`com.witerm.mac`), reads Orbit's key from the same group only when a device's request finds Orbit without one, gives it over Orbit's private socket, and never keeps, logs or sends it. The alternative, Orbit from a phone only while Witerm is open, was declined. A key kept for This Session Only isn't in the Keychain, so then Orbit answers that it needs one.

## Order of work

Done on 2026-11-18: steps 1 and 2, tested (`OrbitRelayTests`; `RelayOrbitTests` end to end through a modeled relay, the real bridge, an isolated service and the real `witerm orbit serve`; the Go fixture contract). Next: step 3.

1. Protocol: `orbit` in relay-v1 and local-agent-v1, fixtures, Swift models in WitermCore (Go is untouched: the server never sees it).
2. Mac: the relay policy and forwarding, the size cut, starting Orbit; unit tests against a fake Orbit and the real daemon.
3. iOS: the client in WitermCore's relay client, then the views; UI tests on the iPhone 18 Pro simulator with a fixture Mac.
4. Joint run through the real relay with the owner's go-ahead (it spends the OpenAI key).
