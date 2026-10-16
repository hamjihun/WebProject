// Package db opens the SQLite metadata database and applies the schema.
package db

import (
	"database/sql"
	"fmt"

	_ "modernc.org/sqlite"
)

const schema = `
CREATE TABLE IF NOT EXISTS users (
	id            INTEGER PRIMARY KEY,
	username      TEXT NOT NULL UNIQUE COLLATE NOCASE,
	display_name  TEXT NOT NULL DEFAULT '',
	password_hash TEXT NOT NULL DEFAULT '',
	is_admin      INTEGER NOT NULL DEFAULT 0,
	disabled      INTEGER NOT NULL DEFAULT 0,
	write_blocked INTEGER NOT NULL DEFAULT 0,
	allow_copy    INTEGER NOT NULL DEFAULT 0,
	failed_logins INTEGER NOT NULL DEFAULT 0,
	locked_until  INTEGER NOT NULL DEFAULT 0,
	created_at    INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS groups (
	id   INTEGER PRIMARY KEY,
	name TEXT NOT NULL UNIQUE COLLATE NOCASE
);

CREATE TABLE IF NOT EXISTS group_members (
	group_id INTEGER NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
	user_id  INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	PRIMARY KEY (group_id, user_id)
);

-- A share is one drive letter on the PC (e.g. 일산영업 -> O:).
-- personal=1 means every user gets a private space inside it (개인문서함).
CREATE TABLE IF NOT EXISTS shares (
	id           INTEGER PRIMARY KEY,
	name         TEXT NOT NULL UNIQUE COLLATE NOCASE,
	drive_letter TEXT NOT NULL DEFAULT '',
	personal     INTEGER NOT NULL DEFAULT 0,
	quota_bytes  INTEGER NOT NULL DEFAULT 0,
	created_at   INTEGER NOT NULL
);

-- level: 1=read, 2=write, 3=manage (manage = approves export requests)
CREATE TABLE IF NOT EXISTS share_acl (
	share_id       INTEGER NOT NULL REFERENCES shares(id) ON DELETE CASCADE,
	principal_type TEXT NOT NULL CHECK (principal_type IN ('user','group')),
	principal_id   INTEGER NOT NULL,
	level          INTEGER NOT NULL CHECK (level BETWEEN 1 AND 3),
	PRIMARY KEY (share_id, principal_type, principal_id)
);

-- Files and folders. owner_id is the personal-space owner (0 for team shares).
-- Deleted nodes stay here (deleted_at set) until the retention period ends.
CREATE TABLE IF NOT EXISTS nodes (
	id           INTEGER PRIMARY KEY,
	share_id     INTEGER NOT NULL REFERENCES shares(id) ON DELETE CASCADE,
	owner_id     INTEGER NOT NULL DEFAULT 0,
	parent_id    INTEGER REFERENCES nodes(id),
	name         TEXT NOT NULL COLLATE NOCASE,
	is_dir       INTEGER NOT NULL,
	size         INTEGER NOT NULL DEFAULT 0,
	blob_sha     TEXT NOT NULL DEFAULT '',
	created_at   INTEGER NOT NULL,
	created_by   INTEGER NOT NULL DEFAULT 0,
	modified_at  INTEGER NOT NULL,
	modified_by  INTEGER NOT NULL DEFAULT 0,
	deleted_at   INTEGER,
	deleted_by   INTEGER,
	delete_batch TEXT,
	delete_root  INTEGER NOT NULL DEFAULT 0,
	orig_path    TEXT NOT NULL DEFAULT '',
	prev_name    TEXT NOT NULL DEFAULT '',
	prev_name_at INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX IF NOT EXISTS nodes_live_name
	ON nodes(parent_id, name) WHERE deleted_at IS NULL AND parent_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS nodes_root ON nodes(share_id, owner_id) WHERE parent_id IS NULL;
CREATE INDEX IF NOT EXISTS nodes_deleted ON nodes(deleted_at) WHERE deleted_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS nodes_usage ON nodes(share_id, owner_id, size) WHERE deleted_at IS NULL AND is_dir=0;
CREATE INDEX IF NOT EXISTS nodes_batch ON nodes(delete_batch) WHERE delete_batch IS NOT NULL;

CREATE TABLE IF NOT EXISTS versions (
	id         INTEGER PRIMARY KEY,
	node_id    INTEGER NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
	blob_sha   TEXT NOT NULL,
	size       INTEGER NOT NULL,
	created_at INTEGER NOT NULL,
	created_by INTEGER NOT NULL DEFAULT 0,
	note       TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS versions_node ON versions(node_id, id);
CREATE INDEX IF NOT EXISTS versions_blob ON versions(blob_sha);

CREATE TABLE IF NOT EXISTS sessions (
	id         INTEGER PRIMARY KEY,
	token_hash TEXT NOT NULL UNIQUE,
	user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	kind       TEXT NOT NULL,
	device     TEXT NOT NULL DEFAULT '',
	ip         TEXT NOT NULL DEFAULT '',
	agent_ver  TEXT NOT NULL DEFAULT '',
	mounted    TEXT NOT NULL DEFAULT '',
	created_at INTEGER NOT NULL,
	expires_at INTEGER NOT NULL,
	last_seen  INTEGER NOT NULL
);

-- 반출 신청
CREATE TABLE IF NOT EXISTS exports (
	id             INTEGER PRIMARY KEY,
	node_id        INTEGER NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
	version_id     INTEGER NOT NULL,
	share_id       INTEGER NOT NULL,
	file_name      TEXT NOT NULL,
	file_path      TEXT NOT NULL,
	requester_id   INTEGER NOT NULL,
	reason         TEXT NOT NULL,
	status         TEXT NOT NULL DEFAULT 'pending',
	approver_id    INTEGER,
	decision_note  TEXT NOT NULL DEFAULT '',
	decided_at     INTEGER,
	created_at     INTEGER NOT NULL,
	expires_at     INTEGER,
	download_count INTEGER NOT NULL DEFAULT 0,
	max_downloads  INTEGER NOT NULL DEFAULT 3
);
CREATE INDEX IF NOT EXISTS exports_status ON exports(status);

CREATE TABLE IF NOT EXISTS audit (
	id         INTEGER PRIMARY KEY,
	ts         INTEGER NOT NULL,
	user_id    INTEGER NOT NULL DEFAULT 0,
	username   TEXT NOT NULL DEFAULT '',
	ip         TEXT NOT NULL DEFAULT '',
	client     TEXT NOT NULL DEFAULT '',
	action     TEXT NOT NULL,
	share_name TEXT NOT NULL DEFAULT '',
	path       TEXT NOT NULL DEFAULT '',
	detail     TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS audit_ts ON audit(ts);
CREATE INDEX IF NOT EXISTS audit_user ON audit(user_id, ts);

CREATE TABLE IF NOT EXISTS settings (
	key   TEXT PRIMARY KEY,
	value TEXT NOT NULL
);
`

// Open opens (creating if needed) the database at path and applies the schema.
// A single connection is used: SQLite allows one writer anyway, and it keeps
// transactions simple. Callers must never run a query on db while holding a tx.
func Open(path string) (*sql.DB, error) {
	dsn := fmt.Sprintf("file:%s?_pragma=busy_timeout(10000)&_pragma=journal_mode(WAL)&_pragma=foreign_keys(1)&_pragma=synchronous(NORMAL)", path)
	d, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	d.SetMaxOpenConns(1)
	if _, err := d.Exec(schema); err != nil {
		d.Close()
		return nil, fmt.Errorf("apply schema: %w", err)
	}
	// Columns added after the first release: add them to existing databases.
	for _, c := range []struct{ table, column, def string }{
		{"users", "allow_copy", "INTEGER NOT NULL DEFAULT 0"},
	} {
		if err := ensureColumn(d, c.table, c.column, c.def); err != nil {
			d.Close()
			return nil, err
		}
	}
	return d, nil
}

func ensureColumn(d *sql.DB, table, column, def string) error {
	rows, err := d.Query(`SELECT name FROM pragma_table_info(?)`, table)
	if err != nil {
		return err
	}
	found := false
	for rows.Next() {
		var name string
		rows.Scan(&name)
		if name == column {
			found = true
		}
	}
	rows.Close()
	if found {
		return nil
	}
	_, err = d.Exec(`ALTER TABLE ` + table + ` ADD COLUMN ` + column + ` ` + def)
	return err
}
