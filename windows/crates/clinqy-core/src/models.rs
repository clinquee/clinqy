//! Which models each provider really offers on this device, asked of the provider itself: `agy models`,
//! `codex debug models`, each API's model list, Ollama's installed models. So the choices follow the user's own
//! plan and installs. If a provider can't say, its usual tiers are offered. The choice is saved per provider in this
//! device's settings file.

use crate::provider::Provider;
use serde::Serialize;
use serde_json::Value;
use std::time::Duration;

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct Choice {
    /// What's saved and sent. Empty: the provider's own default.
    pub id: String,
    pub label: String,
}

fn choice(id: &str, label: &str) -> Choice {
    Choice { id: id.to_string(), label: label.to_string() }
}

/// The tiers every provider maps to something.
fn tiers() -> Vec<Choice> {
    vec![choice("haiku", "Fast · Haiku"), choice("sonnet", "Balanced · Sonnet"), choice("opus", "Most capable · Opus")]
}

fn http() -> reqwest::Client {
    reqwest::Client::builder().timeout(Duration::from_secs(8)).build().unwrap_or_default()
}

async fn run_cli(p: Provider, args: &[&str]) -> Option<String> {
    let cli = p.cli()?;
    let mut command = tokio::process::Command::new(&cli.program);
    command.args(&cli.prefix).args(args).creation_flags(crate::session::CREATE_NO_WINDOW).stdin(std::process::Stdio::null()).kill_on_drop(true);
    let out = tokio::time::timeout(Duration::from_secs(25), command.output()).await.ok()?.ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

/// `gemini-3.8-flash-low<TAB>Gemini 3.8 Flash (Low)`, one per line.
pub fn parse_agy(text: &str) -> Vec<Choice> {
    text.lines()
        .filter_map(|l| {
            let (id, label) = l.split_once('\t')?;
            (!id.trim().is_empty() && !id.contains(' ')).then(|| choice(id.trim(), label.trim()))
        })
        .collect()
}

/// `codex debug models`: {"models": [{slug, display_name, visibility, priority}]}, offering the ones it lists.
pub fn parse_codex(text: &str) -> Vec<Choice> {
    let Ok(body) = serde_json::from_str::<Value>(text) else { return vec![] };
    let mut models: Vec<&Value> = body["models"].as_array().map(|a| a.iter().filter(|m| m["visibility"] == "list").collect()).unwrap_or_default();
    models.sort_by_key(|m| m["priority"].as_i64().unwrap_or(999));
    models.iter().filter_map(|m| Some(choice(m["slug"].as_str()?, m["display_name"].as_str().or(m["slug"].as_str())?))).collect()
}

async fn from_cli(p: Provider) -> Vec<Choice> {
    match p {
        Provider::AgyCli => parse_agy(&run_cli(p, &["models"]).await.unwrap_or_default()),
        Provider::CodexCli => {
            let mut text = run_cli(p, &["debug", "models"]).await.unwrap_or_default();
            if text.is_empty() {
                text = std::fs::read_to_string(crate::paths::home().join(".codex").join("models_cache.json")).unwrap_or_default();
            }
            parse_codex(&text)
        }
        _ => vec![],
    }
}

async fn get(url: &str, headers: &[(&str, String)]) -> Option<Value> {
    let mut request = http().get(url);
    for (k, v) in headers {
        request = request.header(*k, v);
    }
    request.send().await.ok()?.error_for_status().ok()?.json().await.ok()
}

async fn from_api(p: Provider) -> Vec<Choice> {
    let key = p.key().unwrap_or_default();
    let base = p.base_url();
    let bearer = vec![("Authorization", format!("Bearer {key}"))];
    let ids = |v: &Value, keep: &dyn Fn(&str) -> bool| -> Vec<Choice> {
        v["data"].as_array().map(|a| a.iter().filter_map(|m| m["id"].as_str()).filter(|id| keep(id)).map(|id| choice(id, id)).collect()).unwrap_or_default()
    };
    match p {
        Provider::Anthropic => {
            let Some(v) = get(&format!("{base}/v1/models?limit=100"), &[("x-api-key", key), ("anthropic-version", "2023-06-01".into())]).await else { return vec![] };
            v["data"].as_array().map(|a| a.iter().filter_map(|m| Some(choice(m["id"].as_str()?, m["display_name"].as_str().or(m["id"].as_str())?))).collect()).unwrap_or_default()
        }
        Provider::OpenAi => {
            let Some(v) = get(&format!("{base}/models"), &bearer).await else { return vec![] };
            let mut list = ids(&v, &|id| id.starts_with("gpt-") && !["audio", "realtime", "tts", "transcribe", "image", "search"].iter().any(|w| id.contains(w)));
            list.sort_by(|a, b| b.id.cmp(&a.id));
            list
        }
        Provider::OpenRouter => {
            let Some(v) = get(&format!("{base}/models"), &bearer).await else { return vec![] };
            // Clinqy sends screenshots, so a model has to take images.
            v["data"]
                .as_array()
                .map(|a| {
                    a.iter()
                        .filter(|m| m["architecture"]["input_modalities"].as_array().map(|i| i.iter().any(|x| x == "image")).unwrap_or(true))
                        .filter_map(|m| Some(choice(m["id"].as_str()?, m["name"].as_str().or(m["id"].as_str())?)))
                        .take(80)
                        .collect()
                })
                .unwrap_or_default()
        }
        Provider::Gemini => {
            let Some(v) = get(&format!("{base}/models?key={key}&pageSize=100"), &[]).await else { return vec![] };
            v["models"]
                .as_array()
                .map(|a| {
                    a.iter()
                        .filter(|m| m["supportedGenerationMethods"].as_array().map(|g| g.iter().any(|x| x == "generateContent")).unwrap_or(false))
                        .filter_map(|m| Some(choice(m["name"].as_str()?.trim_start_matches("models/"), m["displayName"].as_str().or(m["name"].as_str())?)))
                        .collect()
                })
                .unwrap_or_default()
        }
        Provider::Ollama => {
            let Some(v) = get(&format!("{}/api/tags", base.trim_end_matches("/v1")), &[]).await else { return vec![] };
            v["models"].as_array().map(|a| a.iter().filter_map(|m| m["name"].as_str()).map(|n| choice(n, n)).collect()).unwrap_or_default()
        }
        Provider::Compatible => get(&format!("{base}/models"), &bearer).await.map(|v| ids(&v, &|_| true)).unwrap_or_default(),
        _ => vec![],
    }
}

/// The models to offer for `p`: what it reports, or its tiers when it can't say.
pub async fn list(p: Provider) -> Vec<Choice> {
    let found = if p.is_cli() { from_cli(p).await } else { from_api(p).await };
    match p {
        // Claude Code resolves these aliases to the newest model the user's plan has.
        Provider::ClaudeCli => tiers(),
        Provider::CodexCli => {
            let mut all = vec![choice("", "Codex default")];
            all.extend(found);
            all
        }
        _ if !found.is_empty() => found,
        Provider::Ollama | Provider::Compatible => vec![],
        _ => tiers(),
    }
}

/// The saved model's id for the picker ("" for a provider default).
/// For tier-based providers (not Claude CLI), resolve the tier alias to the real model id
/// so the picker can match it against the provider's choice list.
pub fn saved(p: Provider) -> String {
    let m = p.default_model();
    if p == Provider::CodexCli && m == "sonnet" {
        return String::new();
    }
    // Claude CLI keeps tier aliases ("sonnet", "haiku", "opus") as-is — it resolves them
    // itself at runtime. Every other provider needs the concrete id so the UI picker can
    // highlight the saved entry in its list of choices.
    if p != Provider::ClaudeCli && ["haiku", "sonnet", "opus"].contains(&m.to_lowercase().as_str()) {
        return p.model(&m);
    }
    m
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_what_agy_lists() {
        let text = "gemini-3.8-flash-high\tGemini 3.8 Flash (High)\nclaude-opus-4-6-thinking\tClaude Opus 4.6 (Thinking)\nnot a row\n";
        assert_eq!(parse_agy(text), vec![choice("gemini-3.8-flash-high", "Gemini 3.8 Flash (High)"), choice("claude-opus-4-6-thinking", "Claude Opus 4.6 (Thinking)")]);
    }

    #[test]
    fn reads_what_codex_lists() {
        let text = r#"{"models":[{"slug":"b","display_name":"B","visibility":"list","priority":2},{"slug":"hidden","display_name":"H","visibility":"hide","priority":1},{"slug":"a","display_name":"A","visibility":"list","priority":1}]}"#;
        assert_eq!(parse_codex(text), vec![choice("a", "A"), choice("b", "B")]);
        assert!(parse_codex("not json").is_empty());
    }
}
