# Citadel provenance

Upstream: https://github.com/orlandos-nl/Citadel
Version: 0.12.1
Commit: ae8562f895de06ccb86fdb1cbb65fd99c8976e12
License: MIT, preserved in LICENSE.

Witerm maintains the following narrow compatibility changes here. No algorithm
downgrade is enabled. The SSH client is isolated from WitermCore and the Mac helper.

1. `Client.swift`: add public `createSessionChannel(initialize:)`. It creates a
   session child on the owning NIO event loop with a 10-second creation deadline.
   Witerm installs its own bounded PTY handler, rather than consuming upstream's
   unbounded `withPTY` stream or raising the macOS deployment target to 15.
2. `ClientSession.swift`: close the established transport if initial key
   verification/authentication fails. Preserve the original failure if closing
   an already-closed transport also fails.
3. `Client.swift`: close a jump's nested transport if its key verification or
   authentication fails. Previously authenticated jump transports are owned and
   closed in reverse order by Witerm.

No private engine state is accessed through reflection. The upstream
`connect(on:)` API is not used by Witerm, because this release performs pipeline
`syncOperations` from the async entry point. All normal initial connections and
jumps use upstream's event-loop channel initializer paths.

Witerm does not enable `SSHAlgorithms.all` or the upstream custom RSA/SHA1
authentication path. Supported private-key authentication is OpenSSH Ed25519
(plain or supported bcrypt/AES encrypted keys). Unsupported keys fail explicitly.

Verification is recorded in the project's SSH acceptance document and logs.

4. `SFTP/Client/SFTPClient.swift`: validate success status for mkdir, remove,
   rmdir and rename, including wrong response kinds and unexpected EOF. The
   upstream inbound handler already rejects ordinary failure statuses. Directory listing
   resolves once, caps entries while consuming replies (10,000 by default),
   validates EOF/error status and closes its handle on success and failure.
   The default SFTP logger is replaced with a per-subsystem no-op handler;
   request descriptions, paths and file bytes cannot reach a process-global
   logging backend. The subsystem's file/inbound handlers inherit that logger.
5. `DirectTCPIP/Client/DirectTCPIP+Client.swift`: bound channel creation to ten
   seconds and close the authenticated transport on timeout/cancellation, so
   pending child creation cannot hang indefinitely. A late-created channel is
   closed. Invalid channel data raises an error and closes rather than trapping.

6. `SFTP/SFTPMessageParser.swift`: reject advertised packet lengths outside
   1...1,048,576 before waiting for a payload. Zero length can no longer form a
   negative slice; an oversized advertised message cannot grow the decoder's
   cumulation without a bound. Fragmented valid frames remain supported.

7. `SFTP/Client/SFTPClient.swift`: apply a 30-second deadline per individual
   request, failing the pending response and closing only that SFTP subsystem.
   Streamed transfers have no cumulative 30-second limit. Cancellation also
   closes the subsystem, resolving stalled request futures without replay.

8. `SFTP/Client/SFTPClient.swift`: closing immediately fails pending request
   promises and initiates SSH child close, but waits at most two seconds for a
   remote CLOSE acknowledgement. Completion is resolved once on the owning
   event loop. A permanently unresponsive child can remain in the SSH
   multiplexer until its parent transport disconnects; unrelated healthy PTY
   channels are retained. Calls on a logically closed SFTP subsystem fail fast.

9. Directory replies additionally share a 16MiB cumulative estimated-metadata
   budget (UTF-8 filename, longname, extended fields, 128 bytes per entry and
   64 bytes per extended tuple). This is checked before retaining each reply;
   many valid 1MiB packets cannot bypass the aggregate bound.
