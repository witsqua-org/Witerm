# Witerm Server

A Go server that provides device identity, pairing, and the encrypted relay. It stores identities and grants in PostgreSQL and keeps online connections in memory. It never decrypts, stores, or logs terminal traffic, tokens, or routing details.

Contracts: [HTTP](../protocol/README.md), [pairing](../protocol/pairing-v1.md), [relay](../protocol/relay-v1.md).

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `DATABASE_URL` | required | PostgreSQL connection string |
| `HTTP_ADDR` | `127.0.0.1:37429` | Listen address |
| `MIGRATE_ON_START` | `false` | Apply migrations at startup (Compose turns this on) |
| `TLS_CERT_FILE`, `TLS_KEY_FILE` | unset | Serve HTTPS/WSS (TLS 1.2+); set both or neither |
| `RELAY_ALLOW_LOOPBACK_DEVELOPMENT` | `false` | Allow plain HTTP/WS for exact loopback hosts |

**Running.** `go run ./cmd/server -migrate-only` applies migrations and exits. Migrations are numbered SQL files in `internal/store/migrations`. Never edit one that has been applied.

**Plaintext.** Without TLS, the relay refuses plaintext unless `RELAY_ALLOW_LOOPBACK_DEVELOPMENT=true`. That setting allows HTTP/WS only when the `Host` is exactly `localhost`, `127.0.0.1`, or `::1`.

- Compose enables it and publishes only on `127.0.0.1`.
- Never enable it on a public listener or behind a proxy: a `Host` header doesn't prove where a connection came from.

**Headers.** Forwarded headers are never trusted. WebSocket requests with an `Origin` header are rejected, and authentication is Bearer only.

**Docker healthcheck.** It verifies the configured certificate chain when TLS is on. Mount certificates read-only.

## Relay limits

| Resource | Limit |
|---|---|
| Host connections | 256 |
| Tunnels | 256 total, 4 per device |
| Admitted sockets | 768, including upgrades |
| Pending offers | 16 per host |
| Queued bytes | 256 KiB per leg |
| Unused tunnels | expire after 30 seconds |

**Revocation.**
- Revoking through the API closes routes immediately.
- A once-per-second check, with a 750 ms database deadline, closes sockets whose grant or device is gone, or when the database errors.
- Token expiry closes every socket on its own.

## Testing

```sh
go test -race ./...
go vet ./...
test -z "$(gofmt -l .)"
make -C .. test-integration   # Real PostgreSQL, isolated schema
```
