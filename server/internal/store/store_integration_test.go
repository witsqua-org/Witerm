package store

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestMigrationsAndDeviceGrants(t *testing.T) {
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("set TEST_DATABASE_URL to run PostgreSQL integration tests")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	admin, err := Open(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer admin.Close()
	schema := fmt.Sprintf("witerm_test_%d", time.Now().UnixNano())
	identifier := pgx.Identifier{schema}.Sanitize()
	if _, err := admin.Exec(ctx, "CREATE SCHEMA "+identifier); err != nil {
		t.Fatal(err)
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if _, err := admin.Exec(cleanup, "DROP SCHEMA "+identifier+" CASCADE"); err != nil {
			t.Errorf("clean up test schema: %v", err)
		}
	}()
	cfg, err := pgxpool.ParseConfig(url)
	if err != nil {
		t.Fatal(err)
	}
	cfg.ConnConfig.RuntimeParams["search_path"] = schema
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	if err := ValidateSchema(ctx, pool); err == nil {
		t.Fatal("uninitialized database must fail validation")
	}
	results := make(chan error, 2)
	for range 2 {
		go func() { results <- Migrate(ctx, pool) }()
	}
	for range 2 {
		if err := <-results; err != nil {
			t.Fatal(err)
		}
	}
	if err := ValidateSchema(ctx, pool); err != nil {
		t.Fatal(err)
	}
	const setup = `
        INSERT INTO users(id) VALUES ('00000000-0000-0000-0000-000000000001');
        INSERT INTO devices(id, user_id, name, platform, identity_public_key) VALUES
        ('00000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001', 'Mac', 'macos', decode(repeat('01',32),'hex')),
        ('00000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000001', 'iPhone', 'ios', decode(repeat('02',32),'hex'));`
	if _, err := pool.Exec(ctx, setup); err != nil {
		t.Fatal(err)
	}
	const grant = `INSERT INTO device_grants(id, host_device_id, client_device_id, permission)
        VALUES ($1, '00000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000003', 'control')`
	if _, err := pool.Exec(ctx, grant, "00000000-0000-0000-0000-000000000004"); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, grant, "00000000-0000-0000-0000-000000000005"); err == nil {
		t.Fatal("duplicate active authorization must be rejected")
	}
	if _, err := pool.Exec(ctx, "UPDATE device_grants SET revoked_at = now()"); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, grant, "00000000-0000-0000-0000-000000000005"); err != nil {
		t.Fatalf("reauthorization after revocation: %v", err)
	}
	if _, err := pool.Exec(ctx, "UPDATE schema_migrations SET checksum = 'modified'"); err != nil {
		t.Fatal(err)
	}
	if err := Migrate(ctx, pool); err == nil {
		t.Fatal("changed migration must fail")
	}
}
