# Device Identity and Pairing v1

Pairing creates a signed, revocable grant between a Mac (host) and an iOS device (client). A grant is an identity record, not terminal access. The Mac still enforces its own trust before any session ([relay-v1](relay-v1.md)).

## Encoding

- **Keys.** Ed25519, with 32-byte public keys. Keys and signatures use padded Base64. Nonces, secrets, and tokens are 32 random bytes in unpadded Base64URL. IDs are lowercase UUIDs.
- **Dates.** RFC 3339 UTC, whole seconds. Expiry is exclusive: something is expired when `now >= expires_at`.
- **Device.** `{id, name, platform, public_key}`.
  - `platform` is `macos` or `ios` and can't change for a key.
  - `name` is trimmed, 1–64 Unicode scalars, with no control characters.
- **Key storage.** Private keys stay in the device-only Keychain. After an unexpected Keychain error, never create a replacement key.
- **One key per server.** Each normalized server address has its own key, so a malicious server can't relay another server's challenge.
- **Transport.** Identity and pairing calls require HTTPS. Plain HTTP is allowed only for loopback development.

## Identity

### Get a challenge

`POST /v1/auth/challenges` with `{public_key}` returns 201 `{challenge_id, nonce, expires_at}`.

The challenge is bound to that key, lasts 60 seconds, and is consumed after one attempt, even a failed one.

### Register

`POST /v1/devices` with `{challenge_id, name, platform, signature}` returns 200 `{device, access_token, expires_at}`. The signature covers these UTF-8 bytes, with no trailing newline:

```text
witerm-device-v1\n{challenge_id}\n{nonce}\n{name}\n{platform}
```

- Registration is idempotent per key and returns a 1-hour token. Register again to refresh it.
- A revoked device can't be brought back by registering again.
- There are no accounts. `users` rows only record ownership.

### Authenticated requests

Send `Authorization: Bearer <access_token>`.

- **Server side.** The server stores only the token's SHA-256 and checks expiry and device revocation on each call.
- **Client side.** On a 401, the client renews once and retries, never in a loop. A server restart invalidates tokens, and the device key can always re-register.

## Pairing

| Request | Who | Result |
|---|---|---|
| `POST /v1/pairings` `{}` | Mac | 201 `{pairing, secret}`. Lasts 5 minutes; the secret is returned once and stored only as a hash. Cancels the host's earlier open invitations. |
| `POST /v1/pairings/{id}/join` `{secret}` | iOS | 200 `Pairing`, now pending. Binds exactly one client; repeating it while pending is idempotent. A bad, expired, or used invitation always returns the same 404. |
| `GET /v1/pairings/{id}` | Host or bound client | 200 `Pairing`, with expiry computed. |
| `POST /v1/pairings/{id}/approve` `{permission, approval_signature}` | Mac | 200 `Pairing` with a grant. Never automatic. |
| `POST /v1/pairings/{id}/reject` `{}` | Host, or bound client while pending | 200 `Pairing`. An approved pairing is revoked through its grant instead. |
| `GET /v1/grants` | Either | 200 `{grants}`: only the caller's active grants. |
| `DELETE /v1/grants/{id}` | Either participant | 204, idempotent. Anyone else gets 404. |

**Approval.** `permission` is `view` or `control`. The approval signature covers these bytes, with no trailing newline:

```text
witerm-pair-v1\n{pairing_id}\n{host_public_key}\n{client_public_key}\n{permission}
```

The server verifies the signature against the bound identities, then consumes the pairing and creates the grant in one transaction. Repeating an approval with the same permission returns the original result. A different permission is a conflict.

**Objects.**
- `Pairing` is `{id, status, expires_at, host, client|null, grant|null}`. `status` is one of `waiting`, `pending`, `approved`, `rejected`, or `expired`.
- `Grant` is `{id, pairing_id, host, client, permission, approval_signature, created_at}`.
- After revocation, a pairing reads as `approved` with `grant: null`.

## Invitation

The Mac shows a copyable invitation:

```text
witerm://pair?server=<URL-encoded base URL>&id=<UUID>&secret=<Base64URL>&host_key=<URL-encoded Base64 key>
```

**iOS validation.** iOS validates every field.

- `server` must match the configured server, ignoring only trailing slash, letter case, and default port. iOS never switches servers because an invitation says so.
- iOS pins `host_key` and rejects any response that carries a different host key.

**Session invitation.** A Mac sharing one session without pairing shows instead:

```text
witerm://share?server=<URL-encoded base URL>&id=<UUID>&secret=<Base64URL>&host_key=<URL-encoded Base64 key>&access=view|control&until=<Unix seconds>&key=<Base64URL, 32 bytes>
```

The first four fields are a pairing invitation and are used exactly as above. `access` must match the permission the Mac signs, `until` is at most 24 hours ahead, and `key` never leaves the two devices (see [relay-v1](relay-v1.md)). Because the server isn't checked against saved ones, iOS asks before adding the server a link names.

**Fingerprints** are the first 16 uppercase hex digits of SHA-256(public key), in groups of 4.

**After approval.**
- The client checks the approval signature against the pinned host key and its own key. The host checks the grant matches what it signed.
- Both store the verified grant in the Keychain, scoped to the server.

**Revocation.**
- Revoking first records a local denial, which no later server response can undo, and drops that pairing's pinned key.
- A revoked pairing can still be read, but only without a grant. A revoked pairing that comes back with a grant is rejected as invalid.

## Errors and limits

Errors use `{"error": {"code", "message"}}`. The message is a generic English diagnostic; apps show localized text based on the code.

| Code | HTTP |
|---|---|
| `invalid_request` | 400 |
| `unauthorized` | 401 |
| `forbidden` | 403 |
| `pairing_unavailable`, `not_found` | 404 |
| `conflict` | 409 |
| `rate_limited` | 429 |
| `unavailable` | 503 |

- **Requests.** Bodies are at most 16 KiB; unknown fields and trailing JSON are rejected. Database calls time out after 5 seconds.
- **Rate limits.** 30 challenges per minute per remote IP; `X-Forwarded-For` is not trusted. 30 pairing changes per minute per device.
- **Secrets.** Secrets and tokens never appear in logs or errors.

The Swift API is `PairingClient` in `packages/WitermCore`. Apps poll an open invitation about every 2 seconds, only while in the foreground, and offer explicit refresh and cancel.
