//! Clinqy's agent, independent of the operating system. The OS-facing parts (reading the screen, input, the
//! companion cursor) come in through the traits in `platform`; everything else — the model loop, prompt, memory,
//! history, workflows, the browser-extension bridge, background jobs — lives here.

pub mod agent;
pub mod acp;
pub mod applications;
pub mod background;
pub mod bridge;
pub mod clicks;
pub mod config;
pub mod delegation;
pub mod files;
pub mod hands;
pub mod history;
pub mod log;
pub mod media;
pub mod memory;
pub mod models;
mod model_stream;
pub mod observation;
pub mod page;
pub mod paths;
pub mod pdf;
pub mod platform;
pub mod profile;
pub mod prompt;
pub mod provider;
pub mod replay;
pub mod reply;
pub mod safety;
pub mod scheduler;
pub mod session;
pub mod skills;
pub mod stats;
pub mod taskstore;
pub mod task_memory;
pub mod usage;
pub mod when;
pub mod worker;
pub mod workflow;

pub use agent::{Agent, Event, RunOptions, Snapshot};
pub use platform::{Buddy, Platform};
