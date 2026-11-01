//! Every run, saved (history.json, newest first), and the result cards the agent shows. Same shapes as the Mac app.

use crate::workflow::WorkflowStep;
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::sync::OnceLock;

#[derive(Clone, Debug, Serialize, Deserialize, Default, PartialEq)]
pub struct CardItem {
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subtitle: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub link: Option<String>,
}

/// Output worth looking at (options, prices, plans, summaries), shown in its own card.
#[derive(Clone, Debug, Serialize, Deserialize, Default, PartialEq)]
pub struct ResultCard {
    pub title: String,
    #[serde(default)]
    pub text: String,
    #[serde(default)]
    pub items: Vec<CardItem>,
}

impl ResultCard {
    /// From a `show` action.
    pub fn from_action(a: &Map<String, Value>) -> Option<ResultCard> {
        let items: Vec<CardItem> = a
            .get("items")
            .and_then(|v| v.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|i| {
                        if let Some(s) = i.as_str() {
                            return Some(CardItem { title: s.into(), ..Default::default() });
                        }
                        let s = |k: &str| i.get(k).and_then(|v| v.as_str().map(String::from).or_else(|| v.as_f64().map(|n| n.to_string())));
                        Some(CardItem { title: s("title")?, subtitle: s("subtitle"), detail: s("detail"), link: s("link") })
                    })
                    .collect()
            })
            .unwrap_or_default();
        let text = a.get("text").and_then(|v| v.as_str()).unwrap_or("").to_string();
        if items.is_empty() && text.is_empty() {
            return None;
        }
        Some(ResultCard { title: a.get("title").and_then(|v| v.as_str()).unwrap_or("Results").to_string(), text, items })
    }

    /// Plain text (to copy, or to give a follow-up task).
    pub fn plain(&self) -> String {
        let mut out = vec![self.title.clone()];
        if !self.text.is_empty() {
            out.push(self.text.clone());
        }
        for i in &self.items {
            let mut line = format!("- {}", i.title);
            if let Some(s) = &i.subtitle {
                line += &format!(" — {s}");
            }
            if let Some(d) = &i.detail {
                line += &format!(" ({d})");
            }
            if let Some(l) = &i.link {
                line += &format!(" {l}");
            }
            out.push(line);
        }
        out.join("\n")
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Entry {
    #[serde(default = "new_id")]
    pub id: String,
    pub date: String,
    pub request: String,
    pub answer: String,
    pub ok: bool,
    #[serde(default)]
    pub steps: Vec<String>,
    #[serde(default)]
    pub app: Option<String>,
    #[serde(default)]
    pub result: Option<ResultCard>,
    #[serde(default)]
    pub trace: Option<Vec<WorkflowStep>>,
    #[serde(default, rename = "readText")]
    pub read_text: Option<String>,
    #[serde(default)]
    pub task: Option<String>,
    #[serde(default, rename = "requiresFreshWork")]
    pub requires_fresh_work: bool,
}

impl Entry {
    /// Redact structured string values before serialization, including nested traces/cards/documents.
    pub fn redacted(self, secrets: &[String]) -> Self {
        let mut secrets = secrets.to_vec();
        for key in [
            "ANTHROPIC_API_KEY",
            "OPENAI_API_KEY",
            "GEMINI_API_KEY",
            "GOOGLE_API_KEY",
            "OPENROUTER_API_KEY",
            "OPENAI_COMPATIBLE_API_KEY",
            "TELEGRAM_BOT_TOKEN",
        ] {
            if let Some(value) = crate::config::value(key) {
                secrets.push(value);
            }
        }
        static TOKENS: OnceLock<regex::Regex> = OnceLock::new();
        let pattern = TOKENS.get_or_init(|| {
            regex::Regex::new(r"(?i)\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|Bearer\s+[A-Za-z0-9._~+/-]{16,})").unwrap()
        });
        fn visit(value: &mut Value, secrets: &[String], pattern: &regex::Regex) {
            match value {
                Value::String(text) => {
                    for secret in secrets.iter().filter(|s| s.len() >= 3) {
                        *text = text.replace(secret, crate::safety::REDACTED);
                    }
                    *text = pattern.replace_all(text, crate::safety::REDACTED).into_owned();
                }
                Value::Array(values) => {
                    for value in values {
                        visit(value, secrets, pattern);
                    }
                }
                Value::Object(values) => {
                    for value in values.values_mut() {
                        visit(value, secrets, pattern);
                    }
                }
                _ => {}
            }
        }
        let mut value = serde_json::to_value(&self).expect("Entry is serializable");
        visit(&mut value, &secrets, pattern);
        serde_json::from_value(value).expect("Redaction preserves Entry shape")
    }
}

fn new_id() -> String {
    uuid::Uuid::new_v4().to_string()
}

impl Entry {
    pub fn when(&self) -> chrono::DateTime<chrono::Local> {
        chrono::DateTime::parse_from_rfc3339(&self.date).map(|d| d.with_timezone(&chrono::Local)).unwrap_or_else(|_| chrono::Local::now())
    }
}

pub struct History {
    entries: Mutex<Vec<Entry>>,
}

fn path() -> std::path::PathBuf {
    crate::paths::data_dir().join("history.json")
}

pub fn history() -> &'static History {
    static H: OnceLock<History> = OnceLock::new();
    H.get_or_init(|| {
        let entries: Vec<Entry> = std::fs::read_to_string(path()).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default();
        let entries: Vec<_> = entries.into_iter().map(|e| e.redacted(&[])).collect();
        crate::task_memory::import(&entries);
        History { entries: Mutex::new(entries) }
    })
}

impl History {
    pub fn entries(&self) -> Vec<Entry> {
        self.entries.lock().clone()
    }

    pub fn latest(&self) -> Option<Entry> {
        self.entries.lock().first().cloned()
    }

    pub fn get(&self, id: &str) -> Option<Entry> {
        self.entries.lock().iter().find(|e| e.id == id).cloned().or_else(|| crate::task_memory::get(id))
    }

    pub fn add(&self, entry: Entry) {
        let entry = entry.redacted(&[]);
        crate::task_memory::record(&entry);
        let mut e = self.entries.lock();
        e.insert(0, entry);
        e.truncate(200);
        self.save(&e);
    }

    pub fn remove(&self, id: &str) {
        crate::task_memory::remove(id);
        let mut e = self.entries.lock();
        e.retain(|x| x.id != id);
        self.save(&e);
    }

    pub fn clear(&self) {
        crate::task_memory::clear();
        let mut e = self.entries.lock();
        e.clear();
        self.save(&e);
    }

    fn save(&self, entries: &[Entry]) {
        if let Ok(t) = serde_json::to_string_pretty(entries) {
            let p = path();
            let tmp = p.with_extension("json.tmp");
            if std::fs::write(&tmp, t).is_ok() {
                let _ = std::fs::rename(&tmp, &p);
            }
        }
    }
}
