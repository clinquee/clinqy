//! ClinqyApp: the tray icon, the command bar, the status island, and everything that wires the agent to them — the
//! hotkey (tap to open, hold to talk), the IPC pipe for the `clinqy` command, schedules and reminders.

use crate::ui::{Bar, Dashboard, Island, LiveView, ResultPanel};
use clinqy_core::agent::{Context, Copied, Event as AgentEvent, RunOptions};
use clinqy_core::platform::{Mood, Platform};
use clinqy_core::provider::Provider;
use clinqy_core::{bridge, history, workflow, Agent};
use clinqy_windows::hotkey::{self, HotEvent, TaskKey};
use clinqy_windows::{Overlay, WindowsPlatform};
use parking_lot::Mutex;
use serde_json::{json, Value};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tao::event::{Event, StartCause, WindowEvent};
use tao::event_loop::{ControlFlow, EventLoopBuilder, EventLoopProxy};
use tokio::sync::broadcast;
use tray_icon::menu::{CheckMenuItem, Menu, MenuEvent, MenuItem, PredefinedMenuItem, Submenu};
use tray_icon::{TrayIconBuilder, TrayIconEvent};

#[derive(Debug, Clone)]
pub enum UserEvent {
    Agent(AgentEvent),
    Hot(HotEvent),
    Bar(String),
    Result(String),
    Dashboard(String),
    Live(String),
    LiveFrame(String),
    BadgeClick,
    /// The models a provider offers: (provider id, choices, the saved one).
    Models(String, Vec<clinqy_core::models::Choice>, String),
    /// A line for the Clinqy window's status.
    Status(String),
    /// A notice card's time is up (its number, so a newer card stays).
    HideCard(u64),
    Menu(String),
    TrayClick,
    ShowBar,
    Notice(String),
    /// A newer version is out.
    UpdateAvailable(String),
    BarBlur,
    VoiceLevel(f32),
    VoiceText(String, bool),
    /// The loop the user drew with "Circle" (None: cancelled).
    Circled(Option<Vec<clinqy_core::platform::Point>>),
    Quit,
}

/// What the IPC server and other background parts need from the app.
pub struct Shared {
    pub agent: Arc<Agent>,
    pub platform: Arc<WindowsPlatform>,
    pub events: broadcast::Sender<AgentEvent>,
    pub proxy: Mutex<EventLoopProxy<UserEvent>>,
    pub voice: crate::voice::Voice,
}

impl Shared {
    pub fn send(&self, e: UserEvent) {
        let _ = self.proxy.lock().send_event(e);
    }
}

/// The clipboard's latest change (for "this" meaning what was just copied).
#[derive(Default, Clone)]
struct ClipState {
    seq: u32,
    at: Option<Instant>,
    text: Option<String>,
    files: Vec<std::path::PathBuf>,
}

pub fn run() -> anyhow::Result<()> {
    clinqy_windows::init_process();
    clinqy_windows::com::mark_ui_thread();
    let rt = tokio::runtime::Builder::new_multi_thread().enable_all().thread_name("clinqy-rt").build()?;
    let _guard = rt.enter();

    let event_loop = EventLoopBuilder::<UserEvent>::with_user_event().build();
    let proxy = event_loop.create_proxy();

    let overlay = Arc::new(Overlay::start());
    let platform = Arc::new(WindowsPlatform::new(overlay.clone()));
    let (events, _) = broadcast::channel::<AgentEvent>(512);
    let ev_tx = events.clone();
    let p2 = proxy.clone();
    let agent = Agent::new(platform.clone(), overlay.clone(), move |e| {
        let _ = ev_tx.send(e.clone());
        // Here, not on the UI thread: the pause and stop keys can't wait for it to get to this.
        match &e {
            AgentEvent::Changed(run) => hotkey::set_task_mode(match (run.running, run.background) {
                (false, _) => hotkey::TaskMode::Off,
                (true, false) => hotkey::TaskMode::Foreground,
                (true, true) => hotkey::TaskMode::Background,
            }),
            AgentEvent::Finished { .. } => hotkey::set_task_mode(hotkey::TaskMode::Off),
            _ => {}
        }
        let _ = p2.send_event(UserEvent::Agent(e));
    });
    let p3 = proxy.clone();
    let voice = crate::voice::Voice::new(
        Box::new({
            let p = proxy.clone();
            move |l| {
                let _ = p.send_event(UserEvent::VoiceLevel(l));
            }
        }),
        Box::new(move |text, done| {
            let _ = p3.send_event(UserEvent::VoiceText(text, done));
        }),
    );
    let shared = Arc::new(Shared { agent: agent.clone(), platform: platform.clone(), events, proxy: Mutex::new(proxy.clone()), voice });
    let _ = crate::ipc::token();

    // The browser extension's bridge, and which browser each connection belongs to.
    bridge::bridge().set_owner_lookup(Box::new(clinqy_windows::system::owner_of_port));
    rt.spawn(async {
        if let Err(e) = bridge::bridge().start().await {
            clinqy_core::log::write(&format!("{e}"));
        }
    });
    rt.spawn(crate::server::serve(shared.clone()));
    agent.prewarm();

    // The summon chord (tap to open the bar) and push-to-talk (hold to speak, let go to send).
    let hk = clinqy_core::config::value("HOTKEY").unwrap_or_else(|| "ctrl+alt".into());
    let hotkey_label = hotkey::label(&hk);
    let talk = clinqy_core::config::value("TALK_HOTKEY").unwrap_or_else(|| "ctrl+h".into());
    let talk_label = hotkey::talk_label(&talk);
    {
        let p = proxy.clone();
        hotkey::set_task_keys(
            &clinqy_core::config::value("PAUSE_HOTKEY").unwrap_or_else(|| "ctrl+p".into()),
            &clinqy_core::config::value("STOP_HOTKEY").unwrap_or_else(|| "ctrl+s".into()),
        );
        hotkey::start(&hk, &talk, move |e| {
            let _ = p.send_event(UserEvent::Hot(e));
        });
    }

    // Tray.
    let menu = Menu::new();
    let item = |id: &str, text: &str| MenuItem::with_id(id, text, true, None);
    let pause = MenuItem::with_id("pause", "Pause the current task", true, None);
    let open_item = item("open", &format!("Open Clinqy\t{hotkey_label}"));
    let bg_item = CheckMenuItem::with_id("background", "Work in the background", true, clinqy_core::background::always(), None);
    let dry = CheckMenuItem::with_id("dry", "Dry run (show, don't do)", true, false, None);
    let login = CheckMenuItem::with_id("login", "Open at login", true, crate::setup::starts_at_login(), None);
    // Voice language: what Whisper listens for (saved as VOICE_LANGUAGE in the settings file).
    let current = crate::voice::language_setting();
    let languages: Vec<CheckMenuItem> = crate::voice::LANGUAGES
        .iter()
        .map(|(code, label)| CheckMenuItem::with_id(format!("lang:{code}"), *label, true, current == *code, None))
        .collect();
    // Model: the CLIs people log in with, one click each (checked with a quick question); keys go in Settings.
    let auto = crate::onboard::is_auto();
    let now = crate::onboard::short_name(clinqy_core::provider::Provider::current());
    let mut models: Vec<CheckMenuItem> = vec![CheckMenuItem::with_id("model:auto", "Automatic (what you have)", true, auto, None)];
    models.extend(
        crate::onboard::MODELS.iter().filter(|m| m.1.is_cli())
            .map(|(name, _, what)| CheckMenuItem::with_id(format!("model:{name}"), *what, true, !auto && now == *name, None)),
    );
    let model_menu = Submenu::with_id("model", "Model", true);
    for m in &models {
        let _ = model_menu.append(m);
    }
    let _ = model_menu.append(&PredefinedMenuItem::separator());
    let _ = model_menu.append(&MenuItem::with_id("model:keys", "An API key or a local model…", true, None));
    let _ = model_menu.append(&MenuItem::with_id("model:test", "Check the model works", true, None));
    let voice_menu = Submenu::with_id("voice", "Voice language", true);
    for l in &languages {
        let _ = voice_menu.append(l);
    }
    let _ = menu.append_items(&[
        &open_item,
        &item("dashboard", "Dashboard…"),
        &bg_item,
        &item("live", "Show background work"),
        &pause,
        &item("stop", "Stop the current task"),
        &PredefinedMenuItem::separator(),
        &item("circle", "Circle something…"),
        &item("watch", "Watch && learn…"),
        &item("history", "History"),
        &item("applications", "Applications…"),
        &item("stats", "Stats…"),
        &PredefinedMenuItem::separator(),
        &item("memory", "Edit memory…"),
        &item("profile", "Job profile…"),
        &item("settings", "Settings (model, keys)…"),
        &item("extension", "Browser extension…"),
        &item("check", "Check setup…"),
        &model_menu,
        &voice_menu,
        &dry,
        &login,
        &PredefinedMenuItem::separator(),
        &item("quit", "Quit Clinqy"),
    ]);
    let icon = {
        let img = image::load_from_memory(include_bytes!("../../../assets/tray.png"))?.to_rgba8();
        let (w, h) = img.dimensions();
        tray_icon::Icon::from_rgba(img.into_raw(), w, h)?
    };
    let _tray = TrayIconBuilder::new().with_menu(Box::new(menu)).with_tooltip(format!("Clinqy — {hotkey_label} to open")).with_icon(icon).build()?;
    {
        let p = proxy.clone();
        MenuEvent::set_event_handler(Some(move |e: MenuEvent| {
            let _ = p.send_event(UserEvent::Menu(e.id.0.clone()));
        }));
        let p = proxy.clone();
        TrayIconEvent::set_event_handler(Some(move |e: TrayIconEvent| {
            if let TrayIconEvent::Click { button: tray_icon::MouseButton::Left, button_state: tray_icon::MouseButtonState::Up, .. } = e {
                let _ = p.send_event(UserEvent::TrayClick);
            }
        }));
    }

    let bar = Bar::new(&event_loop, proxy.clone())?;
    let island = Island::new();
    let result = ResultPanel::new(&event_loop, proxy.clone())?;
    let dashboard = Dashboard::new(&event_loop, proxy.clone())?;
    let live = LiveView::new(&event_loop, proxy.clone())?;
    let badge = {
        let p = proxy.clone();
        clinqy_windows::badge::Badge::start(move || {
            let _ = p.send_event(UserEvent::BadgeClick);
        })
    };

    // The clipboard's recent history, for "this" when nothing is selected.
    let clip = Arc::new(Mutex::new(ClipState::default()));
    {
        let clip = clip.clone();
        let platform = platform.clone();
        std::thread::spawn(move || loop {
            std::thread::sleep(Duration::from_millis(900));
            let seq = platform.clipboard_sequence();
            let mut c = clip.lock();
            if seq != c.seq {
                let first = c.seq == 0;
                c.seq = seq;
                if !first {
                    c.at = Some(Instant::now());
                    c.text = platform.clipboard_text().filter(|t| !t.trim().is_empty() && t.len() < 20_000);
                    c.files = platform.clipboard_files();
                }
            }
        });
    }

    // Schedules, daily workflows and reminders.
    {
        let shared = shared.clone();
        rt.spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(20)).await;
                for r in clinqy_core::scheduler::due_reminders() {
                    shared.send(UserEvent::Notice(format!("⏰ {}{}", r.title, r.notes.map(|n| format!(" — {n}")).unwrap_or_default())));
                }
                if shared.agent.is_running() {
                    continue;
                }
                if let Some(item) = clinqy_core::scheduler::take_due() {
                    clinqy_core::log::write(&format!("scheduled run: {}", item.request));
                    shared.agent.submit(&item.request, RunOptions::default());
                    continue;
                }
                let hm = chrono::Local::now().format("%H:%M").to_string();
                let today = chrono::Local::now().format("%Y-%m-%d").to_string();
                for mut wf in workflow::workflows().all() {
                    if wf.schedule.as_deref() == Some(hm.as_str()) && !wf.last_scheduled_run.as_deref().map(|d| d.starts_with(&today)).unwrap_or(false) {
                        wf.last_scheduled_run = Some(chrono::Local::now().to_rfc3339());
                        workflow::workflows().update(wf.clone());
                        shared.agent.run_workflow(&wf.name, Default::default());
                        break;
                    }
                }
            }
        });
    }

    let mut ui = UiState {
        shared: shared.clone(),
        bar,
        island,
        result,
        dashboard,
        live,
        badge,
        bg_item,
        tray: _tray,
        live_on: Arc::new(std::sync::atomic::AtomicBool::new(false)),
        card_id: 0,
        question_card: false,
        pending_page: None,
        dashboard_ready: false,
        open_item,
        island_on: false,
        notice: None,
        dry,
        languages,
        models,
        login,
        clip,
        hotkey_label,
        talk_label,
        talk_key: talk.clone(),
        talk_started: None,
        pause,
        voice_run: false,
        tab: "home".into(),
        island_until: None,
        follow_up: false,
        dashboard_range: "month".into(),
        dashboard_status: String::new(),
        run_provider: Provider::current(),
    };
    let proxy_for_loop = proxy.clone();
    event_loop.run(move |event, _target, control_flow| {
        *control_flow = match ui.island_until {
            Some(t) => ControlFlow::WaitUntil(t),
            None => ControlFlow::Wait,
        };
        match event {
            Event::NewEvents(StartCause::Init) => {
                std::thread::spawn(crate::setup::register_links);
                let updates = proxy_for_loop.clone();
                std::thread::spawn(move || {
                    // After the `clinqy` that restarted this app has exited, so its old file can go.
                    std::thread::sleep(Duration::from_secs(20));
                    crate::update::remove_old_files();
                    if clinqy_core::config::on("UPDATE_CHECK", true) {
                        if let Some(version) = crate::update::available() {
                            let _ = updates.send_event(UserEvent::UpdateAvailable(version));
                        }
                    }
                });
                if crate::setup::first_run() {
                    ui.show_dashboard("setup");
                } else if !std::env::args().any(|a| a == "--login") {
                    // Opened by the user (Windows Search, the Start menu), not at sign-in: show it.
                    let _ = proxy_for_loop.send_event(UserEvent::ShowBar);
                }
            }
            Event::NewEvents(StartCause::ResumeTimeReached { .. }) => {
                if ui.island_until.map(|t| Instant::now() >= t).unwrap_or(false) {
                    ui.island_until = None;
                    ui.notice = None;
                    if !ui.shared.agent.is_running() && !ui.shared.voice.is_listening() && !crate::recorder::is_recording() {
                        ui.island_on = false;
                        ui.island.hide();
                    } else {
                        ui.refresh_island();
                    }
                }
            }
            Event::UserEvent(e) => {
                if let UserEvent::Quit = e {
                    *control_flow = ControlFlow::Exit;
                    return;
                }
                ui.handle(e);
            }
            Event::WindowEvent { window_id, event: WindowEvent::Focused(false), .. } if window_id == ui.bar.window.id() => {
                // Clicking elsewhere puts the bar away, like Spotlight (not while it's asking something).
                // WebView2's own window taking the keyboard also blurs the bar, so check what's really in front.
                let p = proxy_for_loop.clone();
                tokio::spawn(async move {
                    tokio::time::sleep(Duration::from_millis(120)).await;
                    let _ = p.send_event(UserEvent::BarBlur);
                });
            }
            Event::WindowEvent { window_id, event: WindowEvent::CloseRequested, .. } if window_id == ui.dashboard.window.id() => {
                hotkey::set_enabled(true);
                ui.dashboard.hide();
            }
            Event::WindowEvent { window_id, event: WindowEvent::CloseRequested, .. } if window_id == ui.live.window.id() => {
                ui.live_on.store(false, std::sync::atomic::Ordering::Relaxed);
                ui.live.hide();
            }
            _ => {}
        }
    });
}

struct UiState {
    shared: Arc<Shared>,
    bar: Bar,
    island: Island,
    result: ResultPanel,
    dashboard: Dashboard,
    live: LiveView,
    badge: clinqy_windows::badge::Badge,
    bg_item: CheckMenuItem,
    tray: tray_icon::TrayIcon,
    /// The live view is open: frames keep coming.
    live_on: Arc<std::sync::atomic::AtomicBool>,
    card_id: u64,
    /// The result card is showing a question, so an answer from anywhere takes it down.
    question_card: bool,
    /// Where the Clinqy window goes once its page has loaded.
    pending_page: Option<String>,
    dashboard_ready: bool,
    open_item: MenuItem,
    island_on: bool,
    notice: Option<String>,
    dry: CheckMenuItem,
    languages: Vec<CheckMenuItem>,
    models: Vec<CheckMenuItem>,
    login: CheckMenuItem,
    clip: Arc<Mutex<ClipState>>,
    hotkey_label: String,
    /// Push-to-talk's key, for hints ("Ctrl+H"); empty when it's off.
    talk_label: String,
    talk_key: String,
    /// When push-to-talk went down (a quick tap is passed on to the app as its own shortcut).
    talk_started: Option<Instant>,
    pause: MenuItem,
    voice_run: bool,
    tab: String,
    island_until: Option<Instant>,
    follow_up: bool,
    dashboard_range: String,
    dashboard_status: String,
    /// One-run model choice from the command bar; the saved dashboard provider remains the default.
    run_provider: Provider,
}

impl UiState {
    fn agent(&self) -> &Arc<Agent> {
        &self.shared.agent
    }

    fn extras(&self) -> Value {
        let hist: Vec<Value> = history::history()
            .entries()
            .iter()
            .take(40)
            .map(|h| json!({"id": h.id, "date": h.date, "request": h.request, "answer": h.answer, "ok": h.ok, "result": h.result.is_some(), "trace": h.trace.as_ref().map(|t| !t.is_empty()).unwrap_or(false)}))
            .collect();
        let wfs: Vec<Value> = workflow::workflows().all().iter().map(|w| json!({"id": w.id, "name": w.name, "steps": w.steps.len(), "runs": w.runs, "schedule": w.schedule, "params": w.params})).collect();
        let skills: Vec<Value> = clinqy_core::skills::all().iter().map(|s| json!({"id": s.id, "name": s.name, "summary": s.summary, "parameters": s.parameters, "steps": s.steps})).collect();
        let provider = clinqy_core::provider::Provider::current();
        let providers: Vec<Value> = Provider::ALL.iter().filter(|p| p.is_configured())
            .map(|p| json!({"id": p.id(), "name": p.display_name()})).collect();
        let ctx = self.agent().context.lock().clone();
        let name = |p: &std::path::Path| p.file_name().map(|f| f.to_string_lossy().into_owned()).unwrap_or_else(|| p.display().to_string());
        let copied = ctx.copied.as_ref().map(|c| {
            let what = c.text.as_ref().map(|t| format!("“{}”", t.chars().take(60).collect::<String>().replace(char::is_control, " "))).unwrap_or_else(|| c.files.iter().map(|f| name(f)).collect::<Vec<_>>().join(", "));
            format!("{what} · {}", if c.age_secs < 60 { "just now".to_string() } else { format!("{} min ago", c.age_secs / 60) })
        });
        let context = json!({
            "continuing": ctx.continuation.as_ref().map(|c| c.request.clone()),
            "selected": ctx.selected_text,
            "files": ctx.selected_files.iter().map(|f| name(f)).collect::<Vec<_>>(),
            "copied": copied,
            "circled": ctx.circled.as_deref().map(clinqy_core::agent::circle_bounds).map(|r| format!("{}×{}", r.w as i64, r.h as i64)),
        });
        let transcript = self.shared.voice.transcript();
        json!({
            "context": context, "recording": crate::recorder::is_recording(), "learning": crate::recorder::is_learning(),
            "transcribing": transcript == "Transcribing…",
            "snap": self.agent().snapshot(),
            "history": hist, "workflows": wfs, "skills": skills,
            "listening": self.shared.voice.is_listening(), "transcript": if transcript == "Transcribing…" { String::new() } else { transcript },
            "backgroundMode": clinqy_core::background::always(),
            "hotkey": self.hotkey_label, "talkKey": self.talk_label, "model": format!("{} · {}", provider.id(), provider.default_model()),
            "providers": providers, "runProvider": self.run_provider.id(),
        })
    }

    fn refresh_bar(&self) {
        if self.bar.visible() {
            self.bar.update(&self.extras());
        }
    }

    fn refresh_island(&self) {
        let mut v = serde_json::to_value(self.agent().snapshot()).unwrap_or_default();
        v["listening"] = json!(self.shared.voice.is_listening());
        let t = self.shared.voice.transcript();
        v["transcribing"] = json!(t == "Transcribing…");
        v["transcript"] = json!(if t == "Transcribing…" { String::new() } else { t });
        v["followUp"] = json!(self.follow_up);
        v["recording"] = json!(crate::recorder::is_recording());
        v["hotkey"] = json!(self.hotkey_label);
        v["talkKey"] = json!(self.talk_label);
        if let Some(n) = &self.notice {
            v["notice"] = json!(n);
        }
        self.island.update(&v, self.island_on);
    }

    /// Notes what the user was looking at (the app, selected text, files, a recent copy) before the bar opens.
    fn capture_context_then_show(&self) {
        let agent = self.agent().clone();
        if agent.question().is_some() || agent.is_running() {
            self.shared.send(UserEvent::ShowBar);
            return;
        }
        let platform = self.shared.platform.clone();
        let clip = self.clip.lock().clone();
        let shared = self.shared.clone();
        tokio::spawn(async move {
            let target = platform.front_app();
            let mut ctx = Context { target: target.clone(), ..Default::default() };
            if let Some(t) = &target {
                if t.exe == "explorer.exe" {
                    // Files selected in File Explorer ride along ("compress this", "merge these").
                    let before = platform.clipboard_sequence();
                    let saved = platform.clipboard_text();
                    platform.set_target(Some(t));
                    let _ = platform.press("ctrl+c");
                    platform.set_target(None);
                    tokio::time::sleep(Duration::from_millis(150)).await;
                    if platform.clipboard_sequence() != before {
                        ctx.selected_files = platform.clipboard_files();
                        if let Some(s) = saved {
                            platform.set_clipboard_text(&s);
                        }
                    }
                }
                if ctx.selected_files.is_empty() {
                    ctx.selected_text = if platform.is_browser(t) && bridge::bridge().is_connected() {
                        bridge::bridge().selection(Some(&t.exe)).await
                    } else {
                        platform.selected_text(t).await
                    };
                }
            }
            if ctx.selected_text.is_none() && ctx.selected_files.is_empty() {
                if let Some(at) = clip.at.filter(|a| a.elapsed() < Duration::from_secs(600)) {
                    ctx.copied = Some(Copied { text: clip.text.clone(), files: clip.files.clone(), age_secs: at.elapsed().as_secs() });
                }
            }
            let keep_continuation = shared.agent.context.lock().continuation.clone();
            ctx.continuation = keep_continuation;
            *shared.agent.context.lock() = ctx;
            shared.send(UserEvent::ShowBar);
        });
    }

    /// Hides the bar, lets the user draw a loop around something, then brings the bar back with it attached.
    fn start_circling(&mut self) {
        self.bar.hide();
        let shared = self.shared.clone();
        let platform = self.shared.platform.clone();
        tokio::spawn(async move {
            if shared.agent.context.lock().target.is_none() {
                shared.agent.context.lock().target = platform.front_app();
            }
            let points = tokio::task::spawn_blocking(clinqy_windows::circle::pick).await.ok().flatten();
            shared.send(UserEvent::Circled(points));
        });
    }

    fn show_bar(&mut self) {
        if !self.agent().is_running() && self.agent().question().is_none() {
            self.run_provider = Provider::current();
        }
        self.bar.show(&self.extras());
    }

    fn submit(&mut self, text: &str, voice: bool) {
        self.voice_run = voice;
        let provider = self.run_provider;
        self.run_provider = Provider::current();
        self.bar.hide();
        self.bar.clear();
        let target = self.agent().context.lock().target.clone();
        let platform = self.shared.platform.clone();
        let agent = self.agent().clone();
        let text = text.to_string();
        tokio::spawn(async move {
            // The app the user was in comes back to the front first: keys and clicks go there.
            if let Some(t) = target {
                platform.bring_to_front(&t).await;
            }
            agent.submit(&text, RunOptions { provider: Some(provider), ..Default::default() });
        });
    }

    fn start_listening(&mut self) {
        let a = self.agent().clone();
        if !a.is_running() && a.question().is_none() {
            // Context for a spoken request is captured at the start, while the user's app is in front.
            self.capture_context_silently();
        }
        self.shared.voice.start();
        self.shared.agent.buddy.set_mood(Mood::Listening);
        a.set_listening(true);
        self.island_until = None;
        self.island_on = true;
        self.refresh_island();
    }

    fn capture_context_silently(&self) {
        let platform = self.shared.platform.clone();
        let shared = self.shared.clone();
        tokio::spawn(async move {
            let target = platform.front_app();
            let mut ctx = shared.agent.context.lock().clone();
            ctx.target = target;
            *shared.agent.context.lock() = ctx;
        });
    }

    fn handle(&mut self, e: UserEvent) {
        match e {
            UserEvent::Agent(ev) => self.on_agent(ev),
            UserEvent::Hot(h) => self.on_hotkey(h),
            UserEvent::ShowBar => self.show_bar(),
            UserEvent::TrayClick => {
                if self.agent().snapshot().background {
                    // Out of sight: show it, with Pause and Stop there.
                    self.show_live();
                } else if self.agent().is_running() {
                    self.agent().cancel();
                } else if self.bar.visible() {
                    self.bar.hide();
                } else {
                    self.capture_context_then_show();
                }
            }
            UserEvent::Bar(msg) => self.on_bar(&msg),
            UserEvent::Dashboard(msg) => self.on_dashboard(&msg),
            UserEvent::Live(msg) => self.on_live(&msg),
            UserEvent::LiveFrame(jpeg) => {
                self.live.frame(&jpeg);
                self.refresh_live();
            }
            UserEvent::BadgeClick => self.show_live(),
            UserEvent::Models(provider, choices, saved) => {
                self.dashboard.call(&format!("models({}, {}, {})", json!(provider), json!(choices), json!(saved)));
            }
            UserEvent::Status(text) => {
                self.dashboard_status = text;
                self.refresh_dashboard();
            }
            UserEvent::HideCard(id) => {
                if id == self.card_id {
                    self.result.hide();
                }
            }
            UserEvent::BarBlur => {
                let s = self.agent().snapshot();
                if self.bar.visible() && !self.bar.has_focus() && s.question.is_none() && s.review.is_none() && !self.shared.voice.is_listening() {
                    self.bar.hide();
                }
            }
            UserEvent::Result(msg) => self.on_result(&msg),
            UserEvent::Circled(points) => {
                let agent = self.agent().clone();
                let target = agent.context.lock().target.clone();
                // The user's app comes back to the front first (keys and clicks go there), then the bar over it.
                let reopen = !agent.is_running();
                if let Some(t) = target {
                    let p = self.shared.platform.clone();
                    let shared = self.shared.clone();
                    tokio::spawn(async move {
                        p.bring_to_front(&t).await;
                        if reopen {
                            shared.send(UserEvent::ShowBar);
                        }
                    });
                } else if reopen {
                    self.shared.send(UserEvent::ShowBar);
                }
                match points {
                    // While a task runs, the circle goes in as added context instead.
                    Some(pts) if agent.is_running() => {
                        let r = clinqy_core::agent::circle_bounds(&pts);
                        agent.add_context(&format!("I circled this area of the screen: x {}–{}, y {}–{} (screen pixels).", r.x as i64, r.max_x() as i64, r.y as i64, r.max_y() as i64));
                    }
                    Some(pts) => agent.context.lock().circled = Some(pts),
                    None => {}
                }
            }
            UserEvent::Menu(id) => self.on_menu(&id),
            UserEvent::UpdateAvailable(version) => {
                if !self.agent().is_running() {
                    let text = "Updating takes a few seconds and keeps your settings, memory and history.";
                    self.notice_card(&format!("Clinqy {version} is available"), text, json!([["Update now", "__update"], ["Later", "__later"]]), 30);
                }
            }
            UserEvent::Notice(text) => {
                crate::setup::beep();
                self.notice = Some(text);
                self.island_on = true;
                self.refresh_island();
                self.island_until = Some(Instant::now() + Duration::from_secs(8));
            }
            UserEvent::VoiceLevel(l) => {
                self.shared.agent.buddy.set_level(l);
                self.island.level(l);
                self.bar.level(l);
            }
            UserEvent::VoiceText(text, done) => {
                if !done {
                    self.refresh_island();
                    self.refresh_bar();
                    return;
                }
                self.agent().set_listening(false);
                self.shared.agent.buddy.set_mood(if self.agent().is_running() { Mood::Acting } else { Mood::Idle });
                let follow = std::mem::take(&mut self.follow_up);
                let text = text.trim().to_string();
                if text.is_empty() {
                    if !self.agent().is_running() {
                        self.island_on = false;
                        self.island.hide();
                    }
                    return;
                }
                let a = self.agent().clone();
                if a.question().is_some() || a.snapshot().review.is_some() {
                    a.answer(Some(text));
                } else if a.is_running() {
                    a.add_context(&text);
                } else if follow && workflow::is_dismissal(&text) {
                    a.context.lock().continuation = None;
                    self.island_on = false;
                    self.island.hide();
                } else {
                    self.submit(&text, true);
                }
            }
            UserEvent::Quit => {}
        }
    }

    fn dashboard_state(&self) -> Value {
        use clinqy_core::provider::Provider;
        use clinqy_core::taskstore::{tasks, State};
        let current = Provider::current();
        let range = match self.dashboard_range.as_str() {
            "thirtyDays" => "thirtyDays",
            "all" => "all",
            _ => "month",
        };
        let summary = clinqy_core::usage::summary(range);
        let monthly = clinqy_core::usage::summary("month");
        let providers = summary.providers.iter().map(|p| {
            let display = Provider::parse(&p.provider).map(Provider::display_name).unwrap_or("Unknown provider");
            json!({"provider": p.provider, "providerName": display, "requests": p.requests, "inputTokens": p.input_tokens, "outputTokens": p.output_tokens, "meteredRequests": p.metered_requests})
        }).collect::<Vec<_>>();
        let summary = json!({
            "requests": summary.requests, "inputTokens": summary.input_tokens, "outputTokens": summary.output_tokens,
            "meteredRequests": summary.metered_requests, "providers": providers, "days": summary.days,
        });
        let summon = clinqy_core::config::value("HOTKEY").unwrap_or_else(|| "ctrl+alt".into());
        let talk = clinqy_core::config::value("TALK_HOTKEY").unwrap_or_else(|| "ctrl+h".into());
        let talk_label = if ["off", "none", "disabled"].contains(&talk.to_lowercase().as_str()) { "Off".to_string() } else { hotkey::talk_label(&talk) };
        let browser = clinqy_core::worker::find_browser();
        let worker = clinqy_core::worker::worker();
        let snapshot = self.agent().snapshot();
        let task_rows = tasks().records().iter().rev().take(50).map(|t| {
            let when = chrono::DateTime::parse_from_rfc3339(&t.created_at).map(|d| d.with_timezone(&chrono::Local).format("%-d %b, %H:%M").to_string()).unwrap_or_default();
            json!({
                "id": t.id, "shortId": t.short_id(), "request": t.request, "state": t.state.label(), "background": t.background, "stage": t.stage,
                "steps": t.completed_steps, "lastStep": t.last_confirmed_step, "pending": t.pending_action, "result": t.result, "reason": t.review_reason, "when": when,
            })
        }).collect::<Vec<_>>();
        json!({
            "range": range,
            "rangeLabel": match range { "month" => "This month", "thirtyDays" => "Last 30 days", _ => "All time" },
            "summary": summary,
            "monthlySummary": { "requests": monthly.requests, "inputTokens": monthly.input_tokens, "outputTokens": monthly.output_tokens, "meteredRequests": monthly.metered_requests },
            "currentProvider": current.id(),
            "currentProviderName": current.display_name(),
            "model": crate::onboard::model_label(current),
            "auto": crate::onboard::is_auto(),
            "providerManaged": Provider::managed_by_environment(),
            "delegateProvider": clinqy_core::config::value("DELEGATE_PROVIDER").unwrap_or_else(|| "auto".into()),
            "routingManaged": std::env::var_os("DELEGATE_PROVIDER").is_some(),
            "providers": crate::onboard::MODELS.iter().map(|m| crate::onboard::provider_info(m.1)).collect::<Vec<_>>(),
            "baseUrl": clinqy_core::config::value("OPENAI_BASE_URL").unwrap_or_default(),
            "tokenLimit": clinqy_core::config::value("MONTHLY_TOKEN_LIMIT").unwrap_or_default(),
            "requestLimit": clinqy_core::config::value("MONTHLY_REQUEST_LIMIT").unwrap_or_default(),
            "summonSpec": summon,
            "summonLabel": hotkey::label(&summon),
            "talkSpec": if talk_label == "Off" { "off" } else { talk.as_str() },
            "talkLabel": talk_label,
            "hotkeysManaged": std::env::var_os("HOTKEY").is_some() || std::env::var_os("TALK_HOTKEY").is_some(),
            "status": self.dashboard_status,
            "background": {
                "always": clinqy_core::background::always(),
                "managed": std::env::var_os("BACKGROUND_TASKS").is_some(),
                "browser": browser.as_deref().map(clinqy_core::worker::browser_name),
                "signingIn": worker.in_login(),
                "ownBrowser": clinqy_core::worker::in_own_browser(),
                "profile": clinqy_core::config::value("WORKER_PROFILE").unwrap_or_default(),
                "profileUsed": worker.profile().display().to_string(),
                "running": worker.connected(),
                "busy": snapshot.running,
                "hasView": snapshot.background || worker.has_tab(),
            },
            "tasks": task_rows,
            "taskError": tasks().error(),
            "taskActive": tasks().active().is_some() || tasks().records().iter().any(|t| t.state == State::Running),
            "extension": { "connected": bridge::bridge().is_connected(), "browser": clinqy_windows::apps::default_browser() },
            "agents": crate::onboard::AGENT_ROWS.iter().map(|(id, name, detail)| json!({"id": id, "name": name, "detail": detail})).collect::<Vec<_>>(),
            "general": {
                "login": crate::setup::starts_at_login(),
                "followUp": clinqy_core::config::on("FOLLOW_UP", false),
                "language": crate::voice::language_setting(),
                "voiceEngine": crate::voice::engine(),
                "languages": crate::voice::LANGUAGES,
            },
        })
    }

    fn show_dashboard(&mut self, page: &str) {
        self.dashboard_range = "month".into();
        self.dashboard_status.clear();
        self.dashboard.present(&self.dashboard_state());
        if self.dashboard_ready {
            self.dashboard.show_page(page);
        } else {
            self.pending_page = Some(page.to_string());
        }
    }

    fn refresh_dashboard(&self) {
        if self.dashboard.visible() {
            self.dashboard.update(&self.dashboard_state());
        }
    }

    fn set_status(&mut self, text: impl Into<String>) {
        self.dashboard_status = text.into();
        self.refresh_dashboard();
    }

    /// Asks the provider what it offers, and has it answer whether it works; slow, so off the UI thread.
    fn load_models(&self, provider: clinqy_core::provider::Provider) {
        let shared = self.shared.clone();
        tokio::spawn(async move {
            let choices = clinqy_core::models::list(provider).await;
            shared.send(UserEvent::Models(provider.id().to_string(), choices, clinqy_core::models::saved(provider)));
        });
    }

    fn test_model(&mut self, provider: clinqy_core::provider::Provider) {
        self.set_status(format!("Checking that {} answers…", provider.display_name()));
        let shared = self.shared.clone();
        tokio::spawn(async move {
            let text = match crate::onboard::readiness(provider) {
                Err(fix) => format!("✗ {fix}"),
                Ok(_) => match crate::onboard::test(provider).await {
                    Ok(t) => format!("✓ {} works ({:.1} s).", provider.display_name(), t.as_secs_f64()),
                    Err(e) => format!("✗ {} didn't answer: {e}", provider.display_name()),
                },
            };
            shared.send(UserEvent::Status(text));
        });
    }

    fn on_dashboard(&mut self, raw: &str) {
        use clinqy_core::provider::Provider;
        let Ok(message) = serde_json::from_str::<Value>(raw) else { return };
        let string = |key: &str| message[key].as_str().unwrap_or("").trim().to_string();
        let on = message["on"] == true;
        let provider = Provider::parse(&string("provider"));
        match message["type"].as_str().unwrap_or("") {
            "ready" => {
                self.dashboard_ready = true;
                use base64::Engine;
                let icon = base64::engine::general_purpose::STANDARD.encode(include_bytes!("../../../assets/icon-256.png"));
                self.dashboard.call(&format!("icon(\"data:image/png;base64,{icon}\")"));
                if let Some(page) = self.pending_page.take() {
                    self.dashboard.show_page(&page);
                }
                self.dashboard.update(&self.dashboard_state());
            }
            "refresh" => self.refresh_dashboard(),
            "range" => {
                let range = string("range");
                if ["month", "thirtyDays", "all"].contains(&range.as_str()) {
                    self.dashboard_range = range;
                    self.refresh_dashboard();
                }
            }
            "capture" => hotkey::set_enabled(!message["enabled"].as_bool().unwrap_or(false)),
            "models" => {
                if let Some(p) = provider {
                    self.load_models(p);
                }
            }
            "testModel" => {
                if let Some(p) = provider {
                    self.test_model(p);
                }
            }
            "provider" => {
                if Provider::managed_by_environment() {
                    self.set_status("The provider is set by the environment or launch options.");
                } else if let Some(p) = provider {
                    if !p.is_configured() {
                        self.set_status(format!("Set up {} before switching to it.", p.display_name()));
                    } else {
                        match crate::onboard::choose(p, None) {
                            Ok(()) => {
                                self.agent().prewarm();
                                self.set_status(format!("Using {}.", p.display_name()));
                            }
                            Err(error) => self.set_status(format!("Couldn't save the provider: {error}")),
                        }
                    }
                }
            }
            "auto" => {
                let result = if on { crate::onboard::choose_auto().map(|_| ()) } else { crate::onboard::choose(Provider::current(), None) };
                match result {
                    Ok(()) => {
                        self.agent().prewarm();
                        let now = Provider::current().display_name();
                        self.set_status(if on { format!("Automatic: using {now}.") } else { format!("Using {now}.") });
                    }
                    Err(error) => self.set_status(format!("Couldn't save the provider: {error}")),
                }
            }
            "saveModel" => {
                if let Some(p) = provider {
                    let model = string("model");
                    match clinqy_core::config::set(p.model_key(), &model) {
                        Ok(()) => {
                            self.agent().prewarm();
                            self.set_status(if model.is_empty() { format!("{} will use its default model.", p.display_name()) } else { format!("{} will use {model}.", p.display_name()) });
                        }
                        Err(error) => self.set_status(format!("Couldn't save the model: {error}")),
                    }
                }
            }
            "saveRouting" => {
                if std::env::var_os("DELEGATE_PROVIDER").is_some() {
                    self.set_status("Provider routing is set by environment variables.");
                } else {
                    let raw = string("delegateProvider");
                    let invalid = if raw.is_empty() || raw == "auto" { None } else {
                        match Provider::parse(&raw) {
                            Some(p) if p.is_configured() => None,
                            Some(p) => Some(format!("Set up {} before assigning it to delegated work.", p.display_name())),
                            None => Some(format!("Unknown provider {raw:?}.")),
                        }
                    };
                    if let Some(error) = invalid {
                        self.set_status(error);
                    } else {
                        let saved = clinqy_core::config::set("DELEGATE_PROVIDER", if raw == "auto" { "" } else { &raw });
                        match saved {
                            Ok(()) => {
                                self.set_status("Delegate provider saved. New delegated tasks will use that provider.");
                            }
                            Err(error) => self.set_status(format!("Couldn't save provider routing: {error}")),
                        }
                    }
                }
            }
            "apiKey" => {
                if let Some((p, var)) = provider.and_then(|p| crate::onboard::key_var(p).map(|v| (p, v))) {
                    crate::setup::ensure_env_file();
                    match clinqy_core::config::set(var, &string("key")) {
                        Ok(()) => self.set_status(format!("Saved your {} key on this PC.", p.display_name())),
                        Err(error) => self.set_status(format!("Couldn't save the key: {error}")),
                    }
                }
            }
            "baseUrl" => {
                let _ = clinqy_core::config::set("OPENAI_BASE_URL", &string("url"));
                self.set_status("Saved the server address.");
            }
            "terminal" => {
                // In its own window, so the user can see it and log in.
                let command = string("command");
                let _ = std::process::Command::new("cmd").args(["/c", "start", "", "cmd", "/k", &command]).spawn();
                self.set_status(format!("Running {command} in a new window. Come back when it's done, then Test connection."));
            }
            "open" => {
                let url = string("url");
                if url.starts_with("https://") {
                    self.shared.platform.open_url_direct(&url);
                }
            }
            "limits" => {
                let tokens = string("tokens");
                let requests = string("requests");
                if (!tokens.is_empty() && tokens.parse::<u64>().is_err()) || (!requests.is_empty() && requests.parse::<u64>().is_err()) {
                    self.set_status("Enter a whole number of zero or greater, or leave a limit empty.");
                } else {
                    let saved = clinqy_core::config::set("MONTHLY_TOKEN_LIMIT", &tokens).and_then(|_| clinqy_core::config::set("MONTHLY_REQUEST_LIMIT", &requests));
                    self.set_status(match saved {
                        Ok(()) => "Monthly warning limits saved.".to_string(),
                        Err(error) => format!("Couldn't save limits: {error}"),
                    });
                }
            }
            "shortcuts" => {
                if std::env::var_os("HOTKEY").is_some() || std::env::var_os("TALK_HOTKEY").is_some() {
                    self.set_status("Shortcuts are set by environment variables.");
                } else {
                    let summon = string("summon");
                    let talk = string("talk");
                    let talk = if talk.is_empty() { "off".to_string() } else { talk };
                    if !hotkey::valid_summon(&summon) || !(talk == "off" || hotkey::valid_talk(&talk)) {
                        self.set_status("Summon needs modifier keys. Push to talk needs modifiers and one key.");
                    } else {
                        match clinqy_core::config::set("HOTKEY", &summon).and_then(|_| clinqy_core::config::set("TALK_HOTKEY", &talk)) {
                            Ok(()) => {
                                hotkey::configure(&summon, &talk);
                                self.hotkey_label = hotkey::label(&summon);
                                self.talk_label = hotkey::talk_label(&talk);
                                self.talk_key = if talk == "off" { String::new() } else { talk };
                                self.open_item.set_text(&format!("Open Clinqy\t{}", self.hotkey_label));
                                self.set_status("Shortcuts saved.");
                            }
                            Err(error) => self.set_status(format!("Couldn't save shortcuts: {error}")),
                        }
                    }
                }
            }
            "background" => self.set_background(on),
            "signIn" => {
                self.set_status("Opening the background browser…");
                let shared = self.shared.clone();
                tokio::spawn(async move {
                    let text = match clinqy_core::worker::worker().open_login().await {
                        Ok(()) => "Sign in to your sites in that window, then Finish sign-in here.".to_string(),
                        Err(e) => format!("✗ {e}"),
                    };
                    shared.send(UserEvent::Status(text));
                });
            }
            "backgroundBrowser" => {
                if self.agent().is_running() {
                    return self.set_status("Wait for the background task to finish first.");
                }
                match clinqy_core::config::set("BACKGROUND_BROWSER", if on { "chrome" } else { "" }) {
                    Ok(()) => self.set_status(if on { "Background tasks now work in a Clinqy tab in your browser." } else { "Background tasks now work in the hidden browser." }),
                    Err(e) => self.set_status(format!("✗ Couldn't save it: {e}")),
                }
            }
            "workerProfile" => {
                let folder = string("folder");
                if self.agent().is_running() || clinqy_core::worker::worker().in_login() {
                    return self.set_status("Wait for the background task to finish first.");
                }
                if let Some(problem) = (!folder.is_empty()).then(|| clinqy_core::worker::profile_problem(&folder)).flatten() {
                    return self.set_status(format!("✗ {problem}"));
                }
                let shared = self.shared.clone();
                tokio::spawn(async move {
                    // The browser has to close on the old profile before the setting moves.
                    clinqy_core::worker::worker().stop().await;
                    let text = match clinqy_core::config::set("WORKER_PROFILE", &folder) {
                        Ok(()) if folder.is_empty() => "Background browser: back to Clinqy's own profile.".to_string(),
                        Ok(()) => format!("Background browser: using {folder}. Use Sign in… for sites that need it."),
                        Err(e) => format!("✗ Couldn't save it: {e}"),
                    };
                    shared.send(UserEvent::Status(text));
                });
            }
            "finishLogin" => {
                let shared = self.shared.clone();
                tokio::spawn(async move {
                    clinqy_core::worker::worker().finish_login().await;
                    shared.send(UserEvent::Status("Signed in. Background tasks can use those sites now.".into()));
                });
            }
            "live" => self.show_live(),
            "taskStart" => {
                use clinqy_core::taskstore::tasks;
                let id = string("id");
                if let Some(t) = tasks().record(&id) {
                    if self.agent().is_running() {
                        self.set_status("Wait for the current task to finish first.");
                    } else if t.review_reason.as_deref().unwrap_or("").contains("Private values") {
                        self.set_status("Rewrite that request without secrets first.");
                    } else {
                        tasks().cancel_queued(&id);
                        self.agent().submit(&t.request, RunOptions { background: Some(t.background), ..Default::default() });
                    }
                }
            }
            "taskCancel" => {
                clinqy_core::taskstore::tasks().cancel_queued(&string("id"));
                self.refresh_dashboard();
            }
            "extInstall" => match crate::onboard::extension_task(None) {
                Ok((_, task, _)) => {
                    self.dashboard.hide();
                    self.agent().submit(&task, RunOptions { background: Some(false), ..Default::default() });
                }
                Err(e) => self.set_status(format!("✗ {e}")),
            },
            "extHelp" => crate::setup::show_extension_help(),
            "connect" => {
                let agent = string("agent");
                let text = match crate::onboard::connect(&agent) {
                    Ok(done) => format!("✓ {done}. Restart it to see Clinqy's tools."),
                    Err(e) => format!("✗ {e}"),
                };
                self.set_status(text);
            }
            "login" => {
                crate::setup::set_start_at_login(on);
                self.login.set_checked(crate::setup::starts_at_login());
                self.refresh_dashboard();
            }
            "followUp" => {
                let _ = clinqy_core::config::set("FOLLOW_UP", if on { "on" } else { "" });
                self.refresh_dashboard();
            }
            "voiceEngine" => {
                let engine = string("engine");
                match clinqy_core::config::set("VOICE_ENGINE", if engine == "windows" { "windows" } else { "" }) {
                    Ok(()) => self.set_status("Voice engine saved. It's used from the next time you talk."),
                    Err(e) => self.set_status(format!("✗ Couldn't save it: {e}")),
                }
            }
            "voice" => {
                let code = string("language");
                let _ = clinqy_core::config::set("VOICE_LANGUAGE", &code);
                for (item, (c, _)) in self.languages.iter().zip(crate::voice::LANGUAGES) {
                    item.set_checked(c == code);
                }
                self.refresh_dashboard();
            }
            "memory" => {
                let p = clinqy_core::memory::path();
                if !p.exists() {
                    let _ = std::fs::write(&p, "# What Clinqy remembers about you — one fact per line. Edit freely.\n");
                }
                clinqy_windows::system::shell_open(&p.display().to_string());
            }
            "profile" => {
                let _ = clinqy_core::profile::current();
                clinqy_windows::system::shell_open(&clinqy_core::profile::path().display().to_string());
            }
            "settings" => self.open_settings(),
            "check" => self.agent().show_card(crate::setup::check_card(None)),
            "tryIt" => {
                self.dashboard.hide();
                self.capture_context_then_show();
            }
            "setupDone" => self.refresh_dashboard(),
            _ => {}
        }
    }

    fn set_background(&mut self, on: bool) {
        if std::env::var_os("BACKGROUND_TASKS").is_some() {
            self.bg_item.set_checked(clinqy_core::background::always());
            return self.set_status("Set by BACKGROUND_TASKS in the environment.");
        }
        match clinqy_core::background::set_always(on) {
            Ok(()) => self.dashboard_status.clear(),
            Err(e) => self.dashboard_status = format!("Couldn't save: {e}"),
        }
        self.bg_item.set_checked(clinqy_core::background::always());
        self.refresh_dashboard();
        if on {
            self.notice_card("Background mode on", "Tasks run in a hidden browser while you keep working.", json!([]), 4);
        } else {
            self.notice_card("Background mode off", "Tasks run on your screen, with the blue cursor.", json!([]), 4);
        }
    }

    /// The badge and the tray say what a background run is doing.
    fn sync_background(&self) {
        let s = self.agent().snapshot();
        let tip = if s.background {
            self.badge.set(Some(if s.question.is_some() || s.review.is_some() { "Clinqy needs you".to_string() } else if s.paused { "Paused in background".to_string() } else { "Working in background".to_string() }));
            "Clinqy is working in the background".to_string()
        } else {
            self.badge.set(None);
            format!("Clinqy — {} to open", self.hotkey_label)
        };
        let _ = self.tray.set_tooltip(Some(tip));
    }

    /// A question from a background run, on the card that never takes focus.
    fn ask_with_card(&mut self, s: &clinqy_core::agent::Snapshot) {
        let card = if let Some(r) = &s.review {
            let items: Vec<Value> = r.items.iter().map(|(q, a)| json!({"title": q, "subtitle": if a.trim().is_empty() { "(empty)" } else { a.as_str() }})).collect();
            json!({"title": format!("Review before submitting: {}", r.title), "text": "Check these answers before submitting.", "items": items, "actions": [["Submit", "__submit"], ["Edit", "__edit"]]})
        } else if let Some(q) = &s.question {
            if q.sensitive {
                json!({"title": "Clinqy needs you", "text": "It's waiting for something private. Answer it in the command bar.", "items": [], "actions": [["Answer…", "__reply"]]})
            } else if q.options.iter().any(|o| o == "Continue in foreground") {
                json!({"title": "Clinqy needs the foreground", "text": q.text, "items": [],
                       "actions": [["Run in foreground", "Continue in foreground"], ["Keep in background", "Keep background mode"], ["Stop task", "Stop task"]]})
            } else {
                let mut actions: Vec<Value> = q.options.iter().map(|o| json!([o, o])).collect();
                actions.push(json!(["Reply…", "__reply"]));
                json!({"title": "Clinqy needs you", "text": q.text, "items": [], "actions": actions})
            }
        } else {
            return;
        };
        self.question_card = true;
        self.card_id += 1;
        self.result.show(&card);
        crate::setup::beep();
    }

    /// A background run finished: a card that goes by itself.
    fn finished_card(&mut self, answer: &str, ok: bool) {
        let title = if ok { "Done" } else if answer == "Stopped" { "Stopped" } else { "Couldn't finish" };
        let mut actions = vec![json!(["Follow up", "__follow"])];
        if clinqy_core::worker::worker().has_tab() {
            actions.push(json!(["Show me", "__live"]));
        }
        self.notice_card(title, answer, json!(actions), 12);
    }

    /// A short message on the card that never takes focus; it goes by itself.
    fn notice_card(&mut self, title: &str, text: &str, actions: Value, seconds: u64) {
        self.result.show(&json!({"title": title, "text": text, "items": [], "actions": actions}));
        self.card_id += 1;
        let (id, p) = (self.card_id, self.shared.proxy.lock().clone());
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs(seconds));
            let _ = p.send_event(UserEvent::HideCard(id));
        });
    }

    fn live_state(&self) -> Value {
        let s = self.agent().snapshot();
        let sensitive = s.question.as_ref().map(|q| q.sensitive).unwrap_or(false);
        let text = if let Some(q) = &s.question {
            if q.sensitive { "Waiting for private input on this PC".to_string() } else { format!("Needs you: {}", q.text) }
        } else if s.running {
            s.narration.clone()
        } else if s.answer.is_empty() {
            "Nothing is running in the background.".to_string()
        } else {
            s.answer.clone()
        };
        json!({"text": text, "running": s.running, "paused": s.paused, "waitText": if sensitive { "Waiting for private input on this PC" } else { "" }})
    }

    fn refresh_live(&self) {
        self.live.state(&self.live_state());
    }

    /// Opens the live view, and keeps pictures coming while it's open: every second, every 3 while waiting.
    fn show_live(&mut self) {
        use std::sync::atomic::Ordering;
        self.live.present();
        self.refresh_live();
        if self.live_on.swap(true, Ordering::Relaxed) {
            return;
        }
        let (on, agent, shared) = (self.live_on.clone(), self.agent().clone(), self.shared.clone());
        tokio::spawn(async move {
            while on.load(Ordering::Relaxed) {
                let s = agent.snapshot();
                let private = s.question.as_ref().map(|q| q.sensitive).unwrap_or(false);
                if !private {
                    if let Some(jpeg) = clinqy_core::worker::worker().picture(None, 70).await {
                        shared.send(UserEvent::LiveFrame(jpeg));
                    }
                }
                tokio::time::sleep(Duration::from_secs(if s.question.is_some() || s.review.is_some() { 3 } else { 1 })).await;
            }
        });
    }

    fn on_live(&mut self, raw: &str) {
        let Ok(m) = serde_json::from_str::<Value>(raw) else { return };
        let agent = self.agent().clone();
        match m["type"].as_str().unwrap_or("") {
            "ready" => self.refresh_live(),
            "pause" => agent.set_paused(!agent.is_paused()),
            "stop" => agent.cancel(),
            "steer" => {
                let text = m["text"].as_str().unwrap_or("").to_string();
                if agent.question().is_some() {
                    agent.answer(Some(text));
                } else {
                    agent.add_context(&text);
                }
            }
            _ => {}
        }
    }

    fn on_hotkey(&mut self, h: HotEvent) {
        match h {
            // The summon chord: a tap opens (or closes) the bar; listening is push-to-talk's job.
            HotEvent::Pressed | HotEvent::Spoiled => {}
            HotEvent::TaskKey(key) => {
                let agent = self.agent().clone();
                match key {
                    TaskKey::Pause => {
                        let paused = !agent.is_paused();
                        agent.set_paused(paused);
                        self.notice_card(if paused { "Paused" } else { "Resumed" }, "Press the same keys to carry on, or stop.", json!([]), 3);
                    }
                    TaskKey::Stop => agent.cancel(),
                    TaskKey::PauseHint => self.notice_card("Press again to pause", "Press those keys again within 2 seconds to pause this background task.", json!([]), 3),
                    TaskKey::StopHint => self.notice_card("Press again to stop", "Press those keys again within 2 seconds to stop this background task.", json!([]), 3),
                }
            }
            HotEvent::Released => {
                if self.bar.visible() {
                    self.bar.hide();
                } else {
                    self.capture_context_then_show();
                }
            }
            // Push-to-talk: listen only while it's held.
            HotEvent::TalkDown => {
                self.talk_started = Some(Instant::now());
                if self.agent().question().is_none() {
                    self.bar.hide();
                }
                self.start_listening();
            }
            HotEvent::TalkUp => {
                let held = self.talk_started.take().map(|t| t.elapsed()).unwrap_or_default();
                if held < Duration::from_millis(250) {
                    // A tap, not speech: undo, and give the app its own shortcut (Ctrl+H is Replace, History…).
                    self.shared.voice.cancel();
                    self.agent().set_listening(false);
                    self.shared.agent.buddy.set_mood(if self.agent().is_running() { Mood::Acting } else { Mood::Idle });
                    if !self.agent().is_running() {
                        self.island_on = false;
                        self.island.hide();
                    }
                    let keys = self.talk_key.clone();
                    std::thread::spawn(move || {
                        std::thread::sleep(Duration::from_millis(30));
                        let _ = clinqy_windows::input::press_combo(&keys);
                    });
                } else {
                    self.shared.voice.stop();
                }
            }
        }
    }

    /// The tray's Pause item: only while a task runs, and it says Resume when paused.
    fn sync_pause_item(&self) {
        let running = self.agent().is_running();
        self.pause.set_enabled(running);
        self.pause.set_text(if running && self.agent().is_paused() { "Resume the task" } else { "Pause the current task" });
    }

    fn on_agent(&mut self, ev: AgentEvent) {
        match ev {
            AgentEvent::Changed(_) => {
                self.sync_pause_item();
                self.sync_background();
                if self.live.visible() {
                    self.refresh_live();
                }
                self.refresh_island();
                self.refresh_bar();
                self.refresh_dashboard();
            }
            AgentEvent::Started => {
                self.island_until = None;
                if self.agent().context.lock().continuation.is_none() {
                    self.island.recenter();
                }
                self.bar.hide();
                // A background run shows the badge instead: nothing on the screen moves.
                let background = self.agent().snapshot().background;
                self.island_on = !background;
                self.refresh_island();
                self.sync_background();
                if background {
                    self.notice_card("Running in the background", "Keep working. Clinqy won't touch your mouse, keyboard or windows.", json!([]), 5);
                }
            }
            AgentEvent::Question => {
                // Paused for the user's input: the bar comes up with the question. A background run doesn't take
                // the keyboard from them: a card asks, and it's theirs to answer when they like.
                let s = self.agent().snapshot();
                if s.background {
                    self.ask_with_card(&s);
                } else {
                    self.show_bar();
                }
            }
            AgentEvent::Answered => {
                if std::mem::take(&mut self.question_card) {
                    self.result.hide();
                }
                self.bar.hide();
                let target = self.agent().context.lock().target.clone().filter(|_| !self.agent().snapshot().background);
                let platform = self.shared.platform.clone();
                if let Some(t) = target {
                    tokio::spawn(async move {
                        platform.bring_to_front(&t).await;
                    });
                }
            }
            AgentEvent::WentForeground => {
                self.island_on = true;
                self.refresh_island();
                self.sync_background();
                self.notice_card("Now running in the foreground", "Clinqy will use your mouse and keyboard from here. Tap the tray icon to stop it.", json!([]), 6);
            }
            AgentEvent::Result => {
                if let Some(card) = self.agent().snapshot().result {
                    self.result.show(&serde_json::to_value(card).unwrap_or_default());
                }
            }
            AgentEvent::Finished { answer, ok, background } => {
                self.sync_pause_item();
                self.refresh_island();
                self.refresh_dashboard();
                self.sync_background();
                let has_card = self.agent().snapshot().result.is_some();
                if std::mem::take(&mut self.question_card) {
                    self.result.hide();
                }
                if background {
                    if !has_card {
                        self.finished_card(&answer, ok);
                    }
                } else if !has_card {
                    self.island_until = Some(Instant::now() + Duration::from_millis(4500));
                }
                // Stopped by the user: the bar comes back so they can say what to do differently.
                if !ok && answer == "Stopped" && !self.voice_run && !background {
                    self.show_bar();
                    // Opening the bar cancels the island's timer, and it would stay up.
                    self.island_until = Some(Instant::now() + Duration::from_millis(1500));
                }
                let spoken = std::mem::take(&mut self.voice_run);
                if spoken && ok && clinqy_core::config::on("FOLLOW_UP", false) {
                    // Keep the mic open a few seconds for a follow-up ("now email that to Rahul").
                    self.follow_up = true;
                    self.agent().context.lock().continuation = history::history().latest();
                    let p = self.shared.proxy.lock().clone();
                    let voice = self.shared.voice.clone();
                    std::thread::spawn(move || {
                        std::thread::sleep(Duration::from_millis(1200));
                        voice.start_auto(5.0);
                        let _ = p.send_event(UserEvent::VoiceLevel(0.0));
                    });
                }
            }
        }
    }

    fn on_bar(&mut self, raw: &str) {
        let Ok(m) = serde_json::from_str::<Value>(raw) else { return };
        let s = |k: &str| m[k].as_str().unwrap_or("").to_string();
        let agent = self.agent().clone();
        match m["type"].as_str().unwrap_or("") {
            "ready" => self.refresh_bar(),
            "drag" => {
                let _ = self.bar.window.drag_window();
            }
            "resize" => self.bar.resize(m["height"].as_f64().unwrap_or(120.0)),
            "hide" => {
                if agent.question().is_some() {
                    agent.answer(None);
                }
                self.bar.hide();
            }
            "submit" => self.submit(&s("text"), false),
            "provider" => {
                if let Some(provider) = Provider::parse(&s("provider")) {
                    if provider.is_configured() {
                        self.run_provider = provider;
                        self.refresh_bar();
                    }
                }
            }
            "add" => {
                agent.add_context(&s("text"));
                self.bar.hide();
            }
            "answer" => agent.answer(Some(s("text"))),
            "review" => agent.decide_review(m["submit"] == true, Some(s("note")).filter(|n| !n.is_empty())),
            "cancel" => agent.cancel(),
            "pause" => agent.set_paused(!agent.is_paused()),
            "backgroundMode" => {
                self.set_background(!clinqy_core::background::always());
                self.refresh_bar();
            }
            "settings" => {
                self.bar.hide();
                self.show_dashboard("Overview");
            }
            "dry" => {
                let on = !agent.dry_run.load(std::sync::atomic::Ordering::Relaxed);
                agent.dry_run.store(on, std::sync::atomic::Ordering::Relaxed);
                self.dry.set_checked(on);
                self.refresh_bar();
            }
            "mic" => {
                if self.shared.voice.is_listening() {
                    self.shared.voice.stop();
                } else {
                    self.start_listening();
                    self.refresh_bar();
                }
            }
            "tab" => self.tab = s("tab"),
            "continue" => {
                if let Some(h) = history::history().get(&s("id")) {
                    agent.context.lock().continuation = Some(h);
                    self.bar.update(&json!({"tab": "home"}));
                    self.bar.focus();
                }
            }
            "again" => {
                if let Some(h) = history::history().get(&s("id")) {
                    let req = h.request.trim_start_matches("Dry run: ").to_string();
                    self.submit(&req, false);
                }
            }
            "savewf" => {
                if let Some(w) = history::history().get(&s("id")).as_ref().and_then(workflow::Workflow::from_entry) {
                    workflow::workflows().add(w);
                    self.refresh_bar();
                }
            }
            "runwf" => {
                self.bar.hide();
                agent.run_workflow(&s("name"), Default::default());
            }
            "delwf" => {
                workflow::workflows().remove(&s("id"));
                self.refresh_bar();
            }
            "daily" => {
                if let Some(mut w) = workflow::workflows().all().into_iter().find(|w| w.id == s("id")) {
                    let t = s("time");
                    w.schedule = regex::Regex::new(r"^\d{1,2}:\d{2}$").unwrap().is_match(t.trim()).then(|| {
                        let (h, mm) = t.trim().split_once(':').unwrap();
                        format!("{:02}:{mm}", h.parse::<u32>().unwrap_or(9))
                    });
                    workflow::workflows().update(w);
                    self.refresh_bar();
                }
            }
            "delskill" => {
                clinqy_core::skills::remove(&s("id"));
                self.refresh_bar();
            }
            "delhist" => {
                history::history().remove(&s("id"));
                self.refresh_bar();
            }
            "result" => {
                if let Some(card) = history::history().get(&s("id")).and_then(|h| h.result) {
                    agent.show_card(card);
                }
            }
            // A correction to the run that just failed: carry on from it with what to do differently.
            "fix" => {
                if let Some(h) = history::history().get(&s("id")) {
                    agent.context.lock().continuation = Some(h);
                    self.submit(&format!("That didn't work. {}", s("text")), false);
                }
            }
            "unchip" => {
                let mut c = agent.context.lock();
                match s("kind").as_str() {
                    "continuation" => c.continuation = None,
                    "selection" => c.selected_text = None,
                    "files" => c.selected_files.clear(),
                    "copied" => c.copied = None,
                    "circled" => c.circled = None,
                    _ => {}
                }
                drop(c);
                self.refresh_bar();
            }
            "circle" => self.start_circling(),
            "watch" => {
                self.bar.hide();
                crate::recorder::toggle(self.shared.clone());
            }
            _ => {}
        }
    }

    fn on_result(&mut self, raw: &str) {
        let Ok(m) = serde_json::from_str::<Value>(raw) else { return };
        match m["type"].as_str().unwrap_or("") {
            "resize" => self.result.resize(m["height"].as_f64().unwrap_or(200.0)),
            "action" => {
                let agent = self.agent().clone();
                self.question_card = false;
                self.card_id += 1;
                self.result.hide();
                match m["value"].as_str().unwrap_or("") {
                    "__reply" | "__edit" => self.show_bar(),
                    "__submit" => agent.decide_review(true, None),
                    "__live" => self.show_live(),
                    "__follow" => {
                        agent.context.lock().continuation = history::history().latest();
                        self.show_bar();
                    }
                    "__later" => {}
                    "__update" => {
                        let proxy = self.shared.proxy.lock().clone();
                        std::thread::spawn(move || {
                            if !crate::update::run_from_app() {
                                let _ = proxy.send_event(UserEvent::Notice("Couldn't update. Try `clinqy update` in a terminal.".into()));
                            }
                        });
                    }
                    value => agent.answer(Some(value.to_string())),
                }
            }
            "copy" => {
                if let Some(r) = self.agent().snapshot().result {
                    self.shared.platform.set_clipboard_text(&r.plain());
                }
            }
            "dismiss" => {
                self.agent().dismiss_result();
                self.result.hide();
            }
            "link" => {
                if let Some(u) = m["url"].as_str().filter(|u| u.starts_with("http")) {
                    self.shared.platform.open_url_direct(u);
                }
            }
            _ => {}
        }
    }

    fn on_menu(&mut self, id: &str) {
        let agent = self.agent().clone();
        let open = |p: &std::path::Path| {
            clinqy_windows::system::shell_open(&p.display().to_string());
        };
        match id {
            "open" => self.capture_context_then_show(),
            "dashboard" => self.show_dashboard("Overview"),
            "live" => self.show_live(),
            "background" => self.set_background(!clinqy_core::background::always()),
            "pause" => agent.set_paused(!agent.is_paused()),
            "stop" => agent.cancel(),
            "watch" => crate::recorder::toggle(self.shared.clone()),
            "circle" => self.start_circling(),
            "history" => {
                self.bar.update(&json!({"tab": "history"}));
                self.show_bar();
            }
            "applications" => {
                agent.show_applications();
            }
            "stats" => agent.show_card(clinqy_core::history::ResultCard { title: "How runs are going (7 days)".into(), text: clinqy_core::stats::report(7.0, false), items: vec![] }),
            "memory" => {
                let p = clinqy_core::memory::path();
                if !p.exists() {
                    let _ = std::fs::write(&p, "# What Clinqy remembers about you — one fact per line. Edit freely.\n");
                }
                open(&p);
            }
            "profile" => {
                let _ = clinqy_core::profile::current();
                open(&clinqy_core::profile::path());
            }
            "settings" => {
                self.open_settings();
            }
            "extension" => crate::setup::show_extension_help(),
            "check" => agent.show_card(crate::setup::check_card(None)),
            "model:keys" => {
                crate::setup::ensure_env_file();
                let p = clinqy_core::paths::env_file();
                use std::os::windows::process::CommandExt;
                let _ = std::process::Command::new("notepad.exe").arg(&p).creation_flags(clinqy_core::session::CREATE_NO_WINDOW).spawn();
            }
            m if m.starts_with("model:") => {
                let name = &m[6..];
                let p = if name == "test" {
                    clinqy_core::provider::Provider::current()
                } else if name == "auto" {
                    let Ok(p) = crate::onboard::choose_auto() else { return };
                    p
                } else {
                    let Some(p) = crate::onboard::MODELS.iter().find(|x| x.0 == name).map(|x| x.1) else { return };
                    let _ = crate::onboard::choose(p, None);
                    p
                };
                let now = crate::onboard::short_name(p);
                let auto = crate::onboard::is_auto();
                for (i, item) in self.models.iter().enumerate() {
                    item.set_checked(if i == 0 { auto } else { !auto && crate::onboard::MODELS[i - 1].0 == now });
                }
                // Check it answers, and say so either way.
                let shared = self.shared.clone();
                shared.send(UserEvent::Notice(format!("Checking that {now} answers…")));
                tokio::spawn(async move {
                    let text = match crate::onboard::readiness(p) {
                        Err(fix) => fix,
                        Ok(_) => match crate::onboard::test(p).await {
                            Ok(t) => format!("✓ {now} works ({:.1} s). Press Ctrl+Alt and ask something.", t.as_secs_f64()),
                            Err(e) => format!("✗ {now} didn't answer: {e}. Run `{now}` once in a terminal to log in."),
                        },
                    };
                    shared.send(UserEvent::Notice(text));
                });
            }
            lang if lang.starts_with("lang:") => {
                let code = &lang[5..];
                let _ = clinqy_core::config::set("VOICE_LANGUAGE", code);
                for (item, (c, _)) in self.languages.iter().zip(crate::voice::LANGUAGES) {
                    item.set_checked(c == code);
                }
            }
            "dry" => {
                let on = !agent.dry_run.load(std::sync::atomic::Ordering::Relaxed);
                agent.dry_run.store(on, std::sync::atomic::Ordering::Relaxed);
                self.dry.set_checked(on);
            }
            "login" => {
                let on = !crate::setup::starts_at_login();
                crate::setup::set_start_at_login(on);
                self.login.set_checked(crate::setup::starts_at_login());
            }
            "quit" => {
                agent.cancel();
                clinqy_core::worker::worker().shutdown();
                self.shared.send(UserEvent::Quit);
            }
            _ => {}
        }
    }

    fn open_settings(&self) {
        crate::setup::ensure_env_file();
        let path = clinqy_core::paths::env_file();
        let flags = clinqy_core::session::CREATE_NO_WINDOW;
        use std::os::windows::process::CommandExt;
        if std::process::Command::new("notepad.exe").arg(&path).creation_flags(flags).spawn().is_err() {
            clinqy_windows::system::shell_open(&path.display().to_string());
        }
    }
}
