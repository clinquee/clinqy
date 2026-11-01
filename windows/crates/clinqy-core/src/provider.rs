//! Which model service answers: a coding CLI the user is already logged into (Claude Code by default, Antigravity
//! `agy`, Codex) or a provider's HTTP API with their own key. Same settings and defaults as the Mac app.

use crate::config;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Provider {
    ClaudeCli,
    AgyCli,
    CodexCli,
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
    pub const ALL: [Provider; 9] = [
        Provider::ClaudeCli,
        Provider::AgyCli,
        Provider::CodexCli,
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
            Provider::CodexCli => self.cli().is_some() && crate::paths::home().join(".codex").join("auth.json").exists(),
            Provider::AgyCli => self.cli().is_some(),
            Provider::Anthropic | Provider::OpenAi | Provider::Gemini | Provider::OpenRouter => self.key().is_some(),
            Provider::Ollama => reachable(&self.base_url()),
            Provider::Compatible => config::value("OPENAI_BASE_URL").is_some(),
        }
    }

    pub fn managed_by_environment() -> bool {
        ["PROVIDER", "USE_AGY"].iter().any(|key| std::env::var_os(key).is_some())
            || std::env::args().any(|arg| ["--agy", "--agy-cli", "--claude", "--claude-cli"].contains(&arg.as_str()))
    }

    /// Parses a PROVIDER value (and the aliases the Mac app accepts).
    pub fn parse(raw: &str) -> Option<Provider> {
        Some(match raw.trim().to_lowercase().as_str() {
            "agy" | "agy-cli" | "antigravity" | "gemini-cli" => Provider::AgyCli,
            "claude" | "claude-code" | "cli" | "claude-cli" => Provider::ClaudeCli,
            "codex" | "codex-cli" => Provider::CodexCli,
            "anthropic" => Provider::Anthropic,
            "openai" | "gpt" | "chatgpt" => Provider::OpenAi,
            "gemini" | "google" => Provider::Gemini,
            "openrouter" => Provider::OpenRouter,
            "ollama" => Provider::Ollama,
            "openai-compatible" | "compatible" | "custom" => Provider::Compatible,
            _ => return None,
        })
    }

    fn flag_says_agy() -> Option<bool> {
        let args: Vec<String> = std::env::args().collect();
        if args.iter().any(|a| a == "--agy" || a == "--agy-cli") {
            return Some(true);
        }
        if args.iter().any(|a| a == "--claude" || a == "--claude-cli") {
            return Some(false);
        }
        None
    }

    /// The provider in use: a flag, PROVIDER / USE_AGY, else whatever is on this PC, in this order: Claude Code
    /// (logged in), Codex, agy, a running Ollama, an API key, then any CLI at all.
    pub fn current() -> Provider {
        if let Some(agy) = Self::flag_says_agy() {
            return if agy { Provider::AgyCli } else { Provider::ClaudeCli };
        }
        if config::on("USE_AGY", false) {
            return Provider::AgyCli;
        }
        if let Some(p) = config::value("PROVIDER").and_then(|v| Provider::parse(&v)) {
            return p;
        }
        Self::detected()
    }

    /// What `current` picks when nothing is set.
    pub fn detected() -> Provider {
        if Provider::ClaudeCli.cli().is_some() && claude_logged_in() {
            return Provider::ClaudeCli;
        }
        if let Some(p) = [Provider::CodexCli, Provider::AgyCli].into_iter().find(|p| p.cli().is_some()) {
            return p;
        }
        if ollama_running() {
            return Provider::Ollama;
        }
        [Provider::Anthropic, Provider::OpenAi, Provider::Gemini, Provider::OpenRouter]
            .into_iter()
            .find(|p| p.key().is_some())
            .unwrap_or(Provider::ClaudeCli)
    }

    pub fn is_cli(self) -> bool {
        matches!(self, Provider::ClaudeCli | Provider::AgyCli | Provider::CodexCli)
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
        assert_eq!(Provider::parse("custom"), Some(Provider::Compatible));
        assert_eq!(Provider::parse("nope"), None);
    }

    #[test]
    fn tiers() {
        assert_eq!(Provider::Anthropic.model("opus"), "claude-opus-5-5");
        assert_eq!(Provider::ClaudeCli.model("sonnet"), "sonnet");
        assert_eq!(Provider::OpenAi.model("my-model"), "my-model");
    }
}
