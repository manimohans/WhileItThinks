use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Source {
    ClaudeCode,
    Codex,
    Shell,
    Macos,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Surface {
    Cli,
    Desktop,
    Unknown,
}

impl Default for Surface {
    fn default() -> Self {
        Self::Unknown
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EventKind {
    SessionStarted,
    PromptSubmitted,
    AgentStarted,
    AgentThought,
    AgentResponse,
    AgentStopped,
    PermissionRequested,
    ToolStarted,
    ToolFinished,
    ToolFailed,
    ShellStarted,
    ShellFinished,
    TaskStarted,
    TaskFinished,
    FileRead,
    FileEdited,
    ActiveAppChanged,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WaitState {
    AiGenerating,
    AgentRunningTools,
    CommandRunning,
    BuildRunning,
    TestRunning,
    PackageInstalling,
    DockerRunning,
    XcodeBuilding,
    WaitingForPermission,
    ReadyForReview,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WhileItThinksEvent {
    pub id: String,
    pub source: Source,
    #[serde(default)]
    pub surface: Surface,
    pub kind: EventKind,
    #[serde(rename = "timestampMs")]
    pub timestamp_ms: i64,

    #[serde(skip_serializing_if = "Option::is_none")]
    pub project_root: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub conversation_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub generation_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub raw_event_name: Option<String>,
}

impl WhileItThinksEvent {
    pub fn new(source: Source, surface: Surface, kind: EventKind) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            source,
            surface,
            kind,
            timestamp_ms: chrono::Utc::now().timestamp_millis(),
            project_root: None,
            cwd: None,
            session_id: None,
            conversation_id: None,
            generation_id: None,
            tool_name: None,
            command: None,
            exit_code: None,
            duration_ms: None,
            raw_event_name: None,
        }
    }

    pub fn with_raw_event_name(mut self, raw_event_name: impl Into<String>) -> Self {
        self.raw_event_name = Some(raw_event_name.into());
        self
    }
}
