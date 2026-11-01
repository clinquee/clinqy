//! The agent: runs a request as a conversation with one model session — observe the screen, the model picks
//! actions, the companion cursor carries them out the way a person would, report, repeat. A port of the Mac
//! app's Agent with the same loop, actions, safety checks and recovery behaviour.
//!
//! Layout: `mod.rs` holds the agent's state and its API for the UI; `run.rs` the loop; `act.rs` the actions on
//! apps; `web.rs` the actions inside web pages; `tasks.rs` the background jobs (files, PDFs, email, calendar…).

mod act;
mod run;
mod tasks;
mod web;

use crate::hands::{Hands, QuietBuddy};
use crate::history::{self, Entry, ResultCard};
use crate::taskstore::tasks;
use crate::platform::{AppRef, Buddy, Mood, Platform, Point, Rect};
use crate::provider::Provider;
use crate::session::{Brain, Session};
use crate::workflow::{Target, WorkflowStep};
use parking_lot::Mutex;
use serde::Serialize;
use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::oneshot;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Phase {
    Idle,
    Listening,
    Thinking,
    Acting,
    Waiting,
    Done,
    Failed,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct Question {
    pub text: String,
    pub options: Vec<String>,
    pub sensitive: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum StepState {
    Running,
    Ok,
    Failed,
    Info,
}

#[derive(Clone, Debug, Serialize)]
pub struct Step {
    pub text: String,
    pub state: StepState,
}

/// A form's answers shown before its final Submit, waiting for Submit or Edit.
#[derive(Clone, Debug, Serialize)]
pub struct Review {
    pub title: String,
    pub items: Vec<(String, String)>,
}

/// Everything the UI shows, sent whenever it changes.
#[derive(Clone, Debug, Serialize)]
pub struct Snapshot {
    pub phase: Phase,
    pub narration: String,
    pub steps: Vec<Step>,
    pub question: Option<Question>,
    pub result: Option<ResultCard>,
    pub answer: String,
    pub running: bool,
    pub review: Option<Review>,
    pub request: String,
    pub dry_run: bool,
    /// The current run only shows what it would do.
    pub dry: bool,
    /// Held by the user between steps (Pause); Resume carries on.
    pub paused: bool,
    /// The current run works in the background browser, out of the user's way.
    pub background: bool,
    pub qa: bool,
}

#[derive(Clone, Debug)]
pub enum Event {
    Changed(Box<Snapshot>),
    Started,
    /// Paused for the user's input.
    Question,
    Answered,
    Result,
    Finished { answer: String, ok: bool, background: bool },
    /// A background run came to the foreground: it'll use the mouse and keyboard now.
    WentForeground,
}

/// What the user copied in the last few minutes, when nothing was selected.
#[derive(Clone, Debug, Default)]
pub struct Copied {
    pub text: Option<String>,
    pub files: Vec<PathBuf>,
    pub age_secs: u64,
}

/// Context captured when the user summoned Clinqy, sent with the next request.
#[derive(Clone, Debug, Default)]
pub struct Context {
    pub target: Option<AppRef>,
    pub selected_text: Option<String>,
    pub selected_files: Vec<PathBuf>,
    pub copied: Option<Copied>,
    pub continuation: Option<Entry>,
    /// A loop the user drew around something on screen ("this", "here"); screen pixels.
    pub circled: Option<Vec<Point>>,
}

/// Options for one request.
#[derive(Clone, Debug, Default)]
pub struct RunOptions {
    pub test: bool,
    pub dry: bool,
    pub model: Option<String>,
    pub provider: Option<Provider>,
    /// Started by the agent itself to carry on a long task.
    pub auto: bool,
    /// Tests that still show the review card / save form answers.
    pub review_in_tests: bool,
    pub save_in_tests: bool,
    /// Whoever asked already chose (a caller's flag). The request's own words win over this.
    pub background: Option<bool>,
}

/// Mutable state the UI sees.
struct Ui {
    phase: Phase,
    narration: String,
    steps: Vec<Step>,
    question: Option<Question>,
    result: Option<ResultCard>,
    answer: String,
    review: Option<Review>,
    request: String,
    qa: bool,
}

/// A QA test's checks.
#[derive(Clone, Debug, Serialize, serde::Deserialize)]
pub struct Check {
    pub text: String,
    pub pass: bool,
    pub note: String,
}

#[derive(Clone, Debug, Serialize, serde::Deserialize)]
pub struct QaReport {
    pub name: String,
    pub passed: bool,
    pub mode: String,
    #[serde(rename = "durationMs")]
    pub duration_ms: u64,
    pub steps: Vec<String>,
    pub checks: Vec<Check>,
    pub message: String,
}

/// A step screenshot for a write-up, kept until pasted (a write-up spans several runs).
#[derive(Clone)]
struct Snap {
    caption: String,
    png: Vec<u8>,
    pasted: bool,
}

type ReviewAnswer = (bool, Option<String>);

pub struct Agent {
    /// The agent's hands: the desktop, or the background browser in a background run.
    pub platform: Arc<dyn Platform>,
    pub buddy: Arc<dyn Buddy>,
    pub(crate) hands: Arc<Hands>,
    quiet: Arc<QuietBuddy>,
    /// What the next run decided about where to work.
    next_background: AtomicBool,
    /// The last run was a background one, so a follow-up to it is too.
    last_background: AtomicBool,
    brain: Brain,
    ui: Mutex<Ui>,
    emit: Box<dyn Fn(Event) + Send + Sync>,
    /// Things the user added mid-task, folded into the next step.
    added: Mutex<Vec<String>>,
    answer_waiter: Mutex<Option<oneshot::Sender<Option<String>>>>,
    review_waiter: Mutex<Option<oneshot::Sender<ReviewAnswer>>>,
    task: Mutex<Option<tokio::task::JoinHandle<()>>>,
    pub context: Mutex<Context>,
    /// The sticky Dry run toggle from the command bar.
    pub dry_run: AtomicBool,
    /// Whether the current run is a dry run (the toggle, "dry run:" or `--dry`).
    run_dry: AtomicBool,
    last_progress: Arc<Mutex<Instant>>,
    paused: AtomicBool,
    pause_wake: tokio::sync::Notify,
    snaps: Mutex<(Vec<Snap>, Option<PathBuf>, Option<Instant>)>,
    auto_continues: AtomicU32,
    /// Bumped by every new run, so a stale watchdog or a finished run's late call can tell it's not current.
    generation: AtomicU32,
    current: Mutex<RunInfo>,
    /// QA: the checks of the test running now.
    checks: Mutex<Vec<Check>>,
    /// What the user typed instead of approving the last review.
    last_review_note: Mutex<Option<String>>,
}

/// What finish() needs about the run in progress (kept outside the run's task so a cancel can still finish it).
#[derive(Clone, Default)]
struct RunInfo {
    request: String,
    started: Option<Instant>,
    started_at: Option<chrono::DateTime<chrono::Utc>>,
    test: bool,
    dry: bool,
    qa: Option<String>,
    target: Option<AppRef>,
    trace: Vec<WorkflowStep>,
    read_text: Option<String>,
    secrets: Vec<String>,
    continuation: Option<Entry>,
    start_place: (Option<String>, Option<String>, Option<String>),
    opened_last: bool,
    turns: u32,
    model_seconds: f64,
    requires_fresh_work: bool,
    looks: u32,
    linger: f64,
    run_result: Option<ResultCard>,
    finished: bool,
    background: bool,
    /// What the user added during the run, kept with the task for anything that continues it.
    follow_ups: Vec<String>,
    /// Its record in the task store (test and QA runs have none).
    task: Option<String>,
}

impl Agent {
    pub fn new(platform: Arc<dyn Platform>, buddy: Arc<dyn Buddy>, emit: impl Fn(Event) + Send + Sync + 'static) -> Arc<Agent> {
        let hands = Arc::new(Hands::new(platform));
        let quiet = Arc::new(QuietBuddy::new(buddy));
        Arc::new(Agent {
            platform: hands.clone(),
            buddy: quiet.clone(),
            hands,
            quiet,
            next_background: AtomicBool::new(false),
            last_background: AtomicBool::new(false),
            brain: Brain::new(),
            ui: Mutex::new(Ui {
                phase: Phase::Idle,
                narration: String::new(),
                steps: vec![],
                question: None,
                result: None,
                answer: String::new(),
                review: None,
                request: String::new(),
                qa: false,
            }),
            emit: Box::new(emit),
            added: Mutex::new(vec![]),
            answer_waiter: Mutex::new(None),
            review_waiter: Mutex::new(None),
            task: Mutex::new(None),
            context: Mutex::new(Context::default()),
            dry_run: AtomicBool::new(false),
            run_dry: AtomicBool::new(false),
            last_progress: Arc::new(Mutex::new(Instant::now())),
            paused: AtomicBool::new(false),
            pause_wake: tokio::sync::Notify::new(),
            snaps: Mutex::new((vec![], None, None)),
            auto_continues: AtomicU32::new(0),
            generation: AtomicU32::new(0),
            current: Mutex::new(RunInfo::default()),
            checks: Mutex::new(vec![]),
            last_review_note: Mutex::new(None),
        })
    }

    /// Starts the model CLI ahead of time, so the first request doesn't wait for it.
    pub fn prewarm(self: &Arc<Self>) {
        let me = self.clone();
        tokio::spawn(async move {
            let _ = tokio::task::spawn_blocking(move || me.brain.prewarm(crate::prompt::SYSTEM)).await;
        });
    }

    pub(crate) fn session(&self, model: Option<&str>, provider: Option<Provider>) -> anyhow::Result<Session> {
        self.brain.session(crate::prompt::SYSTEM, model, provider)
    }

    pub fn snapshot(&self) -> Snapshot {
        let u = self.ui.lock();
        Snapshot {
            phase: u.phase,
            narration: u.narration.clone(),
            steps: u.steps.clone(),
            question: u.question.clone(),
            result: u.result.clone(),
            answer: u.answer.clone(),
            running: matches!(u.phase, Phase::Thinking | Phase::Acting | Phase::Waiting),
            review: u.review.clone(),
            request: u.request.clone(),
            dry_run: self.dry_run.load(Ordering::Relaxed),
            dry: self.run_dry.load(Ordering::Relaxed),
            paused: self.paused.load(Ordering::Relaxed) && matches!(u.phase, Phase::Thinking | Phase::Acting | Phase::Waiting),
            background: self.hands.hidden(),
            qa: u.qa,
        }
    }

    fn changed(&self) {
        (self.emit)(Event::Changed(Box::new(self.snapshot())));
    }

    pub fn is_running(&self) -> bool {
        matches!(self.ui.lock().phase, Phase::Thinking | Phase::Acting | Phase::Waiting)
    }

    pub fn phase(&self) -> Phase {
        self.ui.lock().phase
    }

    pub fn question(&self) -> Option<Question> {
        self.ui.lock().question.clone()
    }

    pub(crate) fn set_phase(&self, p: Phase) {
        self.ui.lock().phase = p;
        self.changed();
    }

    pub(crate) fn set_narration(&self, s: &str) {
        self.ui.lock().narration = s.to_string();
        self.changed();
    }

    pub fn set_listening(&self, on: bool) {
        let mut u = self.ui.lock();
        if on && matches!(u.phase, Phase::Idle | Phase::Done | Phase::Failed) {
            u.phase = Phase::Listening;
        } else if !on && u.phase == Phase::Listening {
            u.phase = Phase::Idle;
        }
        drop(u);
        self.changed();
    }

    /// Shows a card in the result panel (also used for the application tracker and stats).
    pub fn show_card(&self, card: ResultCard) {
        self.ui.lock().result = Some(card);
        self.changed();
        (self.emit)(Event::Result);
    }

    pub fn dismiss_result(&self) {
        self.ui.lock().result = None;
        self.changed();
    }

    /// Steer a running task: more context or a change of plan, picked up at the next step.
    pub fn add_context(&self, raw: &str) {
        let text = raw.trim();
        if text.is_empty() || !self.is_running() {
            return;
        }
        if self.ui.lock().question.is_some() {
            return self.answer(Some(text.to_string()));
        }
        self.added.lock().push(text.to_string());
        self.current.lock().follow_ups.push(text.to_string());
        self.push_step(&format!("You: {text}"), StepState::Info);
        self.progress();
        self.log(&format!("  + user added: {text}"));
    }

    /// More for the task: folded into the running one, or, once it's over, the latest task carries on with it.
    pub fn follow_up(self: &Arc<Self>, raw: &str) {
        let text = raw.trim();
        if text.is_empty() {
            return;
        }
        if self.is_running() {
            return self.add_context(text);
        }
        self.context.lock().continuation = history::history().latest();
        self.submit(text, RunOptions::default());
    }

    /// The user's reply to the current question (None = declined / cancelled). A waiting review takes it too:
    /// "submit"/"yes" approves, anything else is an edit to make first.
    pub fn answer(&self, text: Option<String>) {
        if self.answer_waiter.lock().is_none() {
            if let Some(w) = self.review_waiter.lock().take() {
                let t = text.clone().unwrap_or_default();
                let approve = regex::Regex::new(r"(?i)^\s*(submit|yes|ok|okay|go ahead|approve|send)\b").unwrap().is_match(&t);
                self.ui.lock().review = None;
                self.changed();
                let _ = w.send((approve, if approve { None } else { Some(t) }));
                return;
            }
        }
        let Some(w) = self.answer_waiter.lock().take() else { return };
        self.progress();
        {
            let mut u = self.ui.lock();
            u.question = None;
        }
        self.changed();
        (self.emit)(Event::Answered);
        let _ = w.send(text.map(|t| t.trim().to_string()));
    }

    /// The review card's buttons.
    pub fn decide_review(&self, submit: bool, note: Option<String>) {
        if let Some(w) = self.review_waiter.lock().take() {
            self.ui.lock().review = None;
            self.changed();
            let _ = w.send((submit, note.filter(|n| !n.trim().is_empty())));
        }
    }

    /// Stops the current task.
    pub fn cancel(self: &Arc<Self>) {
        self.decide_review(false, None);
        self.answer(None);
        if let Some(t) = self.task.lock().take() {
            t.abort();
        }
        if self.is_running() {
            self.finish(false, "Stopped");
        }
    }

    /// Pause or resume the running task. It holds at the next step (before an action or the next turn); Stop
    /// still ends it at once.
    pub fn set_paused(&self, on: bool) {
        if on && !self.is_running() {
            return;
        }
        if self.paused.swap(on, Ordering::Relaxed) == on {
            return;
        }
        if !on {
            self.pause_wake.notify_waiters();
        }
        self.changed();
    }

    pub fn is_paused(&self) -> bool {
        self.paused.load(Ordering::Relaxed)
    }

    /// Waits here while the user has the task paused.
    pub(crate) async fn hold_if_paused(&self) {
        if !self.is_paused() {
            return;
        }
        self.log("  ⏸ paused by the user");
        self.buddy.set_mood(Mood::Idle);
        self.buddy.go_home();
        while self.is_paused() {
            self.progress();
            tokio::select! {
                _ = self.pause_wake.notified() => {}
                _ = tokio::time::sleep(Duration::from_millis(500)) => {}
            }
        }
        self.log("  ▶ resumed");
        self.buddy.set_mood(Mood::Acting);
    }

    pub(crate) fn progress(&self) {
        *self.last_progress.lock() = Instant::now();
    }

    pub(crate) fn push_step(&self, text: &str, state: StepState) -> usize {
        let mut t = text.to_string();
        for s in self.current.lock().secrets.iter().filter(|s| s.len() >= 3) {
            t = t.replace(s.as_str(), "••••");
        }
        let i = {
            let mut u = self.ui.lock();
            u.steps.push(Step { text: t.clone(), state });
            if state == StepState::Running {
                u.narration = t.clone();
            }
            u.steps.len() - 1
        };
        self.changed();
        i
    }

    pub(crate) fn set_step(&self, i: usize, state: StepState, text: Option<&str>) {
        {
            let mut u = self.ui.lock();
            if let Some(s) = u.steps.get_mut(i) {
                s.state = state;
                if let Some(t) = text {
                    s.text = t.to_string();
                }
            }
        }
        self.changed();
    }

    pub(crate) fn steps(&self) -> Vec<Step> {
        self.ui.lock().steps.clone()
    }

    pub(crate) fn request(&self) -> String {
        self.current.lock().request.clone()
    }

    /// A line in agent.log, "[  1.23s] text", secrets masked.
    pub(crate) fn log(&self, text: &str) {
        self.progress();
        let (secrets, started) = {
            let c = self.current.lock();
            (c.secrets.clone(), c.started)
        };
        let mut t = text.to_string();
        for s in secrets.iter().filter(|s| s.len() >= 3) {
            t = t.replace(s.as_str(), "••••");
        }
        let secs = started.map(|s| s.elapsed().as_secs_f64()).unwrap_or(0.0);
        crate::log::write(&format!("[{secs:6.2}s] {t}"));
    }

    /// Submits a request. Saved workflows that do exactly this replay with no model.
    pub fn submit(self: &Arc<Self>, raw: &str, opts: RunOptions) {
        if !opts.auto {
            self.auto_continues.store(0, Ordering::Relaxed);
        }
        let mut request = raw.trim().to_string();
        if request.is_empty() || self.is_running() {
            return;
        }
        let mut dry = opts.dry || self.dry_run.load(Ordering::Relaxed);
        let re = regex::Regex::new(r"(?i)^\(?(dry[ -]?run|rehearse|practice run)\)?[:,\s-]+").unwrap();
        if let Some(m) = re.find(&request) {
            request = request[m.end()..].to_string();
            dry = true;
        }
        self.run_dry.store(dry, Ordering::Relaxed);
        // A dry run points at things with the cursor, so it's always in front of the user.
        let continuing = self.context.lock().continuation.is_some() && self.last_background.load(Ordering::SeqCst);
        let background = crate::background::choice(&mut request).or(opts.background).or(continuing.then_some(true)).unwrap_or_else(crate::background::always) && !dry;
        if request.is_empty() {
            return;
        }
        self.next_background.store(background, Ordering::SeqCst);
        // "continue", "also make the answers": builds on the last task.
        {
            let mut ctx = self.context.lock();
            if ctx.continuation.is_none() && !opts.test {
                if let Some(last) = history::history().latest() {
                    let age = chrono::Local::now().signed_duration_since(last.when());
                    let correction = crate::workflow::is_correction(&request);
                    if age.num_seconds() >= 0
                        && ((correction && age.num_hours() < 24) || (age.num_minutes() < 20 && crate::workflow::is_follow_up(&request)))
                    {
                        if correction {
                            crate::workflow::replay_cache().corrected(&last.request);
                        }
                        ctx.continuation = Some(last);
                    }
                }
            }
        }
        let me = self.clone();
        let workflow = if !opts.test && !dry && !background { self.workflow_first(&request) } else { None };
        self.prepare(&request, opts.test, dry, None);
        let handle = tokio::spawn(async move {
            if let Some(m) = workflow {
                let mut params = m.workflow.defaults.clone().unwrap_or_default();
                params.extend(m.params.clone());
                me.push_step(
                    &format!("Saved workflow “{}” — no model needed", m.workflow.name.chars().take(40).collect::<String>()),
                    StepState::Info,
                );
                me.log(&format!("workflow-first: “{}” · params {:?}", m.workflow.name, m.params));
                me.replay_or_heal(m.workflow, params, None, &opts).await;
            } else {
                me.run(request, &opts).await;
            }
            *me.context.lock() = Context::default();
        });
        *self.task.lock() = Some(handle);
    }

    fn workflow_first(&self, request: &str) -> Option<crate::workflow::RouteMatch> {
        let ctx = self.context.lock();
        if !crate::config::on("WORKFLOW_FIRST", true)
            || ctx.selected_text.is_some()
            || !ctx.selected_files.is_empty()
            || ctx.continuation.is_some()
            || ctx.circled.is_some()
            || run::is_question(request)
            || crate::workflow::refers_to_context(request)
        {
            return None;
        }
        crate::workflow::route(request, &crate::workflow::workflows().all())
    }

    /// Replays a saved workflow by name.
    pub fn run_workflow(self: &Arc<Self>, name: &str, params: std::collections::HashMap<String, String>) -> bool {
        if self.is_running() {
            return false;
        }
        let Some(wf) = crate::workflow::workflows().named(name) else { return false };
        let mut all = wf.defaults.clone().unwrap_or_default();
        all.extend(params);
        self.prepare(&format!("Workflow: {}", wf.name), false, false, None);
        let me = self.clone();
        let handle = tokio::spawn(async move {
            me.replay_or_heal(wf, all, None, &RunOptions::default()).await;
        });
        *self.task.lock() = Some(handle);
        true
    }

    /// Runs a UI test: replays its compiled script with no model, or learns it, then writes a report.
    #[allow(clippy::too_many_arguments)] // Public QA command arguments map directly to the CLI contract.
    pub fn run_qa(
        self: &Arc<Self>,
        name: &str,
        test: &str,
        compiled: PathBuf,
        relearn: bool,
        model: Option<String>,
        provider: Option<Provider>,
        out: PathBuf,
    ) {
        if self.is_running() {
            write_report(
                &QaReport {
                    name: name.into(),
                    passed: false,
                    mode: "none".into(),
                    duration_ms: 0,
                    steps: vec![],
                    checks: vec![],
                    message: "Clinqy is busy with another task".into(),
                },
                &out,
            );
            return;
        }
        self.prepare(&format!("QA: {name}"), true, false, Some(name.to_string()));
        self.buddy.set_qa(true);
        let me = self.clone();
        let (name, test) = (name.to_string(), test.to_string());
        let handle = tokio::spawn(async move {
            let started = Instant::now();
            let opts = RunOptions { test: true, model, provider, ..Default::default() };
            let saved = (!relearn)
                .then(|| std::fs::read_to_string(&compiled).ok().and_then(|t| serde_json::from_str::<crate::workflow::Workflow>(&t).ok()))
                .flatten();
            let mut mode = "learned".to_string();
            if let Some(w) = saved {
                mode = if me.replay_or_heal(w, Default::default(), Some(test.clone()), &opts).await {
                    "healed".into()
                } else {
                    "replay".into()
                };
            } else {
                me.run(run::qa_prompt(&name, &test), &opts).await;
            }
            let finished_ok = me.phase() == Phase::Done;
            let checks = me.checks.lock().clone();
            let passed = finished_ok && !checks.iter().any(|c| !c.pass);
            let trace = me.current.lock().trace.clone();
            if finished_ok && mode != "replay" && !trace.is_empty() {
                let mut steps = trace;
                let go = regex::Regex::new(r"(?im)^\s*(?:go to|open|visit|navigate to)\s+(https?://\S+)").unwrap();
                if let Some(c) = go.captures(&test) {
                    if steps.first().map(|s| s.action != "open_url").unwrap_or(true) {
                        steps.insert(0, WorkflowStep { action: "open_url".into(), url: Some(c[1].to_string()), ..Default::default() });
                    }
                }
                let wf = crate::workflow::Workflow::new(&name, "QA test", steps);
                if let Some(dir) = compiled.parent() {
                    let _ = std::fs::create_dir_all(dir);
                }
                let _ = std::fs::write(&compiled, serde_json::to_string_pretty(&wf).unwrap_or_default());
            }
            let report = QaReport {
                name: name.clone(),
                passed,
                mode,
                duration_ms: started.elapsed().as_millis() as u64,
                steps: me.steps().into_iter().map(|s| s.text).collect(),
                checks,
                message: me.ui.lock().answer.clone(),
            };
            write_report(&report, &out);
            me.buddy.set_qa(false);
            me.ui.lock().qa = false;
            me.current.lock().qa = None;
        });
        *self.task.lock() = Some(handle);
    }

    /// Resets per-run state; shared by requests, workflow replays and QA runs.
    fn prepare(self: &Arc<Self>, request: &str, test: bool, dry: bool, qa: Option<String>) {
        let ctx = self.context.lock().clone();
        let generation = self.generation.fetch_add(1, Ordering::SeqCst) + 1;
        {
            let mut c = self.current.lock();
            *c = RunInfo {
                request: request.to_string(),
                started: Some(Instant::now()),
                started_at: Some(chrono::Utc::now()),
                test,
                dry,
                qa: qa.clone(),
                target: ctx.target.clone(),
                continuation: ctx.continuation.clone(),
                ..Default::default()
            };
        }
        self.checks.lock().clear();
        // Only `submit` runs in the background: QA and workflows work on the screen.
        let background = self.next_background.swap(false, Ordering::SeqCst);
        let task = if test || qa.is_some() { None } else { self.open_task(request, &ctx, background) };
        {
            let mut c = self.current.lock();
            c.background = background;
            c.task = task;
        }
        self.quiet.set_quiet(background);
        self.hands.set_hidden(background);
        if background {
            crate::worker::worker().run_started(ctx.continuation.is_some());
        }
        {
            let mut u = self.ui.lock();
            u.steps.clear();
            u.answer.clear();
            u.narration.clear();
            u.question = None;
            u.review = None;
            u.request = request.to_string();
            u.phase = Phase::Thinking;
            u.qa = qa.is_some();
        }
        self.added.lock().clear();
        {
            // Snaps not yet pasted are kept for a few hours whatever the next request is (a write-up spans runs).
            let mut s = self.snaps.lock();
            let stale = s.2.map(|t| t.elapsed() > Duration::from_secs(3 * 3600)).unwrap_or(true);
            if ctx.continuation.is_none() && (stale || !s.0.iter().any(|x| !x.pasted)) {
                s.0.clear();
                s.1 = None;
            }
        }
        self.paused.store(false, Ordering::Relaxed);
        self.platform.begin_run();
        self.buddy.clear_mark();
        self.progress();
        crate::replay::begin(request);
        let extra = [
            ctx.selected_text.as_ref().map(|t| format!(" [selection: {} chars]", t.chars().count())),
            (!ctx.selected_files.is_empty()).then(|| {
                format!(
                    " [files: {}]",
                    ctx.selected_files
                        .iter()
                        .filter_map(|f| f.file_name())
                        .map(|f| f.to_string_lossy().into_owned())
                        .collect::<Vec<_>>()
                        .join(", ")
                )
            }),
            ctx.circled
                .as_deref()
                .map(circle_bounds)
                .map(|r| format!(" [circled: {}×{} at {},{}]", r.w as i64, r.h as i64, r.x as i64, r.y as i64)),
        ]
        .into_iter()
        .flatten()
        .collect::<String>();
        crate::log::write(&format!("=== {}{}{request}{extra}", if dry { "[dry run] " } else { "" }, if background { "[background] " } else { "" }));
        self.changed();
        (self.emit)(Event::Started);
        self.start_watchdog(generation);
    }

    fn start_watchdog(self: &Arc<Self>, generation: u32) {
        let me = self.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(5)).await;
                if me.generation.load(Ordering::SeqCst) != generation || !me.is_running() {
                    return;
                }
                let phase = me.phase();
                // A model reply with a screenshot and a long history can take well over 30 s: slow, not stuck.
                let limit = if phase == Phase::Thinking { 180 } else { 30 };
                if phase == Phase::Waiting || me.last_progress.lock().elapsed() < Duration::from_secs(limit) {
                    continue;
                }
                let step = if phase == Phase::Thinking {
                    "waiting for the model's reply".to_string()
                } else {
                    me.steps().last().map(|s| s.text.clone()).unwrap_or_else(|| "a step".into())
                };
                me.log(&format!("watchdog: no progress for {limit} s on {step}"));
                if let Some(t) = me.task.lock().take() {
                    t.abort();
                }
                me.finish(false, &format!("I got stuck on “{step}” and stopped"));
                return;
            }
        });
    }

    /// Its record in the task store. A request that can't have one (it held a secret) runs without a checkpoint.
    fn open_task(&self, request: &str, ctx: &Context, background: bool) -> Option<String> {
        let files = ctx.selected_files.iter().map(|f| f.display().to_string()).collect();
        let id = tasks().enqueue(request, files, "windows", background)?;
        if tasks().start(&id, true) {
            Some(id)
        } else {
            tasks().cancel_queued(&id);
            None
        }
    }

    pub(crate) fn task_id(&self) -> Option<String> {
        self.current.lock().task.clone()
    }

    /// The run comes to the foreground (the user said so, for something that can't be done hidden).
    pub(crate) fn leave_background(&self) {
        self.current.lock().background = false;
        self.hands.set_hidden(false);
        self.quiet.set_quiet(false);
        self.platform.begin_run();
        tokio::spawn(crate::worker::worker().run_ended());
        self.changed();
        (self.emit)(Event::WentForeground);
    }

    /// Ends the run: history, stats, the cursor home, and carrying on by itself when a long task ran out of steps.
    pub(crate) fn finish(self: &Arc<Self>, ok: bool, text: &str) {
        if !self.is_running() {
            return;
        }
        self.paused.store(false, Ordering::Relaxed);
        let info = {
            let mut c = self.current.lock();
            if c.finished {
                return;
            }
            c.finished = true;
            c.clone()
        };
        let request = info.request.clone();
        {
            let mut u = self.ui.lock();
            u.phase = if ok { Phase::Done } else { Phase::Failed };
            u.narration = text.to_string();
            u.answer = text.to_string();
            u.question = None;
            u.review = None;
        }
        // Long answers are easier to read in a card than in the status bar.
        let mut run_result = info.run_result.clone();
        if ok && run_result.is_none() && text.chars().count() > 140 {
            let card = ResultCard { title: request.chars().take(60).collect(), text: text.to_string(), items: vec![] };
            run_result = Some(card.clone());
            self.ui.lock().result = Some(card);
            (self.emit)(Event::Result);
        }
        self.buddy.set_mood(if ok { Mood::Success } else { Mood::Failure });
        let buddy = self.buddy.clone();
        let linger = info.linger;
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_secs_f64(linger + 0.35)).await;
            buddy.go_home();
            buddy.set_mood(Mood::Idle);
        });
        self.log(&if ok { format!("✓ {text}") } else { format!("✗ {text}") });
        let keep_front = info.opened_last || run::keeps_front_app(&request);
        self.platform.end_run(keep_front);
        tasks().finish(info.task.as_deref(), ok, text);
        if self.hands.hidden() {
            self.hands.set_hidden(false);
            self.quiet.set_quiet(false);
            tokio::spawn(crate::worker::worker().run_ended());
        }
        crate::replay::end(ok);
        let steps = self.steps();
        if !info.test {
            let secs = info.started.map(|s| s.elapsed().as_secs_f64()).unwrap_or(0.0);
            crate::log::append_jsonl(
                "runs.jsonl",
                &serde_json::json!({
                    "date": info.started_at.map(|d| d.to_rfc3339()).unwrap_or_default(),
                    "request": request.chars().take(160).collect::<String>(),
                    "ok": ok, "stopped": !ok && text == "Stopped",
                    "seconds": (secs * 10.0).round() / 10.0,
                    "turns": info.turns, "fast_turns": 0, "screenshots": info.looks, "model_seconds": info.model_seconds,
                    "steps": steps.len(), "failed_steps": steps.iter().filter(|s| s.state == StepState::Failed).count(),
                    "app": info.target.as_ref().map(|a| a.name.clone()).unwrap_or_default(),
                }),
            );
            let cache = crate::workflow::replay_cache();
            if ok
                && !info.dry
                && !info.requires_fresh_work
                && !info.trace.is_empty()
                && !request.starts_with("Workflow:")
                && !request.starts_with("Correction for")
            {
                cache.record(
                    &request,
                    &info.trace,
                    info.start_place.0.as_deref().or(info.target.as_ref().map(|a| a.name.as_str())),
                    info.start_place.1.as_deref(),
                    info.start_place.2.as_deref(),
                    &info.secrets,
                );
            } else {
                cache.outcome(ok);
            }
            history::history().add(Entry {
                id: uuid::Uuid::new_v4().to_string(),
                date: info.started_at.unwrap_or_else(chrono::Utc::now).to_rfc3339(),
                request: if info.dry {
                    format!("Dry run: {request}")
                } else if info.background {
                    format!("In the background: {request}")
                } else {
                    request.clone()
                },
                answer: text.to_string(),
                ok,
                steps: steps.iter().map(|s| s.text.clone()).collect(),
                app: info.target.as_ref().map(|a| a.name.clone()),
                result: run_result,
                trace: (!info.trace.is_empty()).then(|| info.trace.clone()),
                read_text: info.read_text.as_ref().map(|t| t.chars().take(8000).collect()),
                requires_fresh_work: info.requires_fresh_work,
                task: task_with_follow_ups(info.continuation.as_ref().map(|c| c.task.clone().unwrap_or(c.request.clone())), &request, &info.follow_ups),
            }.redacted(&info.secrets));
        }
        self.changed();
        self.last_background.store(info.background, Ordering::SeqCst);
        (self.emit)(Event::Finished { answer: text.to_string(), ok, background: info.background });
        // Something added as the task ended was never seen: it carries on with that, rather than losing it.
        let late = std::mem::take(&mut *self.added.lock());
        if !late.is_empty() && text != "Stopped" && !info.test && !info.dry && info.qa.is_none() {
            self.log("carrying on with what the user added at the end");
            let me = self.clone();
            tokio::spawn(async move {
                tokio::time::sleep(Duration::from_millis(500)).await;
                me.follow_up(&late.join("\n"));
            });
            return;
        }
        // Out of steps or stuck isn't the end of the task: carry on by itself a few times.
        let progressed = steps.iter().filter(|s| s.state == StepState::Ok).count() >= 10;
        let limit = if progressed { 12 } else { 3 };
        let n = self.auto_continues.load(Ordering::Relaxed);
        if !ok
            && !info.test
            && !info.dry
            && info.qa.is_none()
            && n < limit
            && (text.starts_with("Ran out of steps") || text.starts_with("I got stuck on"))
        {
            self.auto_continues.store(n + 1, Ordering::Relaxed);
            self.log(&format!("auto-continue {}/{limit} after: {}", n + 1, text.chars().take(60).collect::<String>()));
            let me = self.clone();
            tokio::spawn(async move {
                tokio::time::sleep(Duration::from_millis(1500)).await;
                if !me.is_running() {
                    me.context.lock().continuation = history::history().latest();
                    me.submit("continue", RunOptions { auto: true, background: Some(info.background), ..Default::default() });
                }
            });
        }
    }

    /// The application tracker, shown in the result card.
    pub fn show_applications(&self) {
        self.show_card(crate::applications::card());
    }

    pub(crate) fn record_trace(&self, action: &crate::reply::Action, target: Option<Target>) {
        use crate::reply::ActionExt;
        let kind = action.kind();
        if !["open_app", "open_url", "click", "type", "key", "scroll", "shell", "assert"].contains(&kind.as_str()) {
            return;
        }
        if kind == "assert" && !action.flag("pass") {
            return;
        }
        let mut step = WorkflowStep::new(if kind == "assert" { "expect" } else { &kind });
        step.name = action.string("name");
        step.url = action.string("url");
        step.text = action.string("text");
        step.keys = action.string("keys");
        step.dir = action.string("dir");
        step.script = action.string("cmd");
        step.submit = action.get("submit").and_then(|v| v.as_bool());
        if action.contains_key("id") {
            step.target = target;
        }
        if kind == "click" && step.target.is_none() {
            return;
        }
        self.current.lock().trace.push(step);
    }

    /// Pauses for the user's answer (None = no answer / cancelled). QA runs take the first option.
    pub(crate) async fn ask_user(&self, text: &str, options: Vec<String>, sensitive: bool) -> Option<String> {
        if self.current.lock().qa.is_some() {
            return options.first().cloned();
        }
        let previous = self.phase();
        self.log(&format!(
            "  waiting for your answer: {}",
            if sensitive { "(hidden)".to_string() } else { text.chars().take(120).collect() }
        ));
        self.buddy.bubble(Some("need your input"), 600.0);
        let (tx, rx) = oneshot::channel();
        *self.answer_waiter.lock() = Some(tx);
        {
            let mut u = self.ui.lock();
            u.phase = Phase::Waiting;
            u.question = Some(Question { text: text.into(), options, sensitive });
        }
        self.changed();
        (self.emit)(Event::Question);
        let reply = rx.await.ok().flatten();
        self.buddy.bubble(None, 0.0);
        if self.is_running() {
            self.ui.lock().phase = if previous == Phase::Waiting { Phase::Acting } else { previous };
            self.changed();
        }
        reply
    }

    /// Shows every answer on the form and waits for Submit or Edit.
    pub(crate) async fn review_card(&self, title: &str, items: Vec<(String, String)>) -> (bool, Option<String>) {
        let (tx, rx) = oneshot::channel();
        if let Some(old) = self.review_waiter.lock().replace(tx) {
            let _ = old.send((false, None));
        }
        {
            let mut u = self.ui.lock();
            u.review = Some(Review { title: title.into(), items });
            u.phase = Phase::Waiting;
        }
        self.changed();
        (self.emit)(Event::Question);
        let r = rx.await.unwrap_or((false, None));
        if self.is_running() {
            self.ui.lock().phase = Phase::Acting;
            self.changed();
        }
        r
    }
}

pub fn write_report(r: &QaReport, out: &std::path::Path) {
    let _ = std::fs::write(out, serde_json::to_string_pretty(r).unwrap_or_default());
}

/// The set of things a run was shown and the places it worked in (for crediting memory).
#[derive(Default)]
pub(crate) struct Seen {
    pub facts: HashSet<String>,
    pub hosts: HashSet<String>,
    pub apps: HashSet<String>,
}

/// The bounding box of a drawn loop.
pub fn circle_bounds(points: &[Point]) -> Rect {
    if points.is_empty() {
        return Rect::default();
    }
    let (mut x0, mut y0, mut x1, mut y1) = (f64::MAX, f64::MAX, f64::MIN, f64::MIN);
    for p in points {
        x0 = x0.min(p.x);
        y0 = y0.min(p.y);
        x1 = x1.max(p.x);
        y1 = y1.max(p.y);
    }
    Rect::new(x0, y0, x1 - x0, y1 - y0)
}

/// The whole task as a later run should see it: what it was, and everything the user added.
fn task_with_follow_ups(task: Option<String>, request: &str, follow_ups: &[String]) -> Option<String> {
    if follow_ups.is_empty() {
        return task;
    }
    let added = follow_ups.iter().map(|f| format!("- {f}")).collect::<Vec<_>>().join("
");
    Some(format!("{}
The user then added:
{added}", task.as_deref().unwrap_or(request)))
}

#[cfg(test)]
mod follow_up_tests {
    use super::task_with_follow_ups;

    #[test]
    fn follow_ups_stay_with_the_task() {
        assert_eq!(task_with_follow_ups(None, "book a table", &[]), None);
        assert_eq!(task_with_follow_ups(Some("plan a trip".into()), "continue", &[]).as_deref(), Some("plan a trip"));
        let both = task_with_follow_ups(None, "book a table", &["for four".into(), "at eight".into()]).unwrap();
        assert_eq!(both, "book a table
The user then added:
- for four
- at eight");
    }
}
