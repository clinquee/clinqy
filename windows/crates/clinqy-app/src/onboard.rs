//! Getting going: picking the model Clinqy uses (and checking it really answers), and connecting coding agents to
//! Clinqy over MCP. Used by `clinqy model`, `clinqy connect` and the tray's Model menu, so a person, a coding agent
//! following the setup prompt, and the tray all do it the same way.

use clinqy_core::provider::Provider;
use std::path::PathBuf;
use std::time::{Duration, Instant};

/// The choices, by the short names people type: (name, provider, what it is), in the order Clinqy picks them
/// when nothing is set.
pub const MODELS: [(&str, Provider, &str); 9] = [
    ("claude", Provider::ClaudeCli, "Claude Code CLI, your Claude login"),
    ("codex", Provider::CodexCli, "Codex CLI, your ChatGPT login"),
    ("agy", Provider::AgyCli, "Antigravity CLI, your Google login"),
    ("ollama", Provider::Ollama, "a local model with Ollama"),
    ("anthropic", Provider::Anthropic, "Anthropic API key"),
    ("openai", Provider::OpenAi, "OpenAI API key"),
    ("gemini", Provider::Gemini, "Gemini API key"),
    ("openrouter", Provider::OpenRouter, "OpenRouter API key"),
    ("compatible", Provider::Compatible, "any OpenAI-compatible server"),
];

pub fn short_name(p: Provider) -> &'static str {
    MODELS.iter().find(|m| m.1 == p).map(|m| m.0).unwrap_or("claude")
}

/// The model the provider really runs (the tier name "sonnet" becomes, for agy, its Gemini model).
pub fn model_label(p: Provider) -> String {
    let m = p.model(&p.default_model());
    if m.is_empty() { "default model".into() } else { m }
}

/// Whether a provider can be used as it is, and if not, exactly what to do.
pub fn readiness(p: Provider) -> Result<String, String> {
    let env = clinqy_core::paths::env_file().display().to_string();
    match p {
        Provider::ClaudeCli => match p.cli() {
            Some(c) => Ok(c.program.display().to_string()),
            None => Err("Claude Code isn't installed. Install it with `winget install Anthropic.ClaudeCode`, then run `claude` once in a new terminal to log in.".into()),
        },
        Provider::AgyCli => match p.cli() {
            Some(c) => Ok(c.program.display().to_string()),
            None => Err("The Antigravity CLI (agy) isn't installed. Install it from https://antigravity.google/docs/cli/overview, then run `agy` once in a new terminal to log in.".into()),
        },
        Provider::CodexCli => match p.cli() {
            Some(c) => Ok(c.program.display().to_string()),
            None => Err("The Codex CLI isn't installed. Install it with `npm i -g @openai/codex`, then run `codex login`.".into()),
        },
        Provider::Ollama => {
            if clinqy_core::provider::reachable(&p.base_url()) {
                Ok(format!("{} · model {}", p.base_url(), p.model("sonnet")))
            } else {
                Err(format!("Ollama isn't running at {}. Install it (winget install Ollama.Ollama), start it, and run `ollama pull {}`.", p.base_url(), p.model("sonnet")))
            }
        }
        Provider::Compatible => match p.key() {
            _ if clinqy_core::config::value("OPENAI_BASE_URL").is_none() => {
                Err(format!("Set OPENAI_BASE_URL (and OPENAI_COMPATIBLE_API_KEY, LOCAL_MODEL) in {env}: run `clinqy settings` to open it."))
            }
            _ => Ok(p.base_url()),
        },
        _ => match p.key() {
            Some(_) => Ok("key set".into()),
            None => {
                let var = match p {
                    Provider::Anthropic => "ANTHROPIC_API_KEY",
                    Provider::OpenAi => "OPENAI_API_KEY",
                    Provider::Gemini => "GEMINI_API_KEY",
                    _ => "OPENROUTER_API_KEY",
                };
                Err(format!("No {var} yet. Run `clinqy settings`, paste your key after `{var}=` (uncomment the line) and save. Don't paste it into a chat."))
            }
        },
    }
}

/// Makes `p` (and optionally a model id) the one Clinqy uses, in the settings file. The app picks it up on its next
/// request.
pub fn choose(p: Provider, model: Option<&str>) -> std::io::Result<()> {
    crate::setup::ensure_env_file();
    clinqy_core::config::set("PROVIDER", p.id())?;
    // An old "use agy" switch would override the choice.
    if clinqy_core::config::value("USE_AGY").is_some() {
        clinqy_core::config::set("USE_AGY", "")?;
    }
    if let Some(m) = model.filter(|m| !m.trim().is_empty()) {
        clinqy_core::config::set(p.model_key(), m.trim())?;
    }
    Ok(())
}

/// Back to automatic: no PROVIDER set, so Clinqy uses what's on the PC (Claude, Codex, agy, Ollama, a key).
pub fn choose_auto() -> std::io::Result<Provider> {
    crate::setup::ensure_env_file();
    clinqy_core::config::set("PROVIDER", "")?;
    if clinqy_core::config::value("USE_AGY").is_some() {
        clinqy_core::config::set("USE_AGY", "")?;
    }
    Ok(Provider::detected())
}

/// Whether the model was picked automatically (nothing set).
pub fn is_auto() -> bool {
    clinqy_core::config::value("PROVIDER").is_none() && clinqy_core::config::value("USE_AGY").is_none()
}

/// Asks the model for one word, to prove the login or key works. Returns how long it took.
pub async fn test(p: Provider) -> Result<Duration, String> {
    let model = p.default_model();
    let t0 = Instant::now();
    let session = clinqy_core::session::Session::start("You are checking that a connection works. Reply with exactly: OK", &model, p).map_err(|e| e.to_string())?;
    let reply = tokio::time::timeout(Duration::from_secs(120), session.send("ping", None, None)).await;
    session.close();
    match reply {
        Err(_) => Err("no answer in 2 minutes".into()),
        Ok(Err(e)) => Err(first_line(&e.to_string())),
        Ok(Ok(text)) if text.trim().is_empty() => Err("it answered with nothing (is it logged in? run it once in a terminal)".into()),
        Ok(Ok(_)) => Ok(t0.elapsed()),
    }
}

fn first_line(s: &str) -> String {
    s.lines().find(|l| !l.trim().is_empty()).unwrap_or(s).chars().take(300).collect()
}

/// A provider as the Clinqy window shows it: whether it's ready here, and how to get it there.
pub fn provider_info(p: Provider) -> serde_json::Value {
    let installed = !p.is_cli() || p.cli().is_some();
    let configured = p.is_configured();
    let kind = match p {
        Provider::ClaudeCli | Provider::CodexCli | Provider::AgyCli => "cli",
        Provider::Ollama | Provider::Compatible => "local",
        _ => "api",
    };
    let state = match kind {
        "cli" if !installed => "not found",
        "cli" if !configured => "log in",
        "api" if !configured => "needs a key",
        "local" if !configured => "not running",
        _ => "ready",
    };
    let (install, login, guide) = match p {
        Provider::ClaudeCli => ("winget install Anthropic.ClaudeCode", "claude", "https://claude.com/claude-code"),
        Provider::CodexCli => ("npm i -g @openai/codex", "codex login", "https://github.com/openai/codex"),
        Provider::AgyCli => ("", "agy", "https://antigravity.google/docs/cli/overview"),
        Provider::Ollama => ("winget install Ollama.Ollama", "", "https://ollama.com/download"),
        _ => ("", "", ""),
    };
    let (key_name, key_link) = match p {
        Provider::Anthropic => ("Anthropic API key", "https://console.anthropic.com/settings/keys"),
        Provider::OpenAi => ("OpenAI API key", "https://platform.openai.com/api-keys"),
        Provider::Gemini => ("Gemini API key", "https://aistudio.google.com/apikey"),
        Provider::OpenRouter => ("OpenRouter API key", "https://openrouter.ai/keys"),
        Provider::Compatible => ("API key (optional)", ""),
        _ => ("", ""),
    };
    let subtitle = match (kind, configured) {
        (_, true) => format!("Ready · {}", model_label(p)),
        ("cli", _) => MODELS.iter().find(|m| m.1 == p).map(|m| m.2.to_string()).unwrap_or_default(),
        ("api", _) => "Add your key to use it".to_string(),
        _ => "Start it on this PC to use it".to_string(),
    };
    serde_json::json!({
        "id": p.id(), "name": p.display_name(), "kind": kind, "installed": installed, "configured": configured, "state": state, "subtitle": subtitle,
        "install": install, "login": login, "guide": guide, "keyName": key_name, "keyLink": key_link,
        "help": if p == Provider::Ollama { "Local models stay on this PC. Use a vision model: Clinqy sends screenshots." } else { "" },
    })
}

/// The variable a provider's key is saved in.
pub fn key_var(p: Provider) -> Option<&'static str> {
    Some(match p {
        Provider::Anthropic => "ANTHROPIC_API_KEY",
        Provider::OpenAi => "OPENAI_API_KEY",
        Provider::Gemini => "GEMINI_API_KEY",
        Provider::OpenRouter => "OPENROUTER_API_KEY",
        Provider::Compatible => "OPENAI_COMPATIBLE_API_KEY",
        _ => return None,
    })
}

/// The coding agents the Clinqy window can connect: (id, name, where it goes).
pub const AGENT_ROWS: [(&str, &str, &str); 7] = [
    ("claude", "Claude Code", "claude mcp add"),
    ("codex", "Codex", "~/.codex/config.toml"),
    ("agy", "Antigravity CLI", "agy mcp add"),
    ("cursor", "Cursor", "~/.cursor/mcp.json"),
    ("gemini", "Gemini CLI", "~/.gemini/settings.json"),
    ("windsurf", "Windsurf", "~/.codeium/windsurf/mcp_config.json"),
    ("opencode", "OpenCode", "opencode mcp add --global"),
];

/// The browser Clinqy adds its extension to, and the request that does it. None when the extension folder is missing.
pub fn extension_task(browser: Option<&str>) -> Result<(String, String, std::path::PathBuf), String> {
    let dir = crate::setup::extension_dir().ok_or("couldn't find the extension folder next to Clinqy")?;
    let name = match browser.map(|b| b.to_lowercase()) {
        Some(b) if b.contains("edge") => "Microsoft Edge".to_string(),
        Some(b) if b.contains("brave") => "Brave".to_string(),
        Some(b) if b.contains("chrome") => "Google Chrome".to_string(),
        Some(b) => return Err(format!("I can add the extension to Chrome, Edge or Brave, not {b:?}")),
        None => clinqy_windows::apps::default_browser().filter(|b| ["Google Chrome", "Microsoft Edge", "Brave"].contains(&b.as_str())).unwrap_or_else(|| "Google Chrome".into()),
    };
    let page = match name.as_str() {
        "Microsoft Edge" => "edge://extensions",
        "Brave" => "brave://extensions",
        _ => "chrome://extensions",
    };
    let toggle = if name == "Microsoft Edge" { "in the left sidebar" } else { "top right" };
    let task = format!(
        "Open {name} and go to {page} (type it into the address bar). If Developer mode ({toggle}) is off, turn it on. Click Load unpacked. In the folder dialog, click the address bar at the top, type {}, press Enter, then click Select Folder. Stop when the Clinqy extension shows in the list. Don't change any other setting.",
        dir.display()
    );
    Ok((name, task, dir))
}

/// The `clinqy` command an agent should start for MCP: the installed copy if there is one, else this one.
pub fn clinqy_exe() -> PathBuf {
    let installed = std::env::var_os("LOCALAPPDATA").map(|d| PathBuf::from(d).join("Programs").join("Clinqy").join("clinqy.exe"));
    if let Some(p) = installed.filter(|p| p.is_file()) {
        return p;
    }
    std::env::current_exe().ok().and_then(|e| e.parent().map(|d| d.join("clinqy.exe"))).filter(|p| p.is_file()).unwrap_or_else(|| PathBuf::from("clinqy.exe"))
}

/// The coding agents `clinqy connect` knows.
pub const AGENTS: [&str; 7] = ["claude", "agy", "cursor", "codex", "gemini", "windsurf", "opencode"];

/// The coding agents on this PC: those whose CLI or settings folder is here.
pub fn installed_agents() -> Vec<&'static str> {
    let home = clinqy_core::paths::home();
    AGENTS
        .into_iter()
        .filter(|a| match *a {
            "claude" => Provider::ClaudeCli.cli().is_some(),
            "codex" => Provider::CodexCli.cli().is_some(),
            "agy" => Provider::AgyCli.cli().is_some(),
            "cursor" => home.join(".cursor").is_dir(),
            "gemini" => home.join(".gemini").is_dir(),
            "windsurf" => home.join(".codeium").join("windsurf").is_dir(),
            "opencode" => opencode_cli().is_some(),
            _ => false,
        })
        .collect()
}

/// Adds Clinqy as an MCP server to one coding agent, keeping its other servers. Returns what was done.
pub fn connect(agent: &str) -> Result<String, String> {
    let exe = clinqy_exe();
    let exe_s = exe.display().to_string();
    let home = clinqy_core::paths::home();
    match agent {
        "claude" | "claude-code" => {
            let cli = Provider::ClaudeCli.cli().ok_or("Claude Code isn't installed (winget install Anthropic.ClaudeCode)")?;
            // `add` refuses a name that exists: replace it, so the path is always the current one.
            let _ = run(&cli, &["mcp", "remove", "--scope", "user", "clinqy"]);
            run(&cli, &["mcp", "add", "--scope", "user", "clinqy", "--", &exe_s, "mcp"])?;
            Ok("Claude Code: added the clinqy MCP server for your user (all projects)".into())
        }
        "agy" | "antigravity" => {
            let cli = Provider::AgyCli.cli().ok_or("the Antigravity CLI (agy) isn't installed")?;
            run(&cli, &["mcp", "add", "clinqy", &exe_s, "mcp"])?;
            Ok("agy: added the clinqy MCP server".into())
        }
        "opencode" => {
            let cli = opencode_cli().ok_or("OpenCode CLI isn't installed or isn't on PATH (set OPENCODE_PATH in the Clinqy settings file)")?;
            run(&cli, &opencode_args(&exe_s))?;
            Ok("OpenCode: added the clinqy MCP server globally (all projects)".into())
        }
        "cursor" => json_server(&home.join(".cursor").join("mcp.json"), &exe_s).map(|p| format!("Cursor: added clinqy to {}", p.display())),
        "gemini" | "gemini-cli" => json_server(&home.join(".gemini").join("settings.json"), &exe_s).map(|p| format!("Gemini CLI: added clinqy to {}", p.display())),
        "windsurf" => json_server(&home.join(".codeium").join("windsurf").join("mcp_config.json"), &exe_s).map(|p| format!("Windsurf: added clinqy to {}", p.display())),
        "codex" => {
            let path = home.join(".codex").join("config.toml");
            let text = std::fs::read_to_string(&path).unwrap_or_default();
            let block = format!("[mcp_servers.clinqy]\ncommand = {:?}\nargs = [\"mcp\"]\n", exe_s);
            let out = match text.find("[mcp_servers.clinqy]") {
                // Replace the old block (up to the next table).
                Some(i) => {
                    let rest = &text[i + 1..];
                    let end = rest.find("\n[").map(|j| i + 1 + j + 1).unwrap_or(text.len());
                    format!("{}{}{}", &text[..i], block, &text[end..])
                }
                None => format!("{}{}{}", text, if text.is_empty() || text.ends_with('\n') { "\n" } else { "\n\n" }, block),
            };
            std::fs::create_dir_all(path.parent().unwrap()).map_err(|e| e.to_string())?;
            std::fs::write(&path, out).map_err(|e| e.to_string())?;
            Ok(format!("Codex: added clinqy to {}", path.display()))
        }
        other => Err(format!("I don't know the agent {other:?}; use one of: {}", AGENTS.join(", "))),
    }
}

/// Finds OpenCode's native executable or the current official npm CLI shim.
fn opencode_cli() -> Option<clinqy_core::provider::CliCommand> {
    let home = clinqy_core::paths::home();
    let spots = [
        home.join(".opencode").join("bin").join("opencode.exe"),
        home.join(".bun").join("bin").join("opencode.exe"),
    ];
    clinqy_core::provider::find_cli("OPENCODE_PATH", "opencode", &spots, "@opencode/cli/bin/opencode.cjs")
}

fn opencode_args(exe: &str) -> [&str; 7] {
    ["mcp", "add", "clinqy", "--global", "--", exe, "mcp"]
}

/// `{"mcpServers": {"clinqy": {...}}}` in a JSON config, keeping everything else.
fn json_server(path: &std::path::Path, exe: &str) -> Result<PathBuf, String> {
    let mut v: serde_json::Value = std::fs::read_to_string(path).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_else(|| serde_json::json!({}));
    if !v.is_object() {
        return Err(format!("{} isn't a JSON object; fix it by hand", path.display()));
    }
    if !v["mcpServers"].is_object() {
        v["mcpServers"] = serde_json::json!({});
    }
    v["mcpServers"]["clinqy"] = serde_json::json!({"command": exe, "args": ["mcp"]});
    std::fs::create_dir_all(path.parent().unwrap()).map_err(|e| e.to_string())?;
    std::fs::write(path, serde_json::to_string_pretty(&v).unwrap()).map_err(|e| e.to_string())?;
    Ok(path.to_path_buf())
}

fn run(cli: &clinqy_core::provider::CliCommand, args: &[&str]) -> Result<(), String> {
    use std::os::windows::process::CommandExt;
    let out = std::process::Command::new(&cli.program)
        .args(&cli.prefix)
        .args(args)
        .creation_flags(clinqy_core::session::CREATE_NO_WINDOW)
        .output()
        .map_err(|e| e.to_string())?;
    if out.status.success() {
        Ok(())
    } else {
        let err = String::from_utf8_lossy(&out.stderr);
        let msg = if err.trim().is_empty() { String::from_utf8_lossy(&out.stdout).into_owned() } else { err.into_owned() };
        Err(first_line(&msg))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn opencode_connection_is_global_and_keeps_executable_path_as_one_argument() {
        assert_eq!(AGENTS.last(), Some(&"opencode"));
        assert!(AGENT_ROWS.iter().any(|(id, _, _)| *id == "opencode"));
        assert_eq!(
            opencode_args(r"C:\Program Files\Clinqy\clinqy.exe"),
            ["mcp", "add", "clinqy", "--global", "--", r"C:\Program Files\Clinqy\clinqy.exe", "mcp"]
        );
    }
}
