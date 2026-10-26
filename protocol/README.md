# Server HTTP Contract v1

The server provides diagnostics, device identity and pairing ([pairing-v1](pairing-v1.md)), and an opaque encrypted relay ([relay-v1](relay-v1.md)). It has no account login and never handles terminal plaintext. The local Mac service protocol is [local-agent-v1](local-agent-v1.md).

| Method | Path | Response |
|---|---|---|
| GET | `/healthz` | 200 while the process runs; doesn't check the database |
| GET | `/readyz` | 200 if the database answers within 2 seconds, otherwise 503 |
| GET | `/v1/info` | Service name, protocol version, and capabilities |

`/v1/info` advertises `device_identity_v1`, `device_pairing_v1`, and `encrypted_relay_v1`. These cover paired access to existing Witerm sessions only, not direct SSH or remote session creation. Never advertise a capability that isn't implemented.

**Clients.**
- A client treats a server as usable only if `service == "witerm"`, `protocol_version == 1`, and `/readyz` succeeds.
- Diagnostics read at most 16 KiB from `/v1/info` and 4 KiB from `/readyz`, and give each response 15 seconds.
- Base addresses carry no user info, query, or path.

JSON fields are snake_case. Go and Swift tests share the examples in `fixtures/`.
