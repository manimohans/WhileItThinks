use std::sync::Arc;

use crate::event::WhileItThinksEvent;
use crate::sanitize::{sanitize_event, SanitizedEvent};
use crate::storage::EventStore;
use crate::wait_state::{WaitAction, WaitStateEngine};

pub struct EventRuntime {
    store: EventStore,
    engine: WaitStateEngine,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct RuntimeResult {
    pub ok: bool,
    pub sanitized: SanitizedEvent,
    pub action: WaitAction,
}

impl EventRuntime {
    pub fn new(store: EventStore) -> Self {
        Self {
            store,
            engine: WaitStateEngine::default(),
        }
    }

    pub fn handle_event(&mut self, event: WhileItThinksEvent) -> anyhow::Result<RuntimeResult> {
        let sanitized = sanitize_event(&event);
        let action = self.engine.apply(&event);
        self.store.insert_event(&sanitized, &action)?;
        Ok(RuntimeResult {
            ok: true,
            sanitized,
            action,
        })
    }
}

pub type SharedRuntime = Arc<tokio::sync::Mutex<EventRuntime>>;
