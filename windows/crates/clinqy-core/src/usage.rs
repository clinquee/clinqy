//! Local model request usage shared by the tray dashboard and the CLI.

use chrono::{DateTime, Datelike, Duration, Local, SecondsFormat, TimeZone, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io::Write;
use std::sync::OnceLock;

static LOCK: OnceLock<std::sync::Mutex<()>> = OnceLock::new();

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageEntry {
    pub at: String,
    pub provider: String,
    pub model: String,
    #[serde(default)]
    pub input_tokens: Option<u64>,
    #[serde(default)]
    pub output_tokens: Option<u64>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderUsage {
    pub provider: String,
    pub requests: u64,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub metered_requests: u64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DailyUsage {
    pub day: String,
    pub requests: u64,
    pub input_tokens: u64,
    pub output_tokens: u64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageSummary {
    pub requests: u64,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub metered_requests: u64,
    pub providers: Vec<ProviderUsage>,
    pub days: Vec<DailyUsage>,
}

pub fn record(provider: &str, model: &str, input_tokens: Option<u64>, output_tokens: Option<u64>) {
    let entry = UsageEntry {
        at: Local::now().to_rfc3339_opts(SecondsFormat::Secs, true),
        provider: provider.to_string(),
        model: model.to_string(),
        input_tokens,
        output_tokens,
    };
    let Some(line) = serde_json::to_string(&entry).ok() else { return };
    let _guard = LOCK.get_or_init(|| std::sync::Mutex::new(())).lock().ok();
    let path = crate::paths::local_dir().join("usage.jsonl");
    if let Some(parent) = path.parent() {
        if std::fs::create_dir_all(parent).is_err() {
            return;
        }
    }
    if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(file, "{line}");
    }
}

fn range_start(range: &str) -> Option<i64> {
    let now = Local::now();
    match range {
        "month" => Local.with_ymd_and_hms(now.year(), now.month(), 1, 0, 0, 0).single().map(|d| d.timestamp()),
        "thirtyDays" => Some((now - Duration::days(30)).timestamp()),
        _ => None,
    }
}

pub fn summary(range: &str) -> UsageSummary {
    let path = crate::paths::local_dir().join("usage.jsonl");
    let start = range_start(range);
    let text = std::fs::read_to_string(path).unwrap_or_default();
    let mut grouped: HashMap<String, ProviderUsage> = HashMap::new();
    let mut days: HashMap<String, DailyUsage> = HashMap::new();
    for entry in text.lines().filter_map(|line| serde_json::from_str::<UsageEntry>(line).ok()) {
        let parsed = DateTime::parse_from_rfc3339(&entry.at).ok();
        let timestamp = parsed.map(|d| d.timestamp());
        if start.map(|s| timestamp.map(|t| t < s).unwrap_or(true)).unwrap_or(false) {
            continue;
        }
        let row = grouped.entry(entry.provider.clone()).or_insert_with(|| ProviderUsage {
            provider: entry.provider,
            requests: 0,
            input_tokens: 0,
            output_tokens: 0,
            metered_requests: 0,
        });
        row.requests += 1;
        if let Some(n) = entry.input_tokens {
            row.input_tokens += n;
        }
        if let Some(n) = entry.output_tokens {
            row.output_tokens += n;
        }
        if entry.input_tokens.is_some() || entry.output_tokens.is_some() {
            row.metered_requests += 1;
        }
        if let Some(timestamp) = timestamp {
            let day = DateTime::<Utc>::from_timestamp(timestamp, 0)
                .map(|date| date.with_timezone(&Local))
                .unwrap_or_else(Local::now)
                .format("%Y-%m-%d")
                .to_string();
            let daily = days.entry(day.clone()).or_insert(DailyUsage { day, requests: 0, input_tokens: 0, output_tokens: 0 });
            daily.requests += 1;
            daily.input_tokens += entry.input_tokens.unwrap_or(0);
            daily.output_tokens += entry.output_tokens.unwrap_or(0);
        }
    }
    let mut providers: Vec<_> = grouped.into_values().collect();
    providers.sort_by_key(|a| std::cmp::Reverse(a.requests));
    let mut days: Vec<_> = days.into_values().collect();
    days.sort_by(|a, b| a.day.cmp(&b.day));
    UsageSummary {
        requests: providers.iter().map(|p| p.requests).sum(),
        input_tokens: providers.iter().map(|p| p.input_tokens).sum(),
        output_tokens: providers.iter().map(|p| p.output_tokens).sum(),
        metered_requests: providers.iter().map(|p| p.metered_requests).sum(),
        providers,
        days,
    }
}
