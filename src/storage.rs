use std::path::Path;

use anyhow::Context;
use rusqlite::{params, Connection};

use crate::sanitize::SanitizedEvent;
use crate::wait_state::WaitAction;

pub struct EventStore {
    conn: Connection,
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
            "#,
        )?;
        Ok(())
    }
}
