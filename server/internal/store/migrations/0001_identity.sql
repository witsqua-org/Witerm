CREATE TABLE users (
    id uuid PRIMARY KEY,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE devices (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id),
    name text NOT NULL CHECK (length(name) BETWEEN 1 AND 128),
    platform text NOT NULL CHECK (platform IN ('macos', 'ios')),
    identity_public_key bytea NOT NULL UNIQUE,
    created_at timestamptz NOT NULL DEFAULT now(),
    revoked_at timestamptz
);
CREATE INDEX devices_user_id_idx ON devices(user_id);

CREATE TABLE device_grants (
    id uuid PRIMARY KEY,
    host_device_id uuid NOT NULL REFERENCES devices(id),
    client_device_id uuid NOT NULL REFERENCES devices(id),
    permission text NOT NULL CHECK (permission IN ('view', 'control')),
    created_at timestamptz NOT NULL DEFAULT now(),
    revoked_at timestamptz,
    CHECK (host_device_id <> client_device_id)
);
CREATE UNIQUE INDEX device_grants_active_idx
    ON device_grants(host_device_id, client_device_id) WHERE revoked_at IS NULL;
CREATE INDEX device_grants_client_idx ON device_grants(client_device_id);

CREATE TABLE pairing_requests (
    id uuid PRIMARY KEY,
    host_device_id uuid NOT NULL REFERENCES devices(id),
    secret_hash bytea NOT NULL UNIQUE,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    consumed_at timestamptz,
    CHECK (expires_at > created_at),
    CHECK (consumed_at IS NULL OR consumed_at >= created_at)
);
CREATE INDEX pairing_requests_expires_at_idx ON pairing_requests(expires_at);

