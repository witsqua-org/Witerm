# Direct SSH

The apps connect straight to SSH servers. Witerm Server, pairing, and Allow Remote Access play no part.

## Using it

**Where.** Saved hosts are under **SSH Hosts** in the Mac sidebar and in the iOS **SSH** tab.

**Adding a host.** Use File → New SSH Connection (⇧⌘N) on the Mac or the add button on iOS. Enter the address, port, and username, and choose:

- **Password**, or
- **OpenSSH Ed25519 key**, plain or passphrase-protected.

Use **Save and Connect** to connect immediately, or **Save Without Connecting** to keep the configuration without supplying credentials. Editing an existing host uses **Save** and never connects. A blank name defaults to the endpoint; port and jump-host settings are under the advanced disclosures. Search matches names and endpoints; favorites appear first, followed by recently connected hosts. On a regular-width iPad, the host list and terminal use separate columns.

**Not supported:** RSA keys (the engine would sign with SHA-1), hardware keys, agent forwarding, certificates, and keyboard-interactive or MFA logins.

**Sessions.**
- Up to 8 hosts can stay connected at once. Switching hosts doesn't disconnect them; Disconnect is always explicit.
- Closing the Mac window disconnects everything. So does sending the iOS app to the background.
- After a disconnect, the selected iOS host stays visible with its reason and an explicit Reconnect action. A reconnect opens a new shell; it does not recover the old SSH process.
- SSH sessions don't get the Mac service's persistence. Use tmux on the server for work that must survive a disconnect.
- Reconnecting never replays earlier input.

## Credentials

- By default, credentials are kept in memory for one connection only.
- **Save Credentials on This Device** explicitly opts into the local Keychain: not synced, and readable only while unlocked. Saving the configuration alone does not opt in.
- Host profiles never contain passwords, keys, or passphrases.
- Changing a host's address, port, or username clears its saved credentials.

## Mobile input

The keyboard accessory provides Esc, one-key Ctrl, Tab, Ctrl+C, Paste, and directional arrows. The row scrolls horizontally and follows Dynamic Type. Ctrl exposes its selected state and resets after use. Multiline paste opens a complete preview with the destination; Send Text preserves bracketed paste when the shell supports it and adds no extra Return. Cancellation or disconnection discards the pending paste. These actions cannot send input in view-only mode.

## Host keys

**First connection.** The app shows the address, key type, and SHA256 fingerprint. Compare the fingerprint through a channel you trust, then approve. Approval starts a fresh handshake, so taking your time doesn't hit the login timeout.

**Changed keys.** A changed key blocks the connection, and there is no "connect anyway". After confirming a legitimate key rotation, remove the old key under **Host Keys** and verify the new one.

Trust is stored per address and port. Every jump host and the final target are verified separately. Deleting a host keeps its trusted key.

## Jump hosts

- Up to 4 jump hosts, each with its own credentials.
- The final SSH session runs end to end through the jumps, so jump hosts never see the target's credentials.
- When the connection ends, the chain closes in reverse order.

## SFTP

**What you can do.** Browse, create folders, upload, download, and delete files or empty folders (with confirmation).

**Overwrites.** Upload never overwrites a remote file, and download never overwrites a local file or symlink.

**Transfers.**
- Data moves in 64 KiB chunks with progress and cancel, up to 1 TiB per file.
- A cancelled upload tries to remove only the partial file it created. A disconnect can still leave a partial file.

**Limits.**
- 30 seconds per request (transfers themselves can run longer).
- 10,000 entries or 16 MiB of metadata per listing, and 1 MiB per packet.
- Remote filenames can't change where downloads are saved.

## Port forwarding

- **Directions.** Local (L) and remote (R) TCP forwarding.
- **Capacity.** Up to 8 rules per connection, 32 channels per rule.
- **Listeners.** Always on `127.0.0.1`, with no all-interface listeners and no SOCKS. A local port of 0 picks a free port, and the app shows the port actually used.
- **Where targets are reached.** Local-forward targets are reached from the SSH server; remote-forward targets from the device. Server policy such as `AllowTcpForwarding` still applies.
- **Shutdown.** Disconnecting stops every listener and channel.

## Engine and tests

`packages/WitermSSH` uses pinned Citadel 0.12.1 source with SwiftNIO SSH. Witerm's patches add:

- bounded PTYs
- cleanup after failed handshakes
- strict SFTP parsing
- channel deadlines

They are listed in [`vendor/Citadel/WITERM-PATCHES.md`](../vendor/Citadel/WITERM-PATCHES.md).

```sh
swift test --package-path packages/WitermSSH -j 4
python3 tools/ssh-fixture/run.py   # Real OpenSSH tests
```

`run.py` generates throwaway keys and starts two OpenSSH containers on random localhost ports, then cleans everything up. It covers both key types, passwords, PTY sizing, SFTP through a jump host, permission errors, about 2 MiB each way through L and R forwards, and rejection of unknown or changed host keys.

The tests never read your `~/.ssh`, keys, or known hosts, enable Remote Login, or listen on your LAN. Without the fixture, the live tests skip instead of pretending to pass.
