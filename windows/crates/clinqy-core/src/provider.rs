//! Which model service answers: a coding CLI the user is already logged into (Claude Code by default, Antigravity
//! `agy`, Codex) or a provider's HTTP API with their own key. Same settings and defaults as the Mac app.

use crate::config;
use std::path::{Path, PathBuf};
#[cfg(windows)]
use std::os::windows::process::CommandExt;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Provider {
    ClaudeCli,
    AgyCli,
    CodexCli,
    OpenCodeCli,
    CursorCli,
    Anthropic,
    OpenAi,
    Gemini,
    OpenRouter,
    Ollama,
    Compatible,
}

/// How to start a CLI: the program plus arguments that come before ours (an npm shim runs `node cli.js`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CliCommand {
    pub program: PathBuf,
    pub prefix: Vec<String>,
}

impl Provider {
    pub const ALL: [Provider; 11] = [
        Provider::ClaudeCli,
        Provider::AgyCli,
        Provider::CodexCli,
        Provider::OpenCodeCli,
        Provider::CursorCli,
        Provider::Anthropic,
        Provider::OpenAi,
        Provider::Gemini,
        Provider::OpenRouter,
        Provider::Ollama,
        Provider::Compatible,
    ];

    pub fn id(self) -> &'static str {
        match self {
            Provider::ClaudeCli => "claude-cli",
            Provider::AgyCli => "agy-cli",
            Provider::CodexCli => "codex-cli",
            Provider::OpenCodeCli => "opencode-cli",
            Provider::CursorCli => "cursor-cli",
            Provider::Anthropic => "anthropic",
            Provider::OpenAi => "openai",
            Provider::Gemini => "gemini",
            Provider::OpenRouter => "openrouter",
            Provider::Ollama => "ollama",
            Provider::Compatible => "openai-compatible",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Provider::ClaudeCli => "Claude Code",
            Provider::AgyCli => "Antigravity CLI",
            Provider::CodexCli => "Codex CLI",
            Provider::OpenCodeCli => "OpenCode",
            Provider::CursorCli => "Cursor Agent",
            Provider::Anthropic => "Anthropic API",
            Provider::OpenAi => "OpenAI API",
            Provider::Gemini => "Google Gemini",
            Provider::OpenRouter => "OpenRouter",
            Provider::Ollama => "Ollama",
            Provider::Compatible => "OpenAI-compatible API",
        }
    }

    pub fn is_configured(self) -> bool {
        match self {
            Provider::ClaudeCli => self.cli().is_some() && claude_logged_in(),
            Provider::CodexCli => self.cli().is_some() && codex_logged_in(self),
            Provider::AgyCli => self.cli().is_some(),
            Provider::OpenCodeCli => self.cli().is_some() && (config::value("OPENCODE_API_KEY").is_some() || open_code_auth_exists()),
            // Cursor's status subcommand is currently unstable on some CLI builds. A clear signed-out response
            // hides it; an unavailable status check leaves the installed CLI selectable and ACP verifies auth.
            Provider::CursorCli => self.cli().is_some() && cursor_auth_status(self) != CursorAuthStatus::SignedOut,
            Provider::Anthropic | Provider::OpenAi | Provider::Gemini | Provider::OpenRouter => self.key().is_some(),
            Provider::Ollama => reachable(&self.base_url()),
            Provider::Compatible => config::value("OPENAI_BASE_URL").is_some(),
        }
    }

    pub fn managed_by_environment() -> bool {
        ["PROVIDER", "USE_AGY"].iter().any(|key| std::env::var_os(key).is_some())
            || std::env::args().any(|arg| ["--agy", "--agy-cli", "--claude", "--claude-cli", "--codex", "--codex-cli", "--opencode", "--opencode-cli", "--cursor", "--cursor-cli"].contains(&arg.as_str()))
    }

    /// Parses a PROVIDER value (and the aliases the Mac app accepts).
    pub fn parse(raw: &str) -> Option<Provider> {
        Some(match raw.trim().to_lowercase().as_str() {
            "agy" | "agy-cli" | "antigravity" | "gemini-cli" => Provider::AgyCli,
            "claude" | "claude-code" | "cli" | "claude-cli" => Provider::ClaudeCli,
            "codex" | "codex-cli" => Provider::CodexCli,
            "opencode" | "open-code" | "opencode-cli" => Provider::OpenCodeCli,
            "cursor" | "cursor-agent" | "cursor-cli" => Provider::CursorCli,
            "anthropic" => Provider::Anthropic,
            "openai" | "gpt" | "chatgpt" => Provider::OpenAi,
            "gemini" | "google" => Provider::Gemini,
            "openrouter" => Provider::OpenRouter,
            "ollama" => Provider::Ollama,
            "openai-compatible" | "compatible" | "custom" => Provider::Compatible,
            _ => return None,
        })
    }

    fn flag_provider() -> Option<Provider> {
        let args: Vec<String> = std::env::args().collect();
        if args.iter().any(|a| ["--agy", "--agy-cli"].contains(&a.as_str())) {
            Some(Provider::AgyCli)
        } else if args.iter().any(|a| ["--claude", "--claude-cli"].contains(&a.as_str())) {
            Some(Provider::ClaudeCli)
        } else if args.iter().any(|a| ["--codex", "--codex-cli"].contains(&a.as_str())) {
            Some(Provider::CodexCli)
        } else if args.iter().any(|a| ["--opencode", "--opencode-cli"].contains(&a.as_str())) {
            Some(Provider::OpenCodeCli)
        } else if args.iter().any(|a| ["--cursor", "--cursor-cli"].contains(&a.as_str())) {
            Some(Provider::CursorCli)
        } else {
            None
        }
    }

    /// The provider in use: a flag, PROVIDER / USE_AGY, else whatever is on this PC, in this order: Claude Code
    /// (logged in), Codex, agy, a running Ollama, an API key, then any CLI at all.
    pub fn current() -> Provider {
        if let Some(provider) = Self::flag_provider() {
            return provider;
        }
        if config::on("USE_AGY", false) {
            return Provider::AgyCli;
        }
        if let Some(p) = config::value("PROVIDER").and_then(|v| Provider::parse(&v)) {
            return p;
        }
        Self::detected()
    }

    /// What `current` picks when nothing is set, following the user's configured priority order.
    pub fn detected() -> Provider {
        let order = config::value("PROVIDER_ORDER").unwrap_or_else(|| "claude-cli,codex-cli,agy-cli,opencode-cli,cursor-cli,ollama,anthropic,openai,gemini,openrouter,openai-compatible".into());
        order.split(',').filter_map(Provider::parse).find(|p| p.is_configured()).unwrap_or(Provider::ClaudeCli)
    }

    pub fn is_cli(self) -> bool {
        matches!(self, Provider::ClaudeCli | Provider::AgyCli | Provider::CodexCli | Provider::OpenCodeCli | Provider::CursorCli)
    }

    /// The API key for HTTP providers.
    pub fn key(self) -> Option<String> {
        let names: &[&str] = match self {
            Provider::Anthropic => &["ANTHROPIC_API_KEY"],
            Provider::OpenAi => &["OPENAI_API_KEY"],
            Provider::Gemini => &["GEMINI_API_KEY", "GOOGLE_API_KEY"],
            Provider::OpenRouter => &["OPENROUTER_API_KEY"],
            Provider::Compatible => &["OPENAI_COMPATIBLE_API_KEY", "OPENAI_API_KEY"],
            _ => return None,
        };
        names.iter().find_map(|n| config::value(n))
    }

    /// The model id for one of the app's tier names ("haiku" fast helper, "sonnet" agent, "opus"); anything else is
    /// passed through as the provider's own id.
    pub fn model(self, name: &str) -> String {
        let alias = name.to_lowercase();
        let tier = match alias.as_str() {
            "haiku" => 0,
            "sonnet" => 1,
            "opus" => 2,
            _ => return name.to_string(),
        };
        let pick = |a: [&str; 3]| a[tier].to_string();
        match self {
            Provider::AgyCli => pick(["gemini-3.8-flash", "gemini-3.8-flash", "gemini-3.1-pro"]),
            Provider::ClaudeCli => {
                if alias == "haiku" {
                    "claude-haiku-5-5".into()
                } else {
                    name.to_string()
                }
            }
            Provider::CodexCli => String::new(),
            Provider::OpenCodeCli => config::value("OPENCODE_MODEL").unwrap_or_default(),
            Provider::CursorCli => config::value("CURSOR_MODEL").unwrap_or_default(),
            Provider::Anthropic => pick(["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"]),
            Provider::OpenRouter => pick(["anthropic/claude-haiku-5.5", "anthropic/claude-sonnet-5.5", "anthropic/claude-opus-5.5"]),
            Provider::OpenAi => pick(["gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol"]),
            Provider::Gemini => pick(["gemini-3.5-flash-lite", "gemini-3.6-flash", "gemini-3.6-flash"]),
            Provider::Ollama | Provider::Compatible => config::value("LOCAL_MODEL").unwrap_or_else(|| "qwen3-vl".into()),
        }
    }

    /// The setting this provider's model is saved in: each has its own, so switching never sends one provider's
    /// model name to another. On this device only (the settings file isn't synced).
    pub fn model_key(self) -> &'static str {
        match self {
            Provider::ClaudeCli => "CLAUDE_MODEL",
            Provider::AgyCli => "AGY_MODEL",
            Provider::CodexCli => "CODEX_MODEL",
            Provider::OpenCodeCli => "OPENCODE_MODEL",
            Provider::CursorCli => "CURSOR_MODEL",
            Provider::Anthropic => "ANTHROPIC_MODEL",
            Provider::OpenAi => "OPENAI_MODEL",
            Provider::Gemini => "GEMINI_MODEL",
            Provider::OpenRouter => "OPENROUTER_MODEL",
            Provider::Ollama | Provider::Compatible => "LOCAL_MODEL",
        }
    }

    /// The agent's model name for this provider: its own setting, else a tier name left in the older shared settings
    /// (CLAUDE_MODEL, AGY_MODEL), else "sonnet".
    pub fn default_model(self) -> String {
        if let Some(own) = config::value(self.model_key()) {
            return own;
        }
        if matches!(self, Provider::OpenCodeCli | Provider::CursorCli) {
            return String::new();
        }
        // An Anthropic-format id still works on the providers that serve those models.
        if self == Provider::Anthropic {
            if let Some(m) = config::value("CLAUDE_MODEL") {
                return m;
            }
        }
        ["CLAUDE_MODEL", "AGY_MODEL"].iter().find_map(|k| config::value(k).filter(|m| ["haiku", "sonnet", "opus"].contains(&m.to_lowercase().as_str()))).unwrap_or_else(|| "sonnet".into())
    }

    pub fn base_url(self) -> String {
        let explicit = config::value("OPENAI_BASE_URL").map(|u| u.trim_end_matches('/').to_string());
        match self {
            Provider::OpenAi => explicit.unwrap_or_else(|| "https://api.openai.com/v1".into()),
            Provider::OpenRouter => "https://openrouter.ai/api/v1".into(),
            Provider::Ollama => explicit.unwrap_or_else(|| "http://localhost:11434/v1".into()),
            Provider::Compatible => explicit.unwrap_or_else(|| "http://localhost:1234/v1".into()),
            Provider::Anthropic => config::value("ANTHROPIC_BASE_URL").unwrap_or_else(|| "https://api.anthropic.com".into()),
            Provider::Gemini => "https://generativelanguage.googleapis.com/v1beta".into(),
            _ => String::new(),
        }
    }

    /// How to start this provider's CLI, if it's installed.
    pub fn cli(self) -> Option<CliCommand> {
        match self {
            Provider::ClaudeCli => find_cli("CLAUDE_PATH", "claude", &claude_spots(), "@anthropic-ai/claude-code/cli.js"),
            Provider::AgyCli => find_cli("AGY_PATH", "agy", &agy_spots(), ""),
            Provider::CodexCli => find_cli("CODEX_PATH", "codex", &[], "@openai/codex/bin/codex.js"),
            Provider::OpenCodeCli => find_cli("OPENCODE_PATH", "opencode", &opencode_spots(), "@opencode/cli/bin/opencode"),
            Provider::CursorCli => find_cli("CURSOR_AGENT_PATH", "agent", &cursor_spots(), "")
                .or_else(|| find_cli("CURSOR_AGENT_PATH", "cursor-agent", &cursor_spots(), "")),
            _ => None,
        }
    }

    /// One line for the status window: which service, and whether it's ready.
    pub fn label(self) -> String {
        let cli = |name: &str| match self.cli() {
            Some(c) => format!("{name}: {}", c.program.display()),
            None => format!("{name}: not found"),
        };
        match self {
            Provider::ClaudeCli => cli("Claude Code CLI"),
            Provider::AgyCli => cli("Antigravity CLI (agy)"),
            Provider::CodexCli => cli("Codex CLI"),
            Provider::OpenCodeCli => cli("OpenCode CLI"),
            Provider::CursorCli => cli("Cursor Agent CLI"),
            Provider::Ollama => format!("Ollama ({})", self.base_url()),
            Provider::Compatible => {
                format!("OpenAI-compatible API ({}{})", self.base_url(), if self.key().is_none() { ", no key" } else { "" })
            }
            _ => format!("{} API ({})", self.id(), if self.key().is_none() { "no key" } else { "key set" }),
        }
    }
}

/// Whether something listens at a URL's host and port (a local server is up).
pub fn reachable(url: &str) -> bool {
    use std::net::ToSocketAddrs;
    let rest = url.split("://").nth(1).unwrap_or(url);
    let host_port = rest.split('/').next().unwrap_or(rest);
    let addr = if host_port.contains(':') { host_port.to_string() } else { format!("{host_port}:80") };
    addr.to_socket_addrs()
        .ok()
        .and_then(|mut a| a.next())
        .map(|a| std::net::TcpStream::connect_timeout(&a, std::time::Duration::from_millis(300)).is_ok())
        .unwrap_or(false)
}

/// Ollama answering at its address (checked once a minute at most: it sits on the path of every request).
fn ollama_running() -> bool {
    static LAST: std::sync::Mutex<Option<(std::time::Instant, bool)>> = std::sync::Mutex::new(None);
    let mut last = LAST.lock().unwrap();
    if let Some((at, up)) = *last {
        if at.elapsed() < std::time::Duration::from_secs(60) {
            return up;
        }
    }
    let up = reachable(&Provider::Ollama.base_url());
    *last = Some((std::time::Instant::now(), up));
    up
}

fn claude_logged_in() -> bool {
    // Claude Code keeps its login in ~/.claude/.credentials.json on Windows (or uses an API key from the env).
    crate::paths::home().join(".claude").join(".credentials.json").exists() || std::env::var_os("ANTHROPIC_API_KEY").is_some()
}

fn local_app_data() -> PathBuf {
    std::env::var_os("LOCALAPPDATA").map(PathBuf::from).unwrap_or_else(|| crate::paths::home().join("AppData").join("Local"))
}

fn opencode_spots() -> Vec<PathBuf> {
    let home = crate::paths::home();
    vec![
        home.join(".opencode").join("bin").join("opencode.exe"),
        home.join(".local").join("bin").join("opencode.exe"),
        local_app_data().join("Programs").join("OpenCode").join("opencode.exe"),
    ]
}

fn cursor_spots() -> Vec<PathBuf> {
    let home = crate::paths::home();
    vec![
        local_app_data().join("cursor").join("bin").join("agent.exe"),
        home.join(".cursor").join("bin").join("agent.exe"),
        home.join(".local").join("bin").join("agent.exe"),
    ]
}

fn open_code_auth_exists() -> bool {
    let home = crate::paths::home();
    let data_home = config::value("XDG_DATA_HOME").map(PathBuf::from).unwrap_or_else(|| home.join(".local").join("share"));
    let data = data_home.join("opencode");
    let auth_files = vec![data.join("auth.json"), home.join(".opencode").join("auth.json")];
    let mut databases = vec![data.join("opencode.db")];
    if let Some(database) = config::value("OPENCODE_DB") {
        let database = database.strip_prefix("~/").map(|rest| home.join(rest)).unwrap_or_else(|| PathBuf::from(&database));
        databases.push(database);
    }
    if let Some(appdata) = std::env::var_os("APPDATA") {
        let data = PathBuf::from(appdata).join("opencode");
        if open_code_auth_file_has_credentials(&data.join("auth.json")) { return true; }
        databases.push(data.join("opencode.db"));
    }
    let local_data = local_app_data().join("opencode");
    if open_code_auth_file_has_credentials(&local_data.join("auth.json")) { return true; }
    databases.push(local_data.join("opencode.db"));
    auth_files.iter().any(|path| open_code_auth_file_has_credentials(path))
        || databases.iter().any(|path| open_code_database_has_credentials(path))
}

/// OpenCode creates its SQLite database for sessions even before anyone logs in. Inspect only whether a
/// credential row exists; never read or log credential contents.
fn open_code_database_has_credentials(path: &Path) -> bool {
    use rusqlite::{Connection, OpenFlags};
    let Ok(connection) = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY) else { return false };
    let _ = connection.busy_timeout(std::time::Duration::from_millis(250));
    // OpenCode shares this table with OAuth-backed MCP services. Only model-provider integrations count here;
    // MCP integration IDs use the `mcp_` prefix. The separate `auth` table can represent non-model accounts.
    connection.query_row(
        "SELECT 1 FROM credential WHERE integration_id IS NOT NULL AND substr(integration_id, 1, 4) != 'mcp_' LIMIT 1",
        [],
        |_| Ok(()),
    ).is_ok()
}

/// OpenCode v1 and migration-era installs keep provider credentials in auth.json.
fn open_code_auth_file_has_credentials(path: &Path) -> bool {
    let Ok(data) = std::fs::read(path) else { return false };
    let Ok(root) = serde_json::from_slice::<serde_json::Value>(&data) else { return false };
    let Some(records) = root.as_object() else { return false };
    records.values().any(|record| {
        let Some(object) = record.as_object() else { return false };
        match object.get("type").and_then(|value| value.as_str()).unwrap_or("").to_lowercase().as_str() {
            "api" => ["key"].into_iter().any(|key| object.get(key).and_then(|v| v.as_str()).is_some_and(|v| !v.is_empty())),
            "oauth" => ["access", "refresh"].into_iter().any(|key| object.get(key).and_then(|v| v.as_str()).is_some_and(|v| !v.is_empty())),
            "wellknown" => ["key", "token"].into_iter().any(|key| object.get(key).and_then(|v| v.as_str()).is_some_and(|v| !v.is_empty())),
            _ => false,
        }
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CursorAuthStatus { SignedIn, SignedOut, Unknown }

/// Check Codex's supported non-interactive login status command without retaining or logging its output.
fn codex_logged_in(provider: Provider) -> bool {
    static LAST: std::sync::Mutex<Option<(std::time::Instant, bool)>> = std::sync::Mutex::new(None);
    let mut last = LAST.lock().unwrap();
    if let Some((at, ready)) = *last {
        if at.elapsed() < std::time::Duration::from_secs(60) { return ready; }
    }
    let ready = run_cli_status(provider, &["login", "status"])
        .is_some_and(|output| codex_chatgpt_login_status(output.status.success(), &output.stdout, &output.stderr));
    *last = Some((std::time::Instant::now(), ready));
    ready
}

fn codex_chatgpt_login_status(success: bool, stdout: &[u8], stderr: &[u8]) -> bool {
    let text = format!("{}\n{}", String::from_utf8_lossy(stdout), String::from_utf8_lossy(stderr)).to_lowercase();
    success && text.contains("logged in using chatgpt")
}

/// Cursor supports both an existing browser login and API-key auth. Its installed binary owns the credential store;
/// only parse the documented status command and never retain its account details.
fn cursor_auth_status(provider: Provider) -> CursorAuthStatus {
    if ["CURSOR_API_KEY", "CURSOR_AUTH_TOKEN"].iter().any(|key| std::env::var(key).is_ok_and(|value| !value.trim().is_empty())) {
        return CursorAuthStatus::SignedIn;
    }
    static LAST: std::sync::Mutex<Option<(std::time::Instant, CursorAuthStatus)>> = std::sync::Mutex::new(None);
    let mut last = LAST.lock().unwrap();
    if let Some((at, status)) = *last {
        if at.elapsed() < std::time::Duration::from_secs(60) { return status; }
    }
    let status = run_cli_status(provider, &["status"])
        .map(|output| cursor_status_from_output(output.status.success(), &output.stdout, &output.stderr))
        .unwrap_or(CursorAuthStatus::Unknown);
    *last = Some((std::time::Instant::now(), status));
    status
}

fn cursor_status_from_output(success: bool, stdout: &[u8], stderr: &[u8]) -> CursorAuthStatus {
    if let Ok(value) = serde_json::from_slice::<serde_json::Value>(stdout) {
        if let Some(authenticated) = authentication_flag(&value) {
            return if authenticated && success { CursorAuthStatus::SignedIn } else { CursorAuthStatus::SignedOut };
        }
    }
    let text = format!("{}\n{}", String::from_utf8_lossy(stdout), String::from_utf8_lossy(stderr)).to_lowercase();
    if text.contains("not authenticated") || text.contains("unauthenticated") || text.contains("not logged in") || text.contains("not signed in") {
        CursorAuthStatus::SignedOut
    } else if success && (text.contains("authenticated") || text.contains("logged in") || text.contains("signed in")) {
        CursorAuthStatus::SignedIn
    } else {
        CursorAuthStatus::Unknown
    }
}

/// Run a small provider status command with a hard timeout; CLI crashes and unsupported status subcommands are
/// represented as `None`, so Cursor can still be attempted over ACP.
fn run_cli_status(provider: Provider, args: &[&str]) -> Option<std::process::Output> {
    let cli = provider.cli()?;
    let mut command = std::process::Command::new(cli.program);
    command.args(cli.prefix).args(args)
        .stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::piped());
    #[cfg(windows)]
    command.creation_flags(crate::session::CREATE_NO_WINDOW);
    let mut child = command.spawn().ok()?;
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
    loop {
        match child.try_wait() {
            Ok(Some(_)) => return child.wait_with_output().ok(),
            Ok(None) if std::time::Instant::now() < deadline => std::thread::sleep(std::time::Duration::from_millis(20)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
}

fn authentication_flag(value: &serde_json::Value) -> Option<bool> {
    match value {
        serde_json::Value::Object(map) => {
            for (key, value) in map {
                if ["authenticated", "isauthenticated", "loggedin", "signedin"].contains(&key.to_lowercase().replace('_', "").as_str()) {
                    if let Some(flag) = value.as_bool() { return Some(flag); }
                }
                if let Some(flag) = authentication_flag(value) { return Some(flag); }
            }
            None
        }
        serde_json::Value::Array(values) => values.iter().find_map(authentication_flag),
        _ => None,
    }
}

fn claude_spots() -> Vec<PathBuf> {
    let home = crate::paths::home();
    let mut spots = vec![home.join(".local").join("bin").join("claude.exe"), home.join(".claude").join("local").join("claude.exe")];
    // `winget install Anthropic.ClaudeCode` puts it in a versioned package folder.
    if let Ok(dir) = std::fs::read_dir(local_app_data().join("Microsoft").join("WinGet").join("Packages")) {
        for entry in dir.flatten() {
            if entry.file_name().to_string_lossy().starts_with("Anthropic.ClaudeCode") {
                spots.push(entry.path().join("claude.exe"));
            }
        }
    }
    spots
}

fn agy_spots() -> Vec<PathBuf> {
    let home = crate::paths::home();
    vec![local_app_data().join("agy").join("bin").join("agy.exe"), home.join(".local").join("bin").join("agy.exe")]
}

/// Finds a CLI: an explicit path setting, a real .exe on PATH or in the usual install spots, or an npm shim
/// (`name.cmd`), which is run as `node <script>` so long arguments don't go through cmd.exe's 8 KB limit.
pub fn find_cli(setting: &str, name: &str, spots: &[PathBuf], npm_script: &str) -> Option<CliCommand> {
    let plain = |p: PathBuf| CliCommand { program: p, prefix: vec![] };
    if let Some(explicit) = config::value(setting) {
        let p = PathBuf::from(&explicit);
        if p.extension().map(|e| e.eq_ignore_ascii_case("cmd")).unwrap_or(false) {
            if let Some(c) = npm_shim(&p, npm_script) {
                return Some(c);
            }
        }
        return Some(plain(p));
    }
    let path_dirs: Vec<PathBuf> = std::env::var_os("PATH").map(|p| std::env::split_paths(&p).collect()).unwrap_or_default();
    for dir in &path_dirs {
        let exe = dir.join(format!("{name}.exe"));
        if exe.is_file() {
            return Some(plain(exe));
        }
    }
    if let Some(p) = spots.iter().find(|p| p.is_file()) {
        return Some(plain(p.clone()));
    }
    let mut shim_dirs = path_dirs.clone();
    if let Some(appdata) = std::env::var_os("APPDATA") {
        shim_dirs.push(PathBuf::from(appdata).join("npm"));
    }
    for dir in &shim_dirs {
        let shim = dir.join(format!("{name}.cmd"));
        if shim.is_file() {
            if let Some(c) = npm_shim(&shim, npm_script) {
                return Some(c);
            }
            return Some(plain(shim));
        }
    }
    None
}

/// An npm `.cmd` shim as `node <package script>`.
fn npm_shim(shim: &Path, script: &str) -> Option<CliCommand> {
    if script.is_empty() {
        return None;
    }
    let dir = shim.parent()?;
    let js = dir.join("node_modules").join(script.replace('/', "\\"));
    if !js.is_file() {
        return None;
    }
    let node = [dir.join("node.exe")]
        .into_iter()
        .find(|p| p.is_file())
        .or_else(|| std::env::var_os("PATH").and_then(|p| std::env::split_paths(&p).map(|d| d.join("node.exe")).find(|p| p.is_file())))?;
    Some(CliCommand { program: node, prefix: vec![js.display().to_string()] })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_aliases() {
        assert_eq!(Provider::parse("agy"), Some(Provider::AgyCli));
        assert_eq!(Provider::parse("Claude-Code"), Some(Provider::ClaudeCli));
        assert_eq!(Provider::parse("codex"), Some(Provider::CodexCli));
        assert_eq!(Provider::parse("chatgpt"), Some(Provider::OpenAi));
        assert_eq!(Provider::parse("gpt"), Some(Provider::OpenAi));
        assert_eq!(Provider::parse("openai"), Some(Provider::OpenAi));
        assert_eq!(Provider::parse("open-code"), Some(Provider::OpenCodeCli));
        assert_eq!(Provider::parse("cursor"), Some(Provider::CursorCli));
        assert_eq!(Provider::parse("cursor-agent"), Some(Provider::CursorCli));
        assert_eq!(Provider::parse("custom"), Some(Provider::Compatible));
        assert_eq!(Provider::parse("nope"), None);
        assert_eq!(Provider::ALL.len(), 11);
        assert!(Provider::OpenCodeCli.is_cli() && Provider::CursorCli.is_cli());
    }

    #[test]
    fn tiers() {
        assert_eq!(Provider::Anthropic.model("opus"), "claude-opus-5-5");
        assert_eq!(Provider::ClaudeCli.model("sonnet"), "sonnet");
        assert_eq!(Provider::OpenAi.model("my-model"), "my-model");
    }

    #[test]
    fn opencode_database_requires_a_model_provider_credential() {
        let dir = std::env::temp_dir().join(format!("clinqy-opencode-auth-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("opencode.db");
        let connection = rusqlite::Connection::open(&path).unwrap();
        connection.execute("CREATE TABLE credential (id TEXT PRIMARY KEY, integration_id TEXT)", []).unwrap();
        drop(connection);

        assert!(!open_code_database_has_credentials(&path));
        let connection = rusqlite::Connection::open(&path).unwrap();
        connection.execute("INSERT INTO credential (id, integration_id) VALUES ('mcp-test-credential', 'mcp_0123456789abcdef')", []).unwrap();
        drop(connection);
        assert!(!open_code_database_has_credentials(&path));
        let connection = rusqlite::Connection::open(&path).unwrap();
        connection.execute("INSERT INTO credential (id, integration_id) VALUES ('fake-test-credential', 'anthropic')", []).unwrap();
        drop(connection);
        assert!(open_code_database_has_credentials(&path));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn opencode_auth_json_requires_a_nonempty_credential() {
        let dir = std::env::temp_dir().join(format!("clinqy-opencode-auth-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("auth.json");
        std::fs::write(&path, r#"{"openai":{"type":"api","key":""}}"#).unwrap();
        assert!(!open_code_auth_file_has_credentials(&path));
        std::fs::write(&path, r#"{"openai":{"type":"api","key":"fake-test-credential"}}"#).unwrap();
        assert!(open_code_auth_file_has_credentials(&path));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn cursor_status_distinguishes_authenticated_signed_out_and_unavailable() {
        assert_eq!(cursor_status_from_output(true, br#"{"authenticated":true}"#, b""), CursorAuthStatus::SignedIn);
        assert_eq!(cursor_status_from_output(true, br#"{"authenticated":false}"#, b""), CursorAuthStatus::SignedOut);
        assert_eq!(cursor_status_from_output(false, b"Not authenticated", b""), CursorAuthStatus::SignedOut);
        assert_eq!(cursor_status_from_output(false, b"", b""), CursorAuthStatus::Unknown);
    }

    #[test]
    fn codex_provider_requires_the_chatgpt_login_not_an_api_key_login() {
        assert!(codex_chatgpt_login_status(true, b"", b"Logged in using ChatGPT"));
        assert!(!codex_chatgpt_login_status(true, b"", b"API key configured"));
        assert!(!codex_chatgpt_login_status(false, b"", b"Logged in using ChatGPT"));
    }
}
