//! ACP transport for model-only OpenCode and Cursor sessions. Clinqy is the executor; external agent tools and
//! permission requests are never granted. OpenCode gets a deny-all agent and Cursor runs its read-only Ask mode.

use crate::provider::{CliCommand, Provider};
use anyhow::{Context, Result, anyhow, bail};
use base64::Engine;
use serde_json::{Value, json};
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::sync::{Mutex, mpsc};

pub struct AcpSession {
    provider: Provider,
    model: String,
    directory: PathBuf,
    child: parking_lot::Mutex<Option<Child>>,
    stdin: Mutex<Option<ChildStdin>>,
    messages: Mutex<mpsc::UnboundedReceiver<Value>>,
    ready: Mutex<bool>,
    session_id: Mutex<Option<String>>,
    alive: Arc<AtomicBool>,
    send_lock: Mutex<()>,
    next_id: AtomicU64,
}

fn provider_environment_keys(provider: Provider) -> &'static [&'static str] {
    match provider {
        Provider::CursorCli => &["CURSOR_API_KEY", "CURSOR_AUTH_TOKEN"],
        Provider::OpenCodeCli => &[
            "OPENCODE_API_KEY",
            "XDG_CONFIG_HOME",
            "XDG_DATA_HOME",
            "OPENCODE_CONFIG",
            "OPENCODE_CONFIG_CONTENT",
            "OPENCODE_DB",
        ],
        _ => &[],
    }
}

impl AcpSession {
    pub fn start(provider: Provider, system: &str, model: &str) -> Result<Arc<Self>> {
        let CliCommand { program, prefix } = provider
            .cli()
            .ok_or_else(|| anyhow!("{} CLI not found", provider.display_name()))?;
        let directory =
            std::env::temp_dir().join(format!("clinqy-{}-{}", provider.id(), uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&directory)?;
        if provider == Provider::OpenCodeCli {
            write_opencode_isolation(&directory, system)?;
        } else if provider == Provider::CursorCli {
            write_cursor_isolation(&directory, system)?;
        }
        let mut command = Command::new(&program);
        command
            .args(prefix)
            .arg("acp")
            .current_dir(&directory)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true);
        for key in provider_environment_keys(provider) {
            if let Some(value) = crate::config::value(key) {
                command.env(key, value);
            }
        }
        if provider == Provider::OpenCodeCli {
            // User-level OpenCode plugins and inline config must not widen the model-only ACP session.
            command.env("OPENCODE_PURE", "true");
            let inline = crate::config::value("OPENCODE_CONFIG_CONTENT");
            command.env(
                "OPENCODE_CONFIG_CONTENT",
                enforced_opencode_config_content(inline.as_deref())?,
            );
        }
        #[cfg(windows)]
        command.creation_flags(crate::session::CREATE_NO_WINDOW);
        let mut child = command.spawn().map_err(|error| {
            let _ = std::fs::remove_dir_all(&directory);
            anyhow!("couldn't start {}: {error}", program.display())
        })?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| anyhow!("{} ACP stdin unavailable", provider.display_name()))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| anyhow!("{} ACP stdout unavailable", provider.display_name()))?;
        let (tx, messages) = mpsc::unbounded_channel();
        let alive = Arc::new(AtomicBool::new(true));
        spawn_reader(stdout, tx, alive.clone());
        Ok(Arc::new(Self {
            provider,
            model: provider.model(model),
            directory,
            child: parking_lot::Mutex::new(Some(child)),
            stdin: Mutex::new(Some(stdin)),
            messages: Mutex::new(messages),
            ready: Mutex::new(false),
            session_id: Mutex::new(None),
            alive,
            send_lock: Mutex::new(()),
            next_id: AtomicU64::new(0),
        }))
    }

    pub fn is_alive(&self) -> bool {
        self.alive.load(Ordering::Acquire)
    }

    pub async fn send(
        &self,
        text: &str,
        image: Option<String>,
        partial: Option<mpsc::UnboundedSender<String>>,
    ) -> Result<String> {
        let result = self.send_inner(text, image, partial).await;
        if result.is_err() {
            self.close();
        }
        result
    }

    async fn send_inner(
        &self,
        text: &str,
        image: Option<String>,
        partial: Option<mpsc::UnboundedSender<String>>,
    ) -> Result<String> {
        let _guard = self.send_lock.lock().await;
        self.prepare().await?;
        let session_id = self
            .session_id
            .lock()
            .await
            .clone()
            .ok_or_else(|| anyhow!("ACP session did not start"))?;
        let mut content = Vec::new();
        content.push(json!({"type":"text", "text":text}));
        if let Some(image) = image {
            base64::engine::general_purpose::STANDARD
                .decode(&image)
                .context("invalid screenshot encoding")?;
            content.push(json!({"type":"image", "mimeType":"image/jpeg", "data":image}));
        }
        let (result, answer) = self
            .request(
                "session/prompt",
                json!({"sessionId":session_id, "prompt":content}),
                partial,
            )
            .await?;
        if result["stopReason"] == "cancelled" {
            bail!("{} cancelled the turn", self.provider.display_name());
        }
        if answer.trim().is_empty() {
            bail!("Empty reply from {}", self.provider.display_name());
        }
        Ok(answer)
    }

    pub fn close(&self) {
        self.alive.store(false, Ordering::Release);
        if let Some(mut child) = self.child.lock().take() {
            let directory = self.directory.clone();
            if let Ok(runtime) = tokio::runtime::Handle::try_current() {
                runtime.spawn(async move {
                    let _ = child.start_kill();
                    let _ = child.wait().await;
                    let _ = std::fs::remove_dir_all(directory);
                });
            } else {
                let _ = child.start_kill();
                std::thread::spawn(move || {
                    loop {
                        match child.try_wait() {
                            Ok(Some(_)) | Err(_) => break,
                            Ok(None) => std::thread::sleep(std::time::Duration::from_millis(10)),
                        }
                    }
                    let _ = std::fs::remove_dir_all(directory);
                });
            }
        } else {
            let _ = std::fs::remove_dir_all(&self.directory);
        }
    }

    async fn prepare(&self) -> Result<()> {
        let mut ready = self.ready.lock().await;
        if *ready {
            return Ok(());
        }
        if !self.is_alive() {
            bail!("{} ACP process stopped", self.provider.display_name());
        }
        let (initialized, _) = self.request("initialize", json!({
            "protocolVersion": 1,
            "clientInfo": {"name":"clinqy", "version":"1"},
            "clientCapabilities": {"fs":{"readTextFile":false, "writeTextFile":false}, "terminal":false}
        }), None).await?;
        self.write(&json!({"method":"initialized", "params":{}}))
            .await?;
        if self.provider == Provider::CursorCli {
            self.request("authenticate", json!({"methodId":"cursor_login"}), None)
                .await
                .map_err(|error| anyhow!("Cursor Agent couldn't use its current login. Run `agent login` and retry. {error}"))?;
        } else if initialized["authMethods"]
            .as_array()
            .is_some_and(|methods| {
                methods
                    .iter()
                    .any(|m| m["id"] == "opencode-login" && m["type"] == "agent")
            })
        {
            // OpenCode's ACP authentication method uses credentials already stored by `opencode auth login`.
            self.request("authenticate", json!({"methodId":"opencode-login"}), None)
                .await?;
        }
        let (created, _) = self
            .request(
                "session/new",
                json!({"cwd":self.directory.display().to_string(), "mcpServers":[]}),
                None,
            )
            .await?;
        let session_id = created["sessionId"]
            .as_str()
            .filter(|id| !id.is_empty())
            .ok_or_else(|| {
                anyhow!(
                    "{} returned no ACP session ID",
                    self.provider.display_name()
                )
            })?
            .to_string();
        let mode = if self.provider == Provider::CursorCli {
            "ask"
        } else {
            "clinqy"
        };
        self.request(
            "session/set_mode",
            json!({"sessionId":session_id, "modeId":mode}),
            None,
        )
        .await?;
        if !self.model.is_empty() {
            self.request(
                "session/set_config_option",
                json!({"sessionId":session_id, "configId":"model", "value":self.model}),
                None,
            )
            .await?;
        }
        *self.session_id.lock().await = Some(session_id);
        *ready = true;
        Ok(())
    }

    async fn request(
        &self,
        method: &str,
        params: Value,
        partial: Option<mpsc::UnboundedSender<String>>,
    ) -> Result<(Value, String)> {
        if !self.is_alive() {
            bail!("{} ACP process stopped", self.provider.display_name());
        }
        let id = self.next_id.fetch_add(1, Ordering::Relaxed) + 1;
        self.write(&json!({"id":id, "method":method, "params":params}))
            .await?;
        let deadline = tokio::time::Instant::now()
            + if method == "session/prompt" {
                std::time::Duration::from_secs(120)
            } else {
                std::time::Duration::from_secs(25)
            };
        let mut answer = String::new();
        loop {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                bail!(
                    "Timed out waiting for {} during {method}",
                    self.provider.display_name()
                );
            }
            let message = tokio::time::timeout(remaining, self.messages.lock().await.recv())
                .await
                .map_err(|_| {
                    anyhow!(
                        "Timed out waiting for {} during {method}",
                        self.provider.display_name()
                    )
                })?
                .ok_or_else(|| anyhow!("{} ACP process ended", self.provider.display_name()))?;
            if message["method"] == "session/update"
                && message["params"]["update"]["sessionUpdate"] == "agent_message_chunk"
            {
                let chunk = message["params"]["update"]["content"]["text"]
                    .as_str()
                    .or_else(|| message["params"]["update"]["text"].as_str())
                    .unwrap_or_default();
                if !chunk.is_empty() {
                    answer.push_str(chunk);
                    if let Some(partial) = &partial {
                        let _ = partial.send(answer.clone());
                    }
                }
            }
            if let Some(request_method) = message["method"].as_str() {
                if let Some(request_id) = message.get("id") {
                    if request_method == "session/request_permission" {
                        // Select an advertised rejection option, or decline if the agent offers none.
                        let outcome = permission_rejection(&message["params"]);
                        self.write(&json!({"id":request_id, "result":{"outcome":outcome}}))
                            .await?;
                    } else {
                        self.write(&json!({"id":request_id, "error":{"code":-32601, "message":"Unsupported ACP request"}})).await?;
                    }
                    continue;
                }
            }
            if message["id"] != json!(id) {
                continue;
            }
            if let Some(error) = message.get("error") {
                let error = error["message"].as_str().unwrap_or("request failed");
                if self.provider == Provider::OpenCodeCli && error.to_lowercase().contains("auth") {
                    bail!(
                        "OpenCode needs a provider login. Run `opencode auth login` and retry. {error}"
                    );
                }
                bail!("{}: {error}", self.provider.display_name());
            }
            return Ok((
                message.get("result").cloned().unwrap_or(Value::Null),
                answer,
            ));
        }
    }

    async fn write(&self, object: &Value) -> Result<()> {
        let mut message = object.clone();
        message["jsonrpc"] = json!("2.0");
        let mut line = serde_json::to_vec(&message)?;
        line.push(b'\n');
        let mut stdin = self.stdin.lock().await;
        let Some(stdin) = stdin.as_mut() else {
            bail!("{} ACP input closed", self.provider.display_name());
        };
        stdin.write_all(&line).await?;
        stdin.flush().await?;
        Ok(())
    }
}

fn permission_rejection(params: &Value) -> Value {
    params["options"]
        .as_array()
        .and_then(|options| {
            options
                .iter()
                .find(|option| option["kind"] == "reject_once")
                .or_else(|| {
                    options
                        .iter()
                        .find(|option| option["kind"] == "reject_always")
                })
        })
        .and_then(|option| option["optionId"].as_str())
        .map(|option_id| json!({"outcome":"selected", "optionId":option_id}))
        .unwrap_or_else(|| json!({"outcome":"cancelled"}))
}

fn enforced_opencode_config_content(existing: Option<&str>) -> Result<String> {
    let mut config: Value = match existing {
        Some(value) if !value.trim().is_empty() => serde_json::from_str(value)
            .context("OPENCODE_CONFIG_CONTENT must be a JSON object for isolated ACP sessions")?,
        _ => json!({}),
    };
    let root = config.as_object_mut().ok_or_else(|| {
        anyhow!("OPENCODE_CONFIG_CONTENT must be a JSON object for isolated ACP sessions")
    })?;
    let deny_all = json!({"action":"*", "resource":"*", "effect":"deny"});

    let global = root.entry("permissions").or_insert_with(|| json!([]));
    global
        .as_array_mut()
        .ok_or_else(|| anyhow!("OPENCODE_CONFIG_CONTENT permissions must be an array"))?
        .push(deny_all.clone());

    let agents = root.entry("agents").or_insert_with(|| json!({}));
    let agents = agents
        .as_object_mut()
        .ok_or_else(|| anyhow!("OPENCODE_CONFIG_CONTENT agents must be an object"))?;
    let clinqy = agents.entry("clinqy").or_insert_with(|| json!({}));
    let clinqy = clinqy
        .as_object_mut()
        .ok_or_else(|| anyhow!("OPENCODE_CONFIG_CONTENT agents.clinqy must be an object"))?;
    let agent_permissions = clinqy.entry("permissions").or_insert_with(|| json!([]));
    agent_permissions
        .as_array_mut()
        .ok_or_else(|| {
            anyhow!("OPENCODE_CONFIG_CONTENT agents.clinqy.permissions must be an array")
        })?
        .push(deny_all);

    serde_json::to_string(&config).context("couldn't encode isolated OpenCode ACP settings")
}

fn spawn_reader(stdout: ChildStdout, tx: mpsc::UnboundedSender<Value>, alive: Arc<AtomicBool>) {
    tokio::spawn(async move {
        let mut lines = BufReader::new(stdout).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            if line.len() > 16 * 1024 * 1024 {
                break;
            }
            let Ok(message) = serde_json::from_str::<Value>(&line) else {
                break;
            };
            if tx.send(message).is_err() {
                break;
            }
        }
        alive.store(false, Ordering::Release);
    });
}

fn write_opencode_isolation(directory: &std::path::Path, system: &str) -> Result<()> {
    let agents = directory.join(".opencode").join("agents");
    std::fs::create_dir_all(&agents)?;
    let agent = format!(
        "---\ndescription: Clinqy model-only response agent\nmode: primary\npermissions:\n  - action: \"*\"\n    resource: \"*\"\n    effect: deny\n---\n{system}\n"
    );
    std::fs::write(agents.join("clinqy.md"), agent)?;
    std::fs::write(
        directory.join("opencode.json"),
        r#"{"$schema":"https://opencode.ai/config.json","default_agent":"clinqy","permissions":[{"action":"*","resource":"*","effect":"deny"}]}"#,
    )?;
    Ok(())
}

fn write_cursor_isolation(directory: &std::path::Path, system: &str) -> Result<()> {
    // Cursor CLI loads AGENTS.md from the project root as persistent instructions.
    std::fs::write(directory.join("AGENTS.md"), system)?;
    let config_dir = directory.join(".cursor");
    std::fs::create_dir_all(&config_dir)?;
    let config = json!({
        "version": 1,
        "editor": {"vimMode": false},
        "permissions": {
            "allow": [],
            "deny": ["Shell(*)", "Read(*)", "Write(*)", "WebFetch(*)", "Mcp(*:*)"]
        }
    });
    std::fs::write(config_dir.join("cli.json"), serde_json::to_vec(&config)?)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn permission_response_only_selects_advertised_rejection() {
        let denied = permission_rejection(&json!({"options":[
            {"optionId":"reject-forever", "kind":"reject_always"},
            {"optionId":"allow", "kind":"allow_once"},
            {"optionId":"reject", "kind":"reject_once"}
        ]}));
        assert_eq!(denied, json!({"outcome":"selected", "optionId":"reject"}));

        let declined = permission_rejection(&json!({"options":[
            {"optionId":"allow", "kind":"allow_once"}
        ]}));
        assert_eq!(declined, json!({"outcome":"cancelled"}));
    }

    #[test]
    fn opencode_inline_config_preserves_settings_and_appends_final_denials() {
        let raw = r#"{"model":"openai/gpt-4o","permissions":[{"action":"read","resource":"*","effect":"allow"}],"agents":{"clinqy":{"permissions":[{"action":"shell","resource":"*","effect":"allow"}]}}}"#;
        let config: Value =
            serde_json::from_str(&enforced_opencode_config_content(Some(raw)).unwrap()).unwrap();
        assert_eq!(config["model"], "openai/gpt-4o");
        assert_eq!(
            config["permissions"].as_array().unwrap().last().unwrap()["effect"],
            "deny"
        );
        assert_eq!(
            config["agents"]["clinqy"]["permissions"]
                .as_array()
                .unwrap()
                .last()
                .unwrap()["effect"],
            "deny"
        );

        let empty: Value =
            serde_json::from_str(&enforced_opencode_config_content(None).unwrap()).unwrap();
        assert_eq!(empty["permissions"][0]["effect"], "deny");
        assert_eq!(
            empty["agents"]["clinqy"]["permissions"][0]["effect"],
            "deny"
        );
    }

    #[test]
    fn opencode_agent_denies_every_tool() {
        let root =
            std::env::temp_dir().join(format!("clinqy-acp-isolation-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        write_opencode_isolation(&root, "Model-only system prompt.").unwrap();
        let config: Value =
            serde_json::from_slice(&std::fs::read(root.join("opencode.json")).unwrap()).unwrap();
        let agent =
            std::fs::read_to_string(root.join(".opencode").join("agents").join("clinqy.md"))
                .unwrap();
        assert_eq!(config["default_agent"], "clinqy");
        assert_eq!(config["permissions"][0]["action"], "*");
        assert_eq!(config["permissions"][0]["effect"], "deny");
        assert!(
            agent.contains("mode: primary")
                && agent.contains("effect: deny")
                && agent.contains("Model-only system prompt.")
        );
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn cursor_project_config_denies_mcp_and_local_tools() {
        let root =
            std::env::temp_dir().join(format!("clinqy-cursor-isolation-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        write_cursor_isolation(&root, "Model-only system prompt.").unwrap();
        assert_eq!(
            std::fs::read_to_string(root.join("AGENTS.md")).unwrap(),
            "Model-only system prompt."
        );
        let config: Value =
            serde_json::from_slice(&std::fs::read(root.join(".cursor").join("cli.json")).unwrap())
                .unwrap();
        assert_eq!(config["version"], 1);
        let deny = config["permissions"]["deny"].as_array().unwrap();
        assert!(deny.iter().any(|rule| rule == "Mcp(*:*)"));
        assert!(deny.iter().any(|rule| rule == "Shell(*)"));
        assert!(deny.iter().any(|rule| rule == "Read(*)"));
        assert!(deny.iter().any(|rule| rule == "Write(*)"));
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn local_settings_are_forwarded_only_to_the_matching_provider() {
        assert_eq!(
            provider_environment_keys(Provider::CursorCli),
            &["CURSOR_API_KEY", "CURSOR_AUTH_TOKEN"]
        );
        assert!(
            provider_environment_keys(Provider::CursorCli)
                .iter()
                .all(|key| key.starts_with("CURSOR_"))
        );
        assert_eq!(
            provider_environment_keys(Provider::OpenCodeCli),
            &[
                "OPENCODE_API_KEY",
                "XDG_CONFIG_HOME",
                "XDG_DATA_HOME",
                "OPENCODE_CONFIG",
                "OPENCODE_CONFIG_CONTENT",
                "OPENCODE_DB"
            ]
        );
        assert!(provider_environment_keys(Provider::AgyCli).is_empty());
    }
}
