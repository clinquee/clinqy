//! One conversation with the model for one task. For the Claude and agy CLIs it's a long-lived process speaking
//! stream-json (each turn then costs only model time, and the whole exchange stays in context); for HTTP APIs the
//! turns are kept here and replayed; Codex runs once per turn. Started ahead of time by `Brain` so a request never
//! waits for process startup.

use crate::config;
use crate::acp::AcpSession;
use crate::provider::{CliCommand, Provider};
use anyhow::{anyhow, bail, Result};
use parking_lot::Mutex;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::{mpsc, oneshot};

/// No console window flashes up when the tray app starts a console CLI.
pub const CREATE_NO_WINDOW: u32 = 0x0800_0000;

pub struct Session {
    pub provider: Provider,
    model: String,
    kind: Kind,
}

enum Kind {
    Cli(Arc<CliSession>),
    Acp(Arc<AcpSession>),
    Api(Arc<ApiChat>),
}

impl Session {
    pub fn start(system: &str, model: &str, provider: Provider) -> Result<Session> {
        let kind = match provider {
            Provider::ClaudeCli | Provider::AgyCli => Kind::Cli(CliSession::start(system, model, provider)?),
            Provider::OpenCodeCli | Provider::CursorCli => Kind::Acp(AcpSession::start(provider, system, model)?),
            _ => Kind::Api(Arc::new(ApiChat::new(provider, system, model)?)),
        };
        Ok(Session { provider, model: provider.model(model), kind })
    }

    pub fn is_alive(&self) -> bool {
        match &self.kind {
            Kind::Cli(c) => c.is_alive(),
            Kind::Acp(a) => a.is_alive(),
            Kind::Api(a) => !*a.closed.lock(),
        }
    }

    /// Sends one user turn (text plus an optional base64 JPEG) and returns the reply. `partial` sees the reply text so
    /// far each time it grows (streaming CLIs only).
    pub async fn send(&self, text: &str, image: Option<String>, partial: Option<mpsc::UnboundedSender<String>>) -> Result<String> {
        match &self.kind {
            Kind::Cli(c) => {
                let reply = c.send(text, image, partial).await?;
                crate::usage::record(self.provider.id(), &self.model, None, None);
                Ok(reply)
            }
            Kind::Acp(a) => {
                let reply = a.send(text, image, partial).await?;
                crate::usage::record(self.provider.id(), &self.model, None, None);
                Ok(reply)
            }
            Kind::Api(a) => a.clone().send(text, image, partial).await,
        }
    }

    pub fn close(&self) {
        match &self.kind {
            Kind::Cli(c) => c.close(),
            Kind::Acp(a) => a.close(),
            Kind::Api(a) => *a.closed.lock() = true,
        }
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        self.close();
    }
}

// MARK: - CLI (claude / agy, stream-json)

struct CliState {
    pending: Option<oneshot::Sender<Result<String>>>,
    partial: Option<mpsc::UnboundedSender<String>>,
    partial_text: String,
    dead: bool,
    last_error: Option<String>,
}

struct CliSession {
    provider: Provider,
    is_agy: bool,
    state: Mutex<CliState>,
    stdin: tokio::sync::Mutex<Option<tokio::process::ChildStdin>>,
    child: Mutex<Option<tokio::process::Child>>,
    dir: PathBuf,
    system: String,
    first_turn: Mutex<bool>,
}

fn cli_name(p: Provider) -> &'static str {
    if p == Provider::AgyCli {
        "Agy"
    } else {
        "Claude"
    }
}

fn not_installed(p: Provider) -> anyhow::Error {
    if p == Provider::AgyCli {
        anyhow!("Agy CLI not found. Install Antigravity (or set AGY_PATH), or add an API key to ~/.config/clinqy/env")
    } else {
        anyhow!("Claude CLI not found. Install Claude Code (winget install Anthropic.ClaudeCode, or set CLAUDE_PATH), or add an API key to ~/.config/clinqy/env")
    }
}

fn reported_usage(provider: Provider, json: &Value) -> (Option<u64>, Option<u64>) {
    let usage = &json["usage"];
    let metadata = &json["usageMetadata"];
    match provider {
        Provider::Anthropic => (usage["input_tokens"].as_u64(), usage["output_tokens"].as_u64()),
        Provider::Gemini => (metadata["promptTokenCount"].as_u64(), metadata["candidatesTokenCount"].as_u64()),
        _ => (usage["prompt_tokens"].as_u64(), usage["completion_tokens"].as_u64()),
    }
}

impl CliSession {
    fn start(system: &str, model: &str, provider: Provider) -> Result<Arc<CliSession>> {
        let CliCommand { program, prefix } = provider.cli().ok_or_else(|| not_installed(provider))?;
        let exe = program.file_stem().map(|s| s.to_string_lossy().to_lowercase()).unwrap_or_default();
        let is_agy = provider == Provider::AgyCli || exe == "agy";
        let dir = std::env::temp_dir().join(format!("clinqy-session-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir)?;
        let mut args: Vec<String> = prefix;
        if is_agy {
            // The rules go in the first turn. (Not in an AGENTS.md in the working folder: agy 1.2.17 answers every turn
            // with an error_message step when one is there, retrying until it gives up.)
            args.extend(
                [
                    "--sandbox",
                    "--input-format",
                    "stream-json",
                    "--output-format",
                    "stream-json",
                    "--disable-slash-commands",
                    "--dangerously-skip-permissions",
                ]
                .map(String::from),
            );
            let mut m = provider.model(model);
            let explicit = config::value("AGY_EFFORT").or_else(|| config::value("CLAUDE_EFFORT"));
            let suffix = ["-low", "-medium", "-high", "-xhigh", "-max"].into_iter().find(|s| m.ends_with(s));
            if let Some(suffix) = suffix {
                if let Some(e) = explicit.as_ref().map(|e| e.to_lowercase()) {
                    m.truncate(m.len() - suffix.len());
                    args.extend(["--effort".into(), e]);
                }
            } else if !m.contains("claude") {
                let default = if model.eq_ignore_ascii_case("opus") { "high" } else { "low" };
                args.extend(["--effort".into(), explicit.unwrap_or_else(|| default.into()).to_lowercase()]);
            }
            if !m.is_empty() && m != "default" {
                args.extend(["--model".into(), m]);
            }
        } else {
            // The prompt goes in a file: it's ~20 KB, and Windows command lines are capped.
            let prompt_file = dir.join("system.md");
            std::fs::write(&prompt_file, system)?;
            args.extend([
                "-p".into(),
                "--input-format".into(),
                "stream-json".into(),
                "--output-format".into(),
                "stream-json".into(),
                "--verbose".into(),
                "--model".into(),
                model.into(),
                "--effort".into(),
                config::value("CLAUDE_EFFORT").unwrap_or_else(|| "low".into()),
                "--tools".into(),
                "".into(),
                "--system-prompt-file".into(),
                prompt_file.display().to_string(),
                "--strict-mcp-config".into(),
                "--setting-sources".into(),
                "".into(),
                "--disable-slash-commands".into(),
                "--no-session-persistence".into(),
                "--include-partial-messages".into(),
            ]);
        }
        let mut cmd = tokio::process::Command::new(&program);
        cmd.args(&args).current_dir(&dir).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).kill_on_drop(true);
        #[cfg(windows)]
        cmd.creation_flags(CREATE_NO_WINDOW);
        let mut child = cmd.spawn().map_err(|e| anyhow!("couldn't start {}: {e}", program.display()))?;
        let stdin = child.stdin.take();
        let stdout = child.stdout.take().ok_or_else(|| anyhow!("no stdout"))?;
        let stderr = child.stderr.take().ok_or_else(|| anyhow!("no stderr"))?;
        let session = Arc::new(CliSession {
            provider,
            is_agy,
            state: Mutex::new(CliState { pending: None, partial: None, partial_text: String::new(), dead: false, last_error: None }),
            stdin: tokio::sync::Mutex::new(stdin),
            child: Mutex::new(Some(child)),
            dir,
            system: system.to_string(),
            first_turn: Mutex::new(true),
        });
        let s = session.clone();
        tokio::spawn(async move {
            let mut lines = BufReader::new(stderr).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                let t = line.trim();
                if !t.is_empty() {
                    s.state.lock().last_error = Some(t.to_string());
                }
            }
        });
        let s = session.clone();
        tokio::spawn(async move {
            let mut reader = BufReader::with_capacity(1 << 20, stdout);
            let mut line = String::new();
            loop {
                line.clear();
                match reader.read_line(&mut line).await {
                    Ok(0) | Err(_) => break,
                    Ok(_) => s.consume(line.trim_end()),
                }
            }
            s.fail(None);
        });
        Ok(session)
    }

    fn is_alive(&self) -> bool {
        !self.state.lock().dead
    }

    async fn send(&self, text: &str, image: Option<String>, partial: Option<mpsc::UnboundedSender<String>>) -> Result<String> {
        let payload = if self.is_agy {
            let mut prompt = text.to_string();
            {
                let mut first = self.first_turn.lock();
                if *first {
                    prompt = format!("<instructions>\n{}\n</instructions>\n\n{prompt}", self.system);
                    *first = false;
                }
            }
            if let Some(img) = image.as_ref() {
                use base64::Engine;
                if let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(img) {
                    let path = self.dir.join("screen.jpg");
                    if std::fs::write(&path, bytes).is_ok() {
                        prompt += &format!("\n(Screenshot saved at {}. You can view it with view_file if needed.)", path.display());
                    }
                }
            }
            json!({"event": "user", "message": {"role": "user", "content": [{"type": "text", "text": prompt}]}})
        } else {
            let mut content = vec![];
            if let Some(img) = image {
                content.push(json!({"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": img}}));
            }
            content.push(json!({"type": "text", "text": text}));
            json!({"type": "user", "message": {"role": "user", "content": content}})
        };
        let (tx, rx) = oneshot::channel();
        {
            let mut st = self.state.lock();
            if st.dead {
                return Err(self.death_error(&st));
            }
            if st.pending.is_some() {
                bail!("Still waiting on the previous reply");
            }
            st.pending = Some(tx);
            st.partial = partial;
            st.partial_text.clear();
        }
        let mut line = payload.to_string();
        line.push('\n');
        {
            let mut stdin = self.stdin.lock().await;
            let Some(w) = stdin.as_mut() else { bail!("The {} process stopped unexpectedly", cli_name(self.provider)) };
            if let Err(e) = w.write_all(line.as_bytes()).await {
                self.state.lock().pending = None;
                bail!("couldn't talk to the {} process: {e}", cli_name(self.provider));
            }
            let _ = w.flush().await;
        }
        rx.await.map_err(|_| anyhow!("The {} process stopped unexpectedly", cli_name(self.provider)))?
    }

    fn death_error(&self, st: &CliState) -> anyhow::Error {
        match &st.last_error {
            Some(msg) => {
                let lower = msg.to_lowercase();
                if lower.contains("not logged in") || lower.contains("oauth") || lower.contains("failed to authenticate") {
                    if self.provider == Provider::AgyCli {
                        anyhow!("Agy CLI isn't logged in. Run `agy` in a terminal once and log in.")
                    } else {
                        anyhow!("Claude CLI isn't logged in. Run `claude` in a terminal once and log in ({msg})")
                    }
                } else {
                    anyhow!("{msg}")
                }
            }
            None => anyhow!("The {} process stopped unexpectedly", cli_name(self.provider)),
        }
    }

    fn consume(&self, line: &str) {
        let Ok(event) = serde_json::from_str::<Value>(line) else { return };
        let mut st = self.state.lock();
        // agy: streaming text, then a result.
        if event["event"] == "step_update" {
            let step = &event["step_update"];
            if step["step_type"] == "agent_response" {
                if let Some(piece) = step["text_delta"].as_str() {
                    if st.pending.is_some() {
                        st.partial_text.push_str(piece);
                        let grown = st.partial_text.clone();
                        if let Some(p) = &st.partial {
                            let _ = p.send(grown);
                        }
                    }
                }
            }
            return;
        }
        // claude: streaming deltas.
        if event["type"] == "stream_event" {
            let delta = &event["event"]["delta"];
            if delta["type"] == "text_delta" {
                if let Some(piece) = delta["text"].as_str() {
                    if st.pending.is_some() {
                        st.partial_text.push_str(piece);
                        let grown = st.partial_text.clone();
                        if let Some(p) = &st.partial {
                            let _ = p.send(grown);
                        }
                    }
                }
            }
            return;
        }
        let result: Option<Result<String>> = if event["event"] == "result" {
            let res = &event["result"];
            let mut text = res["response"].as_str().unwrap_or("").to_string();
            if text.trim().is_empty() && !st.partial_text.trim().is_empty() {
                text = st.partial_text.clone();
            }
            let err = res["error"].as_str().filter(|e| !e.is_empty());
            if res["status"] == "ERROR" || err.is_some() {
                let msg = err.map(String::from).unwrap_or_else(|| if text.is_empty() { "Agy process error".into() } else { text });
                st.last_error = Some(msg.clone());
                Some(Err(anyhow!(msg)))
            } else {
                Some(Ok(text))
            }
        } else if event["type"] == "result" {
            let mut text = event["result"].as_str().unwrap_or("").to_string();
            // The final event can come back empty while the text arrived as deltas: use what streamed.
            if text.trim().is_empty() && !st.partial_text.trim().is_empty() {
                text = st.partial_text.clone();
            }
            if event["is_error"] == true {
                Some(Err(anyhow!(if text.is_empty() { "the model returned an error".to_string() } else { text })))
            } else {
                Some(Ok(text))
            }
        } else {
            None
        };
        if let Some(r) = result {
            st.partial = None;
            if let Some(p) = st.pending.take() {
                let _ = p.send(r);
            }
        }
    }

    fn fail(&self, why: Option<String>) {
        let mut st = self.state.lock();
        st.dead = true;
        if let Some(w) = why {
            st.last_error.get_or_insert(w);
        }
        let err = self.death_error(&st);
        st.partial = None;
        if let Some(p) = st.pending.take() {
            let _ = p.send(Err(err));
        }
    }

    fn close(&self) {
        if let Some(mut child) = self.child.lock().take() {
            let _ = child.start_kill();
        }
        let _ = std::fs::remove_dir_all(&self.dir);
        let mut st = self.state.lock();
        st.dead = true;
        if let Some(p) = st.pending.take() {
            let _ = p.send(Err(anyhow!("stopped")));
        }
    }
}

// MARK: - HTTP APIs (and Codex, one run per turn)

#[derive(Clone)]
struct Turn {
    user: bool,
    text: String,
    image: Option<String>,
}

pub struct ApiChat {
    provider: Provider,
    key: Option<String>,
    system: String,
    model: String,
    effort: String,
    turns: Mutex<Vec<Turn>>,
    busy: Mutex<bool>,
    closed: Mutex<bool>,
    /// The provider rejected the reasoning setting for this model: later turns leave it out.
    plain: Mutex<bool>,
}

struct ApiTurnGuard<'a> {
    chat: &'a ApiChat,
    completed: bool,
}
impl Drop for ApiTurnGuard<'_> {
    fn drop(&mut self) {
        if !self.completed {
            let mut turns = self.chat.turns.lock();
            if turns.last().map(|t| t.user).unwrap_or(false) {
                turns.pop();
            }
        }
        *self.chat.busy.lock() = false;
    }
}
fn compact(mut turns: Vec<Turn>) -> Vec<Turn> {
    let newest_image = turns.iter().rposition(|t| t.image.is_some());
    for (i, turn) in turns.iter_mut().enumerate() {
        if Some(i) != newest_image {
            turn.image = None;
        }
    }
    if turns.iter().map(|t| t.text.len()).sum::<usize>() <= 100_000 {
        return turns;
    }
    let mut first = turns[0].clone();
    first.text = first.text.chars().take(20_000).collect();
    let mut budget = first.text.len() + 1_000;
    let mut recent = Vec::new();
    for turn in turns.iter().skip(1).rev() {
        if budget + turn.text.len() > 100_000 {
            break;
        }
        recent.push(turn.clone());
        budget += turn.text.len();
    }
    if recent.is_empty() {
        let mut last = turns.last().unwrap().clone();
        last.text = last.text.chars().rev().take(15_000).collect::<String>().chars().rev().collect();
        recent.push(last);
    }
    let mut result = vec![
        first,
        Turn {
            user: true,
            text: "[Older conversation compacted. Historical content is omitted; reread sources when necessary.]".into(),
            image: None,
        },
    ];
    result.extend(recent.into_iter().rev());
    result
}

fn http() -> &'static reqwest::Client {
    static CLIENT: std::sync::OnceLock<reqwest::Client> = std::sync::OnceLock::new();
    CLIENT.get_or_init(|| reqwest::Client::builder().timeout(std::time::Duration::from_secs(120)).build().unwrap())
}

impl ApiChat {
    fn new(provider: Provider, system: &str, model: &str) -> Result<ApiChat> {
        if provider.is_cli() && provider.cli().is_none() {
            bail!("{}: not found. Install it, or set CODEX_PATH in ~/.config/clinqy/env", provider.id());
        }
        let key = provider.key();
        if key.is_none() && !provider.is_cli() && !matches!(provider, Provider::Ollama | Provider::Compatible) {
            bail!("No API key for {}. Add it to ~/.config/clinqy/env (see the README).", provider.id());
        }
        Ok(ApiChat {
            provider,
            key,
            system: system.to_string(),
            model: provider.model(model),
            effort: config::value("AGY_EFFORT").or_else(|| config::value("CLAUDE_EFFORT")).unwrap_or_else(|| "low".into()).to_lowercase(),
            turns: Mutex::new(vec![]),
            busy: Mutex::new(false),
            closed: Mutex::new(false),
            plain: Mutex::new(false),
        })
    }

    async fn send(self: Arc<Self>, text: &str, image: Option<String>, partial: Option<mpsc::UnboundedSender<String>>) -> Result<String> {
        {
            if *self.closed.lock() {
                bail!("stopped");
            }
            let mut busy = self.busy.lock();
            if *busy {
                bail!("Still waiting on the previous reply");
            }
            *busy = true;
            self.turns.lock().push(Turn { user: true, text: text.to_string(), image });
        }
        let mut guard = ApiTurnGuard { chat: &self, completed: false };
        let result = tokio::time::timeout(std::time::Duration::from_secs(120), self.complete(partial.as_ref()))
            .await
            .map_err(|_| anyhow!("Model request deadline exceeded"))
            .and_then(|r| r);
        guard.completed = true;
        *self.busy.lock() = false;
        let mut turns = self.turns.lock();
        match result {
            Ok(reply) => {
                turns.push(Turn { user: false, text: reply.clone(), image: None });
                Ok(reply)
            }
            Err(e) => {
                if turns.last().map(|t| t.user).unwrap_or(false) {
                    turns.pop();
                }
                Err(e)
            }
        }
    }

    async fn complete(&self, partial: Option<&mpsc::UnboundedSender<String>>) -> Result<String> {
        // Only the newest screenshot is sent again: older ones cost tokens every turn and are out of date anyway.
        let history: Vec<Turn> = {
            let turns = self.turns.lock();
            let last_image = turns.iter().rposition(|t| t.image.is_some());
            turns
                .iter()
                .enumerate()
                .map(|(i, t)| {
                    let mut t = t.clone();
                    if t.image.is_some() && Some(i) != last_image {
                        t.image = None;
                        t.text = format!("[earlier screenshot omitted]\n{}", t.text);
                    }
                    t
                })
                .collect()
        };
        let history = compact(history);
        *self.turns.lock() = history.clone();
        let plain = *self.plain.lock();
        match self.request(&history, plain, partial).await {
            Err(e) if !plain && e.to_string().starts_with("HTTP 400") && matches!(self.provider, Provider::OpenAi | Provider::Gemini) => {
                *self.plain.lock() = true;
                self.request(&history, true, partial).await
            }
            other => other,
        }
    }

    async fn request(&self, history: &[Turn], plain: bool, partial: Option<&mpsc::UnboundedSender<String>>) -> Result<String> {
        if self.provider == Provider::CodexCli {
            return self.run_codex(history).await;
        }
        let p = self.provider;
        let (url, body, headers): (String, Value, Vec<(&str, String)>) = match p {
            Provider::Anthropic => {
                let mut messages: Vec<Value> = history
                    .iter()
                    .map(|t| {
                        let mut content = vec![];
                        if let Some(img) = &t.image {
                            content.push(json!({"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": img}}));
                        }
                        content.push(json!({"type": "text", "text": t.text}));
                        json!({"role": if t.user {"user"} else {"assistant"}, "content": content})
                    })
                    .collect();
                // Cache the conversation so far: each turn then only pays for what's new.
                if let Some(last) = messages.last_mut() {
                    if let Some(arr) = last["content"].as_array_mut() {
                        if let Some(block) = arr.last_mut() {
                            block["cache_control"] = json!({"type": "ephemeral"});
                        }
                    }
                }
                (
                    format!("{}/v1/messages", p.base_url()),
                    json!({"model": self.model, "max_tokens": 8192, "messages": messages,
                           "system": [{"type": "text", "text": self.system, "cache_control": {"type": "ephemeral"}}]}),
                    vec![("x-api-key", self.key.clone().unwrap_or_default()), ("anthropic-version", "2023-06-01".into())],
                )
            }
            Provider::Gemini => {
                let contents: Vec<Value> = history
                    .iter()
                    .map(|t| {
                        let mut parts = vec![];
                        if let Some(img) = &t.image {
                            parts.push(json!({"inlineData": {"mimeType": "image/jpeg", "data": img}}));
                        }
                        parts.push(json!({"text": t.text}));
                        json!({"role": if t.user {"user"} else {"model"}, "parts": parts})
                    })
                    .collect();
                let mut generation = json!({"maxOutputTokens": 8192});
                if !plain {
                    generation["thinkingConfig"] =
                        json!({"thinkingLevel": if self.effort == "high" || self.effort == "max" {"high"} else {"low"}});
                }
                (
                    format!("{}/models/{}:generateContent", p.base_url(), self.model),
                    json!({"systemInstruction": {"parts": [{"text": self.system}]}, "contents": contents, "generationConfig": generation}),
                    vec![("x-goog-api-key", self.key.clone().unwrap_or_default())],
                )
            }
            _ => {
                let mut messages = vec![json!({"role": "system", "content": self.system})];
                for t in history {
                    if let Some(img) = &t.image {
                        messages.push(json!({"role": "user", "content": [
                            {"type": "image_url", "image_url": {"url": format!("data:image/jpeg;base64,{img}")}},
                            {"type": "text", "text": t.text}]}));
                    } else {
                        messages.push(json!({"role": if t.user {"user"} else {"assistant"}, "content": t.text}));
                    }
                }
                let mut body = json!({"model": self.model, "messages": messages});
                let reasoning = self.model.starts_with("gpt-5") || regex::Regex::new(r"^o\d").unwrap().is_match(&self.model);
                if !plain && p == Provider::OpenAi && reasoning {
                    let e = match self.effort.as_str() {
                        "min" | "minimal" | "none" => "minimal",
                        "max" => "high",
                        other => other,
                    };
                    body["reasoning_effort"] = json!(e);
                }
                let mut headers = vec![];
                if let Some(k) = &self.key {
                    headers.push(("Authorization", format!("Bearer {k}")));
                }
                if p == Provider::OpenRouter {
                    headers.push(("X-Title", "Clinqy".into()));
                }
                (format!("{}/chat/completions", p.base_url()), body, headers)
            }
        };
        let mut body = body;
        let url = if p == Provider::Gemini {
            url.replace(":generateContent", ":streamGenerateContent?alt=sse")
        } else {
            body["stream"] = json!(true);
            url
        };
        if p == Provider::OpenAi {
            body["stream_options"] = json!({"include_usage": true});
        }
        let mut req = http().post(&url).json(&body);
        for (k, v) in headers {
            req = req.header(k, v);
        }
        let mut resp = req.try_clone().ok_or_else(|| anyhow!("request cannot be retried"))?.send().await?;
        for attempt in 0..2 {
            if ![429, 503].contains(&resp.status().as_u16()) {
                break;
            }
            let retry = resp
                .headers()
                .get("retry-after")
                .and_then(|h| h.to_str().ok())
                .and_then(|h| h.parse::<f64>().ok())
                .unwrap_or((1 << attempt) as f64 + rand::random::<f64>() * 0.25)
                .clamp(0.2, 8.0);
            drop(resp);
            tokio::time::sleep(std::time::Duration::from_secs_f64(retry)).await;
            resp = req.try_clone().ok_or_else(|| anyhow!("request cannot be retried"))?.send().await?;
        }
        let status = resp.status().as_u16();
        let streamed = resp
            .headers()
            .get("content-type")
            .and_then(|v| v.to_str().ok())
            .map(|v| v.contains("event-stream") || v.contains("ndjson"))
            .unwrap_or(false);
        use futures_util::StreamExt;
        let mut chunks = resp.bytes_stream();
        if (200..300).contains(&status) && streamed {
            let mut stream = crate::model_stream::Stream::default();
            let mut delivered = std::time::Instant::now();
            while let Some(chunk) = chunks.next().await {
                if *self.closed.lock() {
                    bail!("stopped");
                }
                stream.push(&chunk?)?;
                if delivered.elapsed().as_millis() >= 20 {
                    if let Some(partial) = partial {
                        let _ = partial.send(stream.text.clone());
                    }
                    delivered = std::time::Instant::now();
                }
            }
            stream.finish()?;
            if let Some(partial) = partial {
                let _ = partial.send(stream.text.clone());
            }
            crate::usage::record(p.id(), &self.model, stream.input, stream.output);
            return Ok(stream.text);
        }
        let mut data = Vec::new();
        while let Some(chunk) = chunks.next().await {
            let chunk = chunk?;
            if data.len() + chunk.len() > 4_000_000 {
                bail!("Model response exceeded the response budget");
            }
            data.extend_from_slice(&chunk);
        }
        let text = String::from_utf8_lossy(&data);
        let json: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
        if !(200..300).contains(&status) {
            let message = json["error"]["message"]
                .as_str()
                .or_else(|| json["error"].as_str())
                .map(String::from)
                .unwrap_or_else(|| text.chars().take(300).collect());
            bail!("HTTP {status} from {}: {message}", p.id());
        }
        let reply: String = match p {
            Provider::Anthropic => {
                json["content"].as_array().map(|a| a.iter().filter_map(|b| b["text"].as_str()).collect()).unwrap_or_default()
            }
            Provider::Gemini => json["candidates"][0]["content"]["parts"]
                .as_array()
                .map(|a| a.iter().filter(|p| p["thought"] != true).filter_map(|p| p["text"].as_str()).collect())
                .unwrap_or_default(),
            _ => json["choices"][0]["message"]["content"].as_str().unwrap_or("").to_string(),
        };
        if reply.is_empty() {
            bail!("Empty reply from {} ({})", p.id(), self.model);
        }
        let (input, output) = reported_usage(p, &json);
        crate::usage::record(p.id(), &self.model, input, output);
        Ok(reply)
    }

    /// Codex has no long-lived chat mode: each turn runs it once with the transcript on stdin.
    async fn run_codex(&self, history: &[Turn]) -> Result<String> {
        let cli = self.provider.cli().ok_or_else(|| anyhow!("Codex CLI not found (npm i -g @openai/codex, or set CODEX_PATH)"))?;
        let dir = std::env::temp_dir().join(format!("clinqy-codex-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir)?;
        let _cleanup = DirGuard(dir.clone());
        let image_path = dir.join("screen.jpg");
        let has_image = history
            .last()
            .and_then(|t| t.image.as_ref())
            .and_then(|i| {
                use base64::Engine;
                base64::engine::general_purpose::STANDARD.decode(i).ok()
            })
            .map(|b| std::fs::write(&image_path, b).is_ok())
            .unwrap_or(false);
        let last = dir.join("last.txt");
        let mut transcript = format!("<instructions>\n{}\n</instructions>\n\n", self.system);
        for t in history {
            transcript +=
                &if t.user { format!("<user>\n{}\n</user>\n\n", t.text) } else { format!("<assistant>\n{}\n</assistant>\n\n", t.text) };
        }
        transcript +=
            "Write only the assistant's next reply to the last <user> turn, following <instructions>. Don't run commands or edit files.";
        let mut args = cli.prefix.clone();
        args.extend(
            ["exec", "--skip-git-repo-check", "--sandbox", "read-only", "--color", "never", "--output-last-message"].map(String::from),
        );
        args.push(last.display().to_string());
        if has_image {
            args.extend(["--image".into(), image_path.display().to_string()]);
        }
        if !self.model.is_empty() {
            args.extend(["--model".into(), self.model.clone()]);
        }
        args.push("-".into());
        let mut command = tokio::process::Command::new(&cli.program);
        command.args(&args).current_dir(&dir).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).kill_on_drop(true);
        #[cfg(windows)]
        command.creation_flags(CREATE_NO_WINDOW);
        let mut child = command.spawn()?;
        if let Some(mut stdin) = child.stdin.take() {
            stdin.write_all(transcript.as_bytes()).await?;
        }
        let out = child.wait_with_output().await?;
        if !out.status.success() {
            let err = String::from_utf8_lossy(&out.stderr);
            bail!("codex-cli exited {}: {}", out.status, err.chars().rev().take(400).collect::<String>().chars().rev().collect::<String>());
        }
        let reply = std::fs::read_to_string(&last).unwrap_or_else(|_| String::from_utf8_lossy(&out.stdout).into_owned());
        let reply = reply.trim().to_string();
        if reply.is_empty() {
            bail!("Empty reply from codex-cli");
        }
        crate::usage::record(self.provider.id(), &self.model, None, None);
        Ok(reply)
    }
}

struct DirGuard(PathBuf);
impl Drop for DirGuard {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Keeps one session started ahead of time so a request never waits for the CLI to boot.
pub struct Brain {
    warm: Mutex<Option<(Session, String)>>,
}

impl Default for Brain {
    fn default() -> Self {
        Self::new()
    }
}

impl Brain {
    pub const fn new() -> Brain {
        Brain { warm: Mutex::new(None) }
    }

    pub fn prewarm(&self, system: &str) {
        let provider = Provider::current();
        let model = provider.default_model();
        let mut warm = self.warm.lock();
        if let Some((s, m)) = warm.as_ref() {
            if s.is_alive() && s.provider == provider && *m == model {
                return;
            }
        }
        *warm = Session::start(system, &model, provider).ok().map(|s| (s, model));
    }

    /// The warm session (or a fresh one), and warming of the next starts shortly after.
    pub fn session(&self, system: &str, model: Option<&str>, provider: Option<Provider>) -> Result<Session> {
        let provider = provider.unwrap_or_else(Provider::current);
        let default = provider.default_model();
        let model = model.map(String::from).unwrap_or(default.clone());
        if model != default {
            return Session::start(system, &model, provider);
        }
        let taken = self.warm.lock().take();
        if let Some((s, m)) = taken {
            if s.is_alive() && s.provider == provider && m == model {
                return Ok(s);
            }
        }
        Session::start(system, &model, provider)
    }
}
