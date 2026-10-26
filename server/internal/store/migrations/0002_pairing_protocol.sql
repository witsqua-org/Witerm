ALTER TABLE devices ADD CONSTRAINT devices_ed25519_key_length
    CHECK (octet_length(identity_public_key) = 32) NOT VALID;

ALTER TABLE pairing_requests
    ADD COLUMN client_device_id uuid REFERENCES devices(id),
    ADD COLUMN status text NOT NULL DEFAULT 'waiting'
        CHECK (status IN ('waiting', 'pending', 'approved', 'rejected'));
ALTER TABLE pairing_requests ADD CONSTRAINT pairing_distinct_devices
    CHECK (client_device_id IS NULL OR client_device_id <> host_device_id);
CREATE INDEX pairing_requests_host_idx ON pairing_requests(host_device_id);

ALTER TABLE device_grants
    ADD COLUMN pairing_id uuid UNIQUE REFERENCES pairing_requests(id),
    ADD COLUMN approval_signature bytea;
ALTER TABLE device_grants ADD CONSTRAINT signed_pairing_grant
    CHECK ((pairing_id IS NULL AND approval_signature IS NULL)
        OR (pairing_id IS NOT NULL AND approval_signature IS NOT NULL
            AND octet_length(approval_signature) = 64));
