# Witerm Mac Agent

The background service behind the Mac's local terminals, and the `witerm` command. The service hosts shells in a private tmux server, serves them over a Unix socket, and runs the Mac end of the [encrypted relay](../../docs/relay.md). `witerm` ([guide](../../docs/cli.md)) is another client of the same socket. The wire protocol is [local-agent-v1](../../protocol/local-agent-v1.md).

## Build and run

Requires macOS 14+, Swift 6, and tmux.

```sh
swift build --package-path apps/mac-agent
swift test --package-path apps/mac-agent

state="$(mktemp -d /private/tmp/witerm-dev.XXXXXX)"
swift run --package-path apps/mac-agent witerm-agent --state-directory "$state" --shell-path /bin/sh
```

`--state-directory` needs an absolute path that you own, with mode 0700, that isn't a symlink. Point the command at it with `WITERM_AGENT_SOCKET="$state/agent.sock" swift run --package-path apps/mac-agent witerm sessions`. The installed app starts the agent through SMAppService with `--app-group <group>` instead. RPC can't change the tmux path or shell.

## Safety

- **Socket.** `agent.sock` is 0600, and both sides check the peer's user ID. An `agent.lock` file stops a second agent from starting. A stale socket is removed only after taking the lock and confirming nothing is listening.
- **Process spawning.** Processes start with `posix_spawn` from argument arrays. PTYs come from `openpty`. Descriptors are close-on-exec by default.
- **tmux.** Witerm's tmux server is private and has no status bar. Viewers attach `read-only,ignore-size`, so they can't resize the controller's shell.
- **Lifetime.** Closing a client or stopping the agent detaches without killing shells. Only `close` ends a session, and only one this agent created.
- **Slow viewers** get a `backpressure` close and must reattach to get a redraw. Bytes are never dropped silently.
- **Logging.** Nothing that passes through a terminal is logged.

## Testing

The package tests cover:

- file and socket permissions, locking, and peer checks
- malformed frames and limits
- real tmux input, `stty size`, exclusive control, and view-only rejection
- reconnect redraw, resize confirmation, and literal start folders
- sharing and paired-device visibility
- the real `witerm` binary on pseudo-terminals (`WitermCLITests`, see [Command line](../../docs/cli.md#testing))

The black-box smoke tool also checks that the shell PID survives an agent restart:

```sh
make test-local
```

Tests use private temporary directories and `/bin/sh`, and clean up only their own tmux server.
