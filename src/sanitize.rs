use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::classifier::classify_command;
use crate::event::{EventKind, Source, Surface, WhileItThinksEvent};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SanitizedEvent {
    pub id: String,
    pub source: Source,
    pub surface: Surface,
    pub kind: EventKind,
    pub timestamp_ms: i64,
    pub project_hash: Option<String>,
    pub cwd_hash: Option<String>,
    pub session_hash: Option<String>,
    pub conversation_hash: Option<String>,
    pub generation_hash: Option<String>,
    pub tool_name: Option<String>,
    pub command_category: Option<String>,
    pub command_summary: Option<String>,
    pub exit_code: Option<i32>,
    pub duration_ms: Option<i64>,
    pub raw_event_name: Option<String>,
}

pub fn sanitize_event(event: &WhileItThinksEvent) -> SanitizedEvent {
    let command = event.command.as_deref().map(classify_command);

    SanitizedEvent {
        id: event.id.clone(),
        source: event.source,
        surface: event.surface,
        kind: event.kind,
        timestamp_ms: event.timestamp_ms,
        project_hash: event.project_root.as_deref().map(hash_value),
        cwd_hash: event.cwd.as_deref().map(hash_value),
        session_hash: event.session_id.as_deref().map(hash_value),
        conversation_hash: event.conversation_id.as_deref().map(hash_value),
        generation_hash: event.generation_id.as_deref().map(hash_value),
        tool_name: event.tool_name.as_ref().map(|name| scrub_short_value(name)),
        command_category: command
            .as_ref()
            .map(|classification| classification.category.to_string()),
        command_summary: command.map(|classification| classification.summary),
        exit_code: event.exit_code,
        duration_ms: event.duration_ms,
        raw_event_name: event
            .raw_event_name
            .as_ref()
            .map(|name| scrub_short_value(name)),
    }
}

pub fn hash_value(value: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(value.as_bytes());
    let digest = hasher.finalize();
    format!("{:x}", digest)[..16].to_string()
}

fn scrub_short_value(value: &str) -> String {
    value
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.' | ':'))
        .take(80)
        .collect()
}
