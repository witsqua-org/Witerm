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

Put a valid certificate chain and its matching private key in `tls/fullchain.pem` and `tls/privkey.pem`. Protect the private key and `.env` with filesystem permissions. On Windows Docker Desktop, an absolute certificate path such as `C:/work/Witerm/tls` also works. The container must be able to read both files.

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
docker buildx build --platform linux/amd64 --load -t witerm-server:latest -f server/Dockerfile .
docker save witerm-server:latest -o witerm-server-amd64.tar
```

Transfer that archive over the verified SSH connection. On the server, load it and use the already-pulled PostgreSQL image:

```sh
docker load -i witerm-server-amd64.tar
docker compose -f compose.public.yaml up --no-build --pull never -d --wait
```

This keeps the same Compose configuration, application source, database volume, and healthchecks.
