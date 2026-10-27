# Direct SSH

The apps connect straight to SSH servers. Witerm Server, pairing, and Allow Remote Access play no part.

## Hosts

Saved hosts are under **SSH Hosts** in the Mac sidebar and in the iOS **SSH** tab. Search matches names and addresses; favorites come first, then recently connected hosts. On a regular-width iPad, the host list stays beside the terminal.

**Adding a host.** File → New SSH Connection (⇧⌘N) on the Mac, or the add button on iOS. Enter the address, port, and username, then pick **Password** or an **OpenSSH Ed25519 key** (plain or passphrase-protected).

- **Save and Connect** connects at once; **Save Without Connecting** stores the host without credentials.
- Editing a host uses **Save** and never connects.
- The name is optional and defaults to the address. Port and jump hosts are under the advanced sections.

**Not supported:** RSA keys (the engine would sign with SHA-1), hardware keys, agent forwarding, certificates, and keyboard-interactive or MFA logins.

## Sessions

- Up to 8 hosts stay connected at once. Switching hosts doesn't disconnect; Disconnect is always explicit.
- Closing the Mac window disconnects everything. So does sending the iOS app to the background.
- After a disconnect, iOS keeps the host on screen with the reason and a **Reconnect** button. Reconnecting opens a new shell and never replays earlier input.
- SSH sessions don't get the Mac service's persistence. Run tmux on the server for work that must survive a disconnect.

## Credentials

- By default, credentials live in memory for one connection only.
- **Save Credentials on This Device** opts into the local Keychain: not synced, readable only while unlocked. Saving the host alone doesn't opt in.
- Host profiles never contain passwords, keys, or passphrases.
- Changing a host's address, port, or username clears its saved credentials.

## Mobile keyboard row

- Esc, Ctrl, Tab, Ctrl+C, Paste, and arrow keys, in a row that scrolls sideways and follows Dynamic Type.
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

`run.py` generates throwaway keys, starts two OpenSSH containers on random localhost ports, and cleans everything up afterwards. It covers both key types, passwords, PTY sizing, SFTP through a jump host, permission errors, about 2 MiB each way through L and R forwards, and rejection of unknown or changed host keys.

The tests never read your `~/.ssh`, keys, or known hosts, enable Remote Login, or listen on your network. Without the fixture, the live tests skip rather than pretend to pass.
