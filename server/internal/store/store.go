package store

import (
	"context"
	"crypto/sha256"
	"embed"
	"fmt"
	"io/fs"
	"sort"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed migrations/*.sql
var migrations embed.FS

func Open(ctx context.Context, databaseURL string) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		// The pgx parse error may include credentials from the URL.
		return nil, fmt.Errorf("invalid DATABASE_URL")
	}
	cfg.MaxConns = 10
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("cannot create database pool")
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("database connection failed; check connectivity and credentials")
	}
	return pool, nil
}

// Migrate applies embedded SQL in one transaction. The transaction-scoped lock
// serializes startup migrations across server instances.
func Migrate(ctx context.Context, pool *pgxpool.Pool) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(context.Background())
	if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock(8473192601)"); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
        name text PRIMARY KEY,
        checksum text NOT NULL,
        applied_at timestamptz NOT NULL DEFAULT now()
    )`); err != nil {
		return err
	}
	files, err := fs.Glob(migrations, "migrations/*.sql")
	if err != nil {
		return err
	}
	sort.Strings(files)
	for _, name := range files {
		body, err := migrations.ReadFile(name)
		if err != nil {
			return err
		}
		checksum := fmt.Sprintf("%x", sha256.Sum256(body))
		var saved string
		if err := tx.QueryRow(ctx, "SELECT COALESCE((SELECT checksum FROM schema_migrations WHERE name = $1), '')", name).Scan(&saved); err != nil {
			return err
		}
		if saved != "" {
			if saved != checksum {
				return fmt.Errorf("migration %s has changed after being applied", name)
			}
			continue
		}
		if _, err := tx.Exec(ctx, strings.TrimSpace(string(body))); err != nil {
			return fmt.Errorf("apply %s: %w", name, err)
		}
		if _, err := tx.Exec(ctx, "INSERT INTO schema_migrations (name, checksum) VALUES ($1, $2)", name, checksum); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

// ValidateSchema prevents an unmigrated server from reporting itself as ready.
func ValidateSchema(ctx context.Context, pool *pgxpool.Pool) error {
	files, err := fs.Glob(migrations, "migrations/*.sql")
	if err != nil {
		return err
	}
	for _, name := range files {
		body, err := migrations.ReadFile(name)
		if err != nil {
			return err
		}
		var saved string
		if err := pool.QueryRow(ctx, "SELECT checksum FROM schema_migrations WHERE name = $1", name).Scan(&saved); err != nil {
			return fmt.Errorf("database schema is not initialized; run with -migrate-only")
		}
		if saved != fmt.Sprintf("%x", sha256.Sum256(body)) {
			return fmt.Errorf("migration %s does not match the database", name)
		}
	}
	return nil
}
