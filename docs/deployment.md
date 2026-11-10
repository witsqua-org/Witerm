# Docker deployment

The local development service uses `http://localhost:37429`. A public deployment uses trusted HTTPS on TCP port **37429**, including WebSocket relay connections. The container's internal port is 8443; PostgreSQL port 5432 is never published.

## Public server

Copy `server/`, `.dockerignore`, and `compose.public.yaml` to a dedicated directory. Create a private `.env` file there:

```dotenv
POSTGRES_USER=witerm
POSTGRES_PASSWORD=REPLACE_WITH_A_RANDOM_URL_SAFE_PASSWORD
POSTGRES_DB=witerm
SERVER_PORT=37429
TLS_DIRECTORY=./tls
```

Put a valid certificate chain and its matching private key in `tls/fullchain.pem` and `tls/privkey.pem`. Protect the private key and `.env` with filesystem permissions. On Windows Docker Desktop, an absolute certificate path such as `C:/witerm/tls` also works. The container must be able to read both files.

```sh
docker compose -f compose.public.yaml config --quiet
docker compose -f compose.public.yaml up --build -d --wait
docker compose -f compose.public.yaml ps
curl --fail https://YOUR_DOMAIN:37429/readyz
curl --fail https://YOUR_DOMAIN:37429/v1/info
```

The Compose project is `witerm`, including the persistent `postgres_data` volume. Run either the local or public Compose file in a directory, not both together. Subsequent public updates must continue using `-f compose.public.yaml`. Do not delete the database volume during updates.

| Boundary | Configuration |
|---|---|
| Router/NAT | Forward public **TCP 37429** to the Docker host's **TCP 37429** |
| Host firewall | Allow TCP 37429 on the network profile used by the server |
| Client address | `https://YOUR_DOMAIN:37429` on both Mac and iOS |
| Database | Docker network only; no public port |

No UDP port or extra WebSocket port is needed. This deployment does not need inbound ports 80, 443, 8080, or 8443. Keep any separate SSH administration policy independent of this service. DNS must point to the public endpoint, and the certificate must cover that DNS name.

TLS is served directly by Witerm. Plaintext relay mode stays disabled. The server and PostgreSQL communicate over the private, same-host Compose network; do not publish or route that database connection across hosts without database TLS.

After renewing a certificate, replace the files in `tls/` and restart the server container so it loads them:

```sh
docker compose -f compose.public.yaml restart server
docker compose -f compose.public.yaml ps
```

## Behind a shared Nginx

A host that already terminates HTTPS in Nginx can also serve Witerm on its port, for example 443. Witerm keeps its own TLS and ignores forwarded headers, so Nginx must forward to Witerm over HTTPS and verify its certificate. Witerm needs only `/v1/` and `/readyz`; relay connections are long-lived WebSockets. Inside the site's `server` block (with the usual `map $http_upgrade $connection_upgrade` in `http`):

```nginx
location ^~ /v1/ {
    proxy_pass https://127.0.0.1:37429;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_ssl_server_name on;
    proxy_ssl_name YOUR_DOMAIN;
    proxy_ssl_verify on;
    proxy_ssl_verify_depth 4;
    proxy_ssl_trusted_certificate witerm-upstream-ca.pem;  # the certificate chain's root
    proxy_buffering off;
    proxy_read_timeout 1h;
    proxy_send_timeout 1h;
    access_log off;
}
location = /readyz {
    # the same proxy_pass and proxy_ssl_* lines
}
```

Keep the default request buffering: Witerm refuses chunked requests. To keep Witerm off the network, set `SERVER_BIND_ADDRESS=127.0.0.1` in `.env`. To reuse the proxy's certificate files instead of a copy, point `TLS_DIRECTORY` at their folder and set `TLS_CERT_NAME` and `TLS_KEY_NAME` to the chain and key file names (they default to `fullchain.pem` and `privkey.pem`); after renewing, reload Nginx and restart the server container. Clients then use `https://YOUR_DOMAIN` (or the proxy's port). Device identities are scoped to the server address, so devices that move to a new address must pair again.

A successful local healthcheck establishes application/database availability. Verify certificate trust and public routing separately from outside the server's network.

## Windows Docker Desktop over SSH

Docker Desktop's Windows credential helper can be unavailable in an SSH logon session. For public images, use a separate Docker CLI configuration instead of modifying the user's existing Docker login. An explicit anonymous Docker Hub entry prevents automatic credential-helper discovery:

```json
{"auths":{"https://index.docker.io/v1/":{}}}
```

Point `DOCKER_CONFIG` at that dedicated directory and preserve the active Docker engine endpoint through `DOCKER_HOST`. This configuration contains no registry credentials. Private image registries require their own supported authentication setup.

## Offline image delivery

If the server cannot reach Docker Hub during builds, build the Linux image on another Docker host for the server's architecture (for example, `linux/amd64` on Windows x64):

```sh
docker buildx build --platform linux/amd64 --load -t witerm-server:latest \
  --build-arg REVISION="$(git rev-parse --short HEAD)" -f server/Dockerfile .
docker save witerm-server:latest -o witerm-server-amd64.tar
```

Transfer that archive over the verified SSH connection. On the server, load it and use the already-pulled PostgreSQL image:

```sh
docker load -i witerm-server-amd64.tar
docker compose -f compose.public.yaml up --no-build --pull never -d --wait
```

This keeps the same Compose configuration, application source, database volume, and healthchecks. `docker image inspect witerm-server:latest` shows the source revision in the `org.opencontainers.image.revision` label.

Before an update, back up the database to a file on the host and keep the running image for rollback:

```sh
docker exec witerm-postgres-1 sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc -f /tmp/witerm-backup.dump'
docker cp witerm-postgres-1:/tmp/witerm-backup.dump backups/witerm-db-YYYYMMDD-HHMMSS.dump
docker exec witerm-postgres-1 rm -f /tmp/witerm-backup.dump
docker tag witerm-server:latest witerm-server:rollback-YYYYMMDD
```
