# Direct SSH

The apps connect straight to SSH servers. Witerm Server, pairing, and Allow Remote Access play no part.

## Hosts

Saved hosts are under **SSH Hosts** in the Mac sidebar and in the iOS **SSH** tab. Search matches names and addresses; favorites come first, then recently connected hosts. On a regular-width iPad, the host list stays beside the terminal.

**Adding a host.** File → New SSH Connection (⇧⌘N) on the Mac, or the add button on iOS. Type the address the way you would in a shell: `user@host`, `user@host:port`, `user@[fe80::1]:2222`, or an `ssh://` URL. The form shows what it understood (user, host, port) under the field. Then pick **Password** or an **OpenSSH Ed25519 key** (plain or passphrase-protected).

- **Connect** saves the host and connects; **Save for Later** stores it without connecting. Both sit at the bottom of the form.
- Editing a host uses **Save** and never connects.
- **More Options** holds the name (optional; defaults to the address) and jump hosts. It opens on its own when either is already set or has an error.
- **Generate New Key** makes an Ed25519 key in the form and shows its public key to copy or share into the host's `~/.ssh/authorized_keys`. The private key stays on the device: in memory, or in the Keychain if **Save Credentials on This Device** is on (the form warns when it's off).
- An RSA key is flagged at its field before connecting, with a pointer to generating an Ed25519 key.

**Importing hosts.** File → Import SSH Hosts… on the Mac, or **Import from SSH Config…** in an empty host list. On the Mac, **Read ~/.ssh/config** reads that file when you choose it; anywhere, **Choose File…** opens a file you pick. You review the hosts and choose which to save.

- Imported: `Host` aliases (not patterns), `HostName`, `Port`, `User`, and `ProxyJump`, using OpenSSH's first-value-wins order. Global options before the first `Host` and `Host *` blocks apply.
- Ignored: `Match`, `Include`, `IdentityFile`, agents, and every other option. No credential comes across; you enter it on first connect, and each host key is verified then.
- Hosts already saved with the same endpoints are skipped. Entries without a user (iOS has no default user) or with an unusable jump chain are listed with the reason.

**Deleting a host** is immediate and can be undone for 10 seconds. The undo snapshot, including saved credentials, is held in memory only for that time.

**Not supported:** RSA keys (the engine would sign with SHA-1), hardware keys, agent forwarding, certificates, and keyboard-interactive or MFA logins.

## Sessions

- Up to 8 hosts stay connected at once. Switching hosts doesn't disconnect; Disconnect is always explicit.
- Closing the Mac window disconnects everything. So does sending the iOS app to the background.
- After a disconnect, iOS keeps the host on screen with the reason and a **Reconnect** button. Reconnecting opens a new shell and never replays earlier input.
- When the device has no network, SSH views say so before a connection times out. A returning network doesn't reconnect on its own.

**Connection errors** name the cause and a next step:

| Cause | Next step |
|---|---|
| Host not found (DNS) | **Check Connection…** |
| Connection refused | **Check Connection…** |
| Jump host couldn't reach the target | **Check Connection…** |
| Username, password, or key rejected | **Check Connection…** (opens the form instead of retrying saved credentials) |
| Sign-in method not accepted by the host | **Check Connection…** |
| Timed out, or network unreachable | **Try Again** |
| No secure algorithm in common | Ask the host's administrator; Witerm never downgrades |
- SSH sessions don't get the Mac service's persistence. Run tmux on the server for work that must survive a disconnect.

## Credentials

- By default, credentials live in memory for one connection only.
- **Save Credentials on This Device** opts into the local Keychain: not synced, readable only while unlocked. Saving the host alone doesn't opt in.
- Host profiles never contain passwords, keys, or passphrases.
- Changing a host's address, port, or username clears its saved credentials.

## Mobile keyboard row

- Esc, Ctrl, Tab, Ctrl+C, Paste, Snippets, arrows, `|` `~` `/` `-`, Home, End, Page Up, and Page Down, in a row that scrolls sideways and follows Dynamic Type. Home and End follow the terminal's cursor-key mode like the arrows.
- **Settings → Keyboard Row** chooses which keys appear and their order; at least one key stays. Changes apply to open terminals. The same row serves SSH and paired Mac sessions.
- Ctrl applies to the next key only, and VoiceOver announces whether it's on.
- A multiline paste first shows the full text and where it will go. **Send Text** keeps bracketed paste when the shell supports it and adds no Return. Disconnecting or cancelling discards it.
- None of these send anything in a view-only session.

## Host keys

**First connection.** The app shows the address, key type, and SHA256 fingerprint. Compare the fingerprint through a channel you trust, then approve. Approval starts a fresh handshake, so taking your time doesn't hit the login timeout.

**Changed keys** block the connection, with no "connect anyway". After confirming a legitimate key rotation, remove the old key under **Host Keys** and verify the new one.

Trust is stored per address and port. Every jump host and the final target are verified separately. Deleting a host keeps its trusted key.

## Jump hosts

- Up to 4, each with its own credentials.
- The final session runs end to end through the jumps, so jump hosts never see the target's credentials.
- The chain closes in reverse order.

## SFTP

- **Actions.** Browse, create folders, upload, download, and delete files or empty folders (with confirmation).
- **No overwrites.** Uploads never replace a remote file; downloads never replace a local file or symlink.
- **Transfers.** 64 KiB chunks with progress and cancel, up to 1 TiB per file. A cancelled upload removes only the partial file it created; a disconnect can still leave one behind.
- **Limits.** 30 seconds per request (transfers can run longer), 10,000 entries or 16 MiB of metadata per listing, 1 MiB per packet. Remote file names can't change where downloads are saved.

## Port forwarding

- Local (L) and remote (R) TCP forwarding: up to 8 rules per connection, 32 channels per rule.
- Listeners are always on `127.0.0.1`: no all-interface listeners, no SOCKS. Port 0 picks a free port, and the app shows the one used.
- Local-forward targets are reached from the SSH server, remote-forward targets from the device. Server policy such as `AllowTcpForwarding` still applies.
- Disconnecting stops every listener and channel.

## Engine and tests

`packages/WitermSSH` uses pinned Citadel 0.12.1 source on SwiftNIO SSH. Witerm's patches add bounded PTYs, cleanup after failed handshakes, strict SFTP parsing, and channel deadlines; they're listed in [`vendor/Citadel/WITERM-PATCHES.md`](../vendor/Citadel/WITERM-PATCHES.md).

```sh
swift test --package-path packages/WitermSSH -j 4
python3 tools/ssh-fixture/run.py   # Real OpenSSH
```

`run.py` generates throwaway keys, starts two OpenSSH containers on random localhost ports, and cleans everything up afterwards. It covers both key types, passwords, a rejected password, a jump target that refuses, PTY sizing, SFTP through a jump host, permission errors, about 2 MiB each way through L and R forwards, and rejection of unknown or changed host keys.

Unit tests also check that `ssh-keygen` reads generated keys and that RSA keys are recognized, using throwaway files in a temporary folder. The tests never read your `~/.ssh`, keys, or known hosts, enable Remote Login, or listen on your network. Without the fixture, the live tests skip rather than pretend to pass.
