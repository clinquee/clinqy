//! Talks to the Clinqy browser extension over a localhost WebSocket (ws://127.0.0.1:47823, the same port and
//! protocol as the Mac app, so the one extension serves both). The extension reads the live page and performs
//! precise clicks and fills. Only browser-extension origins may connect, so web pages can't reach this server.

use crate::page::Page;
use crate::worker::{self, worker};
use anyhow::{anyhow, bail, Result};
use futures_util::{SinkExt, StreamExt};
use parking_lot::Mutex;
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};
use tokio_tungstenite::tungstenite::handshake::server::{ErrorResponse, Request, Response};
use tokio_tungstenite::tungstenite::Message;

pub const PORT: u16 = 47823;
/// The extension version this app expects (extension/manifest.json). An older copy still running is asked to reload.
pub const EXTENSION_VERSION: &str = "1.9.15";

/// Finds which program is on the other end of a local TCP connection (by its port): "chrome.exe".
pub type OwnerLookup = Box<dyn Fn(u16) -> Option<String> + Send + Sync>;

struct Conn {
    tx: mpsc::UnboundedSender<Message>,
    /// The browser's executable, once known.
    owner: Option<String>,
}

pub struct Bridge {
    conns: Mutex<HashMap<u64, Conn>>,
    pending: Mutex<HashMap<String, oneshot::Sender<Result<Value>>>>,
    counter: AtomicU64,
    next_conn: AtomicU64,
    reload_asked: Mutex<HashMap<String, u32>>,
    owner_lookup: Mutex<Option<Arc<OwnerLookup>>>,
    started: Mutex<bool>,
}

#[derive(Clone, Debug)]
pub struct TabInfo {
    pub id: i64,
    pub url: String,
    pub connection: u64,
}

#[derive(Clone, Debug)]
pub struct BrowserTab {
    pub id: i64,
    pub title: String,
    pub url: String,
    pub active: bool,
    pub opened: bool,
}

pub fn bridge() -> &'static Bridge {
    static B: OnceLock<Bridge> = OnceLock::new();
    B.get_or_init(|| Bridge {
        conns: Mutex::new(HashMap::new()),
        pending: Mutex::new(HashMap::new()),
        counter: AtomicU64::new(0),
        next_conn: AtomicU64::new(1),
        reload_asked: Mutex::new(HashMap::new()),
        owner_lookup: Mutex::new(None),
        started: Mutex::new(false),
    })
}

fn args(pairs: Value) -> Map<String, Value> {
    pairs.as_object().cloned().unwrap_or_default()
}

impl Bridge {
    pub fn set_owner_lookup(&self, f: OwnerLookup) {
        *self.owner_lookup.lock() = Some(Arc::new(f));
    }

    pub fn is_connected(&self) -> bool {
        !self.conns.lock().is_empty()
    }

    /// Whether pages of the browser `exe` can be read (the background browser needs no extension).
    pub fn serves(&self, exe: &str) -> bool {
        exe == worker::EXE || self.is_connected()
    }

    /// Starts listening (once). Fails if another Clinqy already holds the port.
    pub async fn start(&'static self) -> Result<()> {
        {
            let mut s = self.started.lock();
            if *s {
                return Ok(());
            }
            *s = true;
        }
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", PORT)).await.map_err(|e| {
            *self.started.lock() = false;
            anyhow!("browser bridge: port {PORT} is busy ({e})")
        })?;
        tokio::spawn(async move {
            loop {
                let Ok((stream, peer)) = listener.accept().await else { continue };
                tokio::spawn(async move {
                    let _ = self.serve(stream, peer.port()).await;
                });
            }
        });
        Ok(())
    }

    async fn serve(&'static self, stream: tokio::net::TcpStream, peer_port: u16) -> Result<()> {
        // Browser pages send their own origin; only extensions are let in.
        #[allow(clippy::result_large_err)] // tungstenite requires an owned HTTP rejection response.
        let check = |req: &Request, resp: Response| -> std::result::Result<Response, ErrorResponse> {
            let origin = req.headers().get("origin").and_then(|v| v.to_str().ok()).unwrap_or("");
            if origin.starts_with("chrome-extension://") || origin.starts_with("moz-extension://") || origin.starts_with("extension://") {
                Ok(resp)
            } else {
                let mut r = ErrorResponse::new(Some("forbidden".into()));
                *r.status_mut() = tokio_tungstenite::tungstenite::http::StatusCode::FORBIDDEN;
                Err(r)
            }
        };
        let ws = tokio_tungstenite::accept_hdr_async(stream, check).await?;
        let (mut sink, mut source) = ws.split();
        let (tx, mut rx) = mpsc::unbounded_channel::<Message>();
        let id = self.next_conn.fetch_add(1, Ordering::Relaxed);
        self.conns.lock().insert(id, Conn { tx, owner: None });
        // Which browser is this? Asked off the async threads (it walks the TCP table).
        let lookup = self.owner_lookup.lock().clone();
        if let Some(lookup) = lookup {
            tokio::task::spawn_blocking(move || {
                let owner = lookup(peer_port).unwrap_or_else(|| "?".into());
                if let Some(c) = bridge().conns.lock().get_mut(&id) {
                    c.owner = Some(owner);
                }
            });
        }
        let writer = tokio::spawn(async move {
            while let Some(m) = rx.recv().await {
                if sink.send(m).await.is_err() {
                    break;
                }
            }
        });
        while let Some(msg) = source.next().await {
            let text = match msg {
                Ok(Message::Text(t)) => t.to_string(),
                Ok(Message::Ping(p)) => {
                    if let Some(c) = self.conns.lock().get(&id) {
                        let _ = c.tx.send(Message::Pong(p));
                    }
                    continue;
                }
                Ok(Message::Close(_)) | Err(_) => break,
                _ => continue,
            };
            let Ok(v) = serde_json::from_str::<Value>(&text) else { continue };
            if v["type"] == "hello" {
                self.check_version(v["version"].as_str().unwrap_or(""), id);
            }
            if let Some(rid) = v["id"].as_str() {
                if let Some(waiter) = self.pending.lock().remove(rid) {
                    let r = if v["ok"] == true {
                        Ok(if v["result"].is_object() { v["result"].clone() } else { json!({}) })
                    } else {
                        Err(anyhow!("{}", v["error"].as_str().unwrap_or("extension error")))
                    };
                    let _ = waiter.send(r);
                }
            }
        }
        self.conns.lock().remove(&id);
        writer.abort();
        Ok(())
    }

    fn check_version(&'static self, version: &str, conn: u64) {
        if version == EXTENSION_VERSION {
            return;
        }
        {
            let mut asked = self.reload_asked.lock();
            let n = asked.entry(version.to_string()).or_insert(0);
            if *n >= 3 {
                return;
            }
            *n += 1;
        }
        crate::log::write(&format!("browser extension v{version} connected, app expects v{EXTENSION_VERSION}: reloading it"));
        tokio::spawn(async move {
            let _ = self.request(conn, args(json!({"cmd": "reload"})), 5.0).await;
        });
    }

    async fn request(&self, conn: u64, mut body: Map<String, Value>, timeout: f64) -> Result<Value> {
        let rid = format!("r{}", self.counter.fetch_add(1, Ordering::Relaxed) + 1);
        body.insert("id".into(), json!(rid));
        let (tx, rx) = oneshot::channel();
        {
            let conns = self.conns.lock();
            let c = conns.get(&conn).ok_or_else(|| anyhow!("browser extension not connected"))?;
            self.pending.lock().insert(rid.clone(), tx);
            if c.tx.send(Message::Text(Value::Object(body).to_string())).is_err() {
                self.pending.lock().remove(&rid);
                bail!("browser extension not connected");
            }
        }
        match tokio::time::timeout(Duration::from_secs_f64(timeout), rx).await {
            Ok(Ok(r)) => r,
            Ok(Err(_)) => bail!("browser extension disconnected"),
            Err(_) => {
                self.pending.lock().remove(&rid);
                bail!("browser extension didn't answer")
            }
        }
    }

    /// Connections to ask about the browser `exe`: its own; while one is still being identified, that one too;
    /// None = any (the focused window decides).
    fn candidates(&self, exe: Option<&str>) -> Vec<u64> {
        let conns = self.conns.lock();
        let all: Vec<u64> = {
            let mut v: Vec<u64> = conns.keys().copied().collect();
            v.sort();
            v
        };
        let Some(exe) = exe else { return all };
        let own: Vec<u64> =
            all.iter().copied().filter(|id| conns[id].owner.as_deref().map(|o| o.eq_ignore_ascii_case(exe)).unwrap_or(false)).collect();
        if own.is_empty() {
            all.into_iter().filter(|id| conns[id].owner.is_none() || conns[id].owner.as_deref() == Some("?")).collect()
        } else {
            own
        }
    }

    /// The page in the focused window of the browser `exe` (any browser with None).
    pub async fn snapshot(&self, exe: Option<&str>) -> Option<Page> {
        if exe == Some(worker::EXE) {
            return worker().snapshot(None).await;
        }
        let pool = self.candidates(exe);
        for &c in &pool {
            if let Ok(r) = self.request(c, args(json!({"cmd": "snapshot"})), 5.0).await {
                if r["focused"] == true {
                    return Some(self.parse(&r, c));
                }
            }
        }
        // Nobody reports focus (the page hasn't got keyboard focus yet): the only candidate, if one.
        if pool.len() == 1 {
            if let Ok(r) = self.request(pool[0], args(json!({"cmd": "snapshot"})), 5.0).await {
                return Some(self.parse(&r, pool[0]));
            }
        }
        None
    }

    fn parse(&self, r: &Value, conn: u64) -> Page {
        crate::replay::record_page(r);
        Page::parse(r, conn)
    }

    /// The connection to the user's own browser for a task to work in: Chrome when it's there, else any.
    pub fn own_browser(&self) -> Option<u64> {
        let conns = self.conns.lock();
        let chrome = conns.iter().find(|(_, c)| c.owner.as_deref().unwrap_or("").to_lowercase().contains("chrome")).map(|(id, _)| *id);
        chrome.or_else(|| conns.keys().min().copied())
    }

    /// One command on `conn`, for a task working in a tab of the user's browser.
    pub async fn ask(&self, conn: u64, cmd: &str, a: Value, timeout: f64) -> Result<Value> {
        let mut body = args(a);
        body.insert("cmd".into(), json!(cmd));
        self.request(conn, body, timeout).await
    }

    pub async fn perform(&self, cmd: &str, page: &Page, a: Value, timeout: f64) -> Result<Value> {
        if page.connection == worker::CONNECTION {
            return worker().command(cmd, page.tab_id, a).await;
        }
        let document = page.document_id.as_ref().ok_or_else(|| anyhow!("Update the browser extension and take a fresh look: missing document token"))?;
        let snapshot = page.snapshot_id.as_ref().ok_or_else(|| anyhow!("Update the browser extension and take a fresh look: missing snapshot token"))?;
        let tab = page.tab_id.ok_or_else(|| anyhow!("Take a fresh look: missing tab identity"))?;
        let mut body = args(a);
        body.insert("cmd".into(), json!(cmd));
        body.insert("tabId".into(), json!(tab));
        body.insert("documentID".into(), json!(document));
        body.insert("snapshotID".into(), json!(snapshot));
        self.request(page.connection, body, timeout).await
    }

    pub async fn selection(&self, exe: Option<&str>) -> Option<String> {
        for c in self.candidates(exe) {
            if let Ok(r) = self.request(c, args(json!({"cmd": "selection"})), 1.2).await {
                if r["focused"] == true {
                    let t = r["text"].as_str().unwrap_or("").trim().to_string();
                    return (!t.is_empty()).then_some(t);
                }
            }
        }
        None
    }

    pub async fn active_tab(&self, exe: Option<&str>) -> Option<TabInfo> {
        if exe == Some(worker::EXE) {
            let r = worker().command("tabInfo", None, json!({})).await.ok()?;
            return Some(TabInfo { id: r["id"].as_i64()?, url: r["url"].as_str().unwrap_or("").into(), connection: worker::CONNECTION });
        }
        for c in self.candidates(exe) {
            if let Ok(r) = self.request(c, args(json!({"cmd": "tabInfo"})), 1.5).await {
                if r["focused"] == true {
                    if let Some(id) = r["id"].as_i64() {
                        return Some(TabInfo { id, url: r["url"].as_str().unwrap_or("").into(), connection: c });
                    }
                }
            }
        }
        None
    }

    pub async fn tab_command(&self, cmd: &str, tab: &TabInfo, a: Value) -> Option<Value> {
        if tab.connection == worker::CONNECTION {
            return worker().command(cmd, Some(tab.id), a).await.ok();
        }
        let mut body = args(a);
        body.insert("cmd".into(), json!(cmd));
        self.request(tab.connection, body, 3.0).await.ok()
    }

    async fn front_connection(&self, exe: Option<&str>) -> Option<u64> {
        let pool = self.candidates(exe);
        for &c in &pool {
            if let Ok(r) = self.request(c, args(json!({"cmd": "tabInfo"})), 1.5).await {
                if r["focused"] == true {
                    return Some(c);
                }
            }
        }
        (pool.len() == 1).then(|| pool[0])
    }

    pub async fn tabs(&self, exe: Option<&str>) -> Result<Vec<BrowserTab>> {
        let r = if exe == Some(worker::EXE) {
            worker().command("tabs", None, json!({})).await?
        } else {
            let c = self.front_connection(exe).await.ok_or_else(|| anyhow!("browser extension not connected"))?;
            self.request(c, args(json!({"cmd": "tabs"})), 3.0).await?
        };
        Ok(r["tabs"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|t| {
                        Some(BrowserTab {
                            id: t["id"].as_i64()?,
                            title: t["title"].as_str().unwrap_or("").into(),
                            url: t["url"].as_str().unwrap_or("").into(),
                            active: t["active"] == true,
                            opened: t["opened"] == true,
                        })
                    })
                    .collect()
            })
            .unwrap_or_default())
    }

    pub async fn switch_tab(&self, id: i64, exe: Option<&str>) -> Result<()> {
        if exe == Some(worker::EXE) {
            return worker().command("switchTab", Some(id), json!({})).await.map(|_| ());
        }
        let c = self.front_connection(exe).await.ok_or_else(|| anyhow!("browser extension not connected"))?;
        self.request(c, args(json!({"cmd": "switchTab", "tabId": id})), 3.0).await.map(|_| ())
    }

    pub async fn close_tab(&self, id: i64, exe: Option<&str>) -> Result<()> {
        if exe == Some(worker::EXE) {
            return worker().command("closeTab", Some(id), json!({})).await.map(|_| ());
        }
        let c = self.front_connection(exe).await.ok_or_else(|| anyhow!("browser extension not connected"))?;
        self.request(c, args(json!({"cmd": "closeTab", "tabId": id})), 3.0).await.map(|_| ())
    }

    /// Reads tab `id` without bringing it forward; commands on the result go to that tab.
    pub async fn snapshot_tab(&self, id: i64, exe: Option<&str>) -> Option<Page> {
        if exe == Some(worker::EXE) {
            return worker().snapshot(Some(id)).await;
        }
        let c = self.front_connection(exe).await?;
        let r = self.request(c, args(json!({"cmd": "snapshot", "tabId": id})), 5.0).await.ok()?;
        let mut p = self.parse(&r, c);
        p.pinned = true;
        Some(p)
    }

    pub async fn reload_all(&self) -> usize {
        let ids: Vec<u64> = self.conns.lock().keys().copied().collect();
        let mut n = 0;
        for c in ids {
            if self.request(c, args(json!({"cmd": "reload"})), 5.0).await.is_ok() {
                n += 1;
            }
        }
        n
    }

    /// Debug: every connected browser's answer to a snapshot.
    pub async fn debug_snapshots(&self) -> Vec<String> {
        let ids: Vec<(u64, Option<String>)> = self.conns.lock().iter().map(|(k, c)| (*k, c.owner.clone())).collect();
        let mut out = vec![];
        for (c, owner) in ids {
            let v = self.request(c, args(json!({"cmd": "version"})), 3.0).await.ok();
            match self.request(c, args(json!({"cmd": "snapshot"})), 5.0).await {
                Ok(r) => out.push(format!(
                    "{} v{} focused={} url={} elements={}",
                    owner.unwrap_or_else(|| "?".into()),
                    v.as_ref().and_then(|v| v["version"].as_str()).unwrap_or("?"),
                    r["focused"],
                    r["url"].as_str().unwrap_or("-"),
                    r["elements"].as_array().map(|a| a.len() as i64).unwrap_or(-1)
                )),
                Err(e) => out.push(format!("error: {e}")),
            }
        }
        out
    }
}

/// "tab 123 (active): Title — url", "(opened by you)" where it's Clinqy's.
pub fn describe_tabs(tabs: &[BrowserTab]) -> String {
    tabs.iter()
        .map(|t| {
            format!(
                "tab {}{}{}: {} — {}",
                t.id,
                if t.active { " (active)" } else { "" },
                if t.opened { " (opened by you)" } else { "" },
                t.title.chars().take(80).collect::<String>(),
                t.url.chars().take(120).collect::<String>()
            )
        })
        .collect::<Vec<_>>()
        .join("\n")
}
