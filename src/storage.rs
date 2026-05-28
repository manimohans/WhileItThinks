use std::path::Path;

use anyhow::Context;
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};

use crate::sanitize::SanitizedEvent;
use crate::wait_state::WaitAction;

pub struct EventStore {
    conn: Connection,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StorageHealth {
    pub ok: bool,
    pub event_count: i64,
    pub last_event_timestamp_ms: Option<i64>,
}

impl EventStore {
    pub fn open(path: &Path) -> anyhow::Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("create app support dir {}", parent.display()))?;
        }
        let conn = Connection::open(path)
            .with_context(|| format!("open sqlite database {}", path.display()))?;
        let store = Self { conn };
        store.migrate()?;
        Ok(store)
    }

    pub fn in_memory() -> anyhow::Result<Self> {
        let store = Self {
            conn: Connection::open_in_memory()?,
        };
        store.migrate()?;
        Ok(store)
    }

    pub fn insert_event(&self, event: &SanitizedEvent, action: &WaitAction) -> anyhow::Result<()> {
        self.conn.execute(
            r#"
            INSERT INTO events (
                id, source, surface, kind, timestamp_ms, project_hash, cwd_hash,
                session_hash, conversation_hash, generation_hash, tool_name,
                command_category, command_summary, exit_code, duration_ms,
                raw_event_name, action_json
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17)
            "#,
            params![
                event.id,
                serde_json::to_string(&event.source)?,
                serde_json::to_string(&event.surface)?,
                serde_json::to_string(&event.kind)?,
                event.timestamp_ms,
                event.project_hash,
                event.cwd_hash,
                event.session_hash,
                event.conversation_hash,
                event.generation_hash,
                event.tool_name,
                event.command_category,
                event.command_summary,
                event.exit_code,
                event.duration_ms,
                event.raw_event_name,
                serde_json::to_string(action)?,
            ],
        )?;
        Ok(())
    }

    pub fn health(&self) -> anyhow::Result<StorageHealth> {
        let quick_check: String = self
            .conn
            .query_row("PRAGMA quick_check", [], |row| row.get(0))
            .context("run sqlite quick_check")?;
        let event_count = self.event_count()?;
        let last_event_timestamp_ms = self
            .conn
            .query_row("SELECT MAX(timestamp_ms) FROM events", [], |row| {
                row.get::<_, Option<i64>>(0)
            })
            .context("read last event timestamp")?;

        Ok(StorageHealth {
            ok: quick_check.eq_ignore_ascii_case("ok"),
            event_count,
            last_event_timestamp_ms,
        })
    }

    pub fn event_count(&self) -> anyhow::Result<i64> {
        self.conn
            .query_row("SELECT COUNT(*) FROM events", [], |row| row.get(0))
            .context("count events")
    }

    pub fn event_count_by_source(&self, source_json: &str) -> anyhow::Result<i64> {
        self.conn
            .query_row(
                "SELECT COUNT(*) FROM events WHERE source = ?1",
                [source_json],
                |row| row.get(0),
            )
            .with_context(|| format!("count events for source {source_json}"))
    }

    pub fn event_exists(&self, id: &str) -> anyhow::Result<bool> {
        self.conn
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM events WHERE id = ?1)",
                [id],
                |row| row.get::<_, i64>(0),
            )
            .map(|value| value != 0)
            .with_context(|| format!("check event {id}"))
    }

    pub fn event_payload_contains(&self, needle: &str) -> anyhow::Result<bool> {
        let pattern = format!("%{needle}%");
        self.conn
            .query_row(
                r#"
                SELECT EXISTS(
                    SELECT 1 FROM events
                    WHERE project_hash LIKE ?1
                       OR cwd_hash LIKE ?1
                       OR session_hash LIKE ?1
                       OR conversation_hash LIKE ?1
                       OR generation_hash LIKE ?1
                       OR tool_name LIKE ?1
                       OR command_category LIKE ?1
                       OR command_summary LIKE ?1
                       OR raw_event_name LIKE ?1
                       OR action_json LIKE ?1
                )
                "#,
                [pattern],
                |row| row.get::<_, i64>(0),
            )
            .map(|value| value != 0)
            .with_context(|| format!("search sanitized event payloads for {needle}"))
    }

    fn migrate(&self) -> anyhow::Result<()> {
        self.conn.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS events (
                rowid INTEGER PRIMARY KEY AUTOINCREMENT,
                id TEXT NOT NULL,
                source TEXT NOT NULL,
                surface TEXT NOT NULL,
                kind TEXT NOT NULL,
                timestamp_ms INTEGER NOT NULL,
                project_hash TEXT,
                cwd_hash TEXT,
                session_hash TEXT,
                conversation_hash TEXT,
                generation_hash TEXT,
                tool_name TEXT,
                command_category TEXT,
                command_summary TEXT,
                exit_code INTEGER,
                duration_ms INTEGER,
                raw_event_name TEXT,
                action_json TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_events_timestamp_ms ON events(timestamp_ms);
            CREATE INDEX IF NOT EXISTS idx_events_source ON events(source);
            CREATE UNIQUE INDEX IF NOT EXISTS idx_events_id ON events(id);
            "#,
        )?;
        Ok(())
    }
}
