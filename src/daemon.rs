use std::sync::Arc;

use crate::event::WhileItThinksEvent;
use crate::sanitize::{sanitize_event, SanitizedEvent};
use crate::storage::{EventStore, StorageHealth};
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

#[derive(Debug, Clone, serde::Serialize)]
pub struct RuntimeHealth {
    pub ok: bool,
    pub active_wait_count: usize,
    pub storage: StorageHealth,
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

    pub fn health(&self) -> anyhow::Result<RuntimeHealth> {
        let storage = self.store.health()?;
        Ok(RuntimeHealth {
            ok: storage.ok,
            active_wait_count: self.engine.active_count(),
            storage,
        })
    }
}

pub type SharedRuntime = Arc<tokio::sync::Mutex<EventRuntime>>;
