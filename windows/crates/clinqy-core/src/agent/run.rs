//! The loop: observe → model → act → report, up to 80 turns; with the Mac app's speedups (early start of the
//! first action while the reply streams in, diffs instead of full listings) and recovery (loop detection,
//! "you said work remains", unpasted screenshots, label-instead-of-answer).

use super::*;
use crate::memory;
use crate::observation::{self, Observation};
use crate::page::Page;
use crate::platform::{Element, Rect};
use crate::reply::{self, Action, ActionExt};
use std::collections::HashMap;
use tokio::sync::mpsc;

/// Dropping a parent run must also cancel its in-flight model request.
struct AbortOnDrop<T>(tokio::task::JoinHandle<T>);
impl<T> Drop for AbortOnDrop<T> {
    fn drop(&mut self) {
        self.0.abort();
    }
}

/// What the actions of one turn work against; refreshed as they go.
#[derive(Clone, Default)]
pub(crate) struct Ctx {
    pub app: Option<AppRef>,
    pub elements: Vec<Element>,
    pub fingerprint: u64,
    pub page: Option<Page>,
    pub web_area: Option<Rect>,
    /// Page fields typed into this turn (index → text), re-checked because autofill can change them later.
    pub typed: Vec<(i64, String)>,
    /// The page list the model's w-ids refer to.
    pub seen: Option<Page>,
}

/// Per-run state the actions read and write.
/// What a turn's reply means for the task.
#[derive(Debug, PartialEq)]
enum Ending {
    NotYet,
    Finish,
    /// It says it's done, right after an action failed: it gets one chance to show that.
    Check,
    Failed,
}

fn ending(done: bool, gave_up: bool, last_action_failed: bool, warned: bool) -> Ending {
    match (done, gave_up, last_action_failed, warned) {
        (false, ..) => Ending::NotYet,
        (true, true, ..) => Ending::Failed,
        (true, false, false, _) => Ending::Finish,
        (true, false, true, false) => Ending::Check,
        (true, false, true, true) => Ending::Failed,
    }
}

#[derive(Default)]
pub(crate) struct RunState {
    /// The last action that ran failed, and nothing has worked since: what it said.
    pub last_failed: Option<String>,
    /// Told once to check for itself before claiming the task is done.
    pub warned_of_failure: bool,
    pub request: String,
    pub workers: Option<crate::delegation::Pool>,
    pub dry: bool,
    pub test: bool,
    pub qa: bool,
    pub user_confirmed: bool,
    pub reviewed_form: bool,
    pub opened_tab: bool,
    pub owned_tab: Option<i64>,
    pub memory_checked: HashSet<String>,
    pub profile_offered: HashSet<String>,
    pub seen: Seen,
    pub last_page_memory: String,
    pub form_seen: HashMap<String, (String, String, String)>,
    pub agent_entered: HashSet<String>,
    pub user_answers: Vec<String>,
    pub last_target: Option<Target>,
    pub review_in_tests: bool,
    pub save_in_tests: bool,
    pub pushed_on: u32,
    pub snap_pushes: u32,
}

pub(crate) struct ActionResult {
    pub ok: bool,
    pub summary: String,
    pub look: bool,
}

impl ActionResult {
    pub fn ok(summary: impl Into<String>) -> ActionResult {
        ActionResult { ok: true, summary: summary.into(), look: false }
    }
    pub fn fail(why: impl AsRef<str>) -> ActionResult {
        ActionResult { ok: false, summary: format!("FAILED: {}", why.as_ref()), look: false }
    }
}

/// "What is…?", "tell me…", "who/where/when/which/how…": wants information back.
pub fn is_question(request: &str) -> bool {
    let r = request.trim().to_lowercase();
    r.ends_with('?')
        || regex::Regex::new(r"^(so |and |ok |okay )?(what|what's|whats|who|who's|where|when|which|how|tell me|do you know|remind me)\b")
            .unwrap()
            .is_match(&r)
}

/// A short title with nothing in it ("Your roll number", "Found it").
pub fn looks_like_label(say: &str) -> bool {
    let words: Vec<&str> = say.split_whitespace().collect();
    if words.is_empty() {
        return true;
    }
    if words.len() > 5 || say.chars().any(|c| c.is_ascii_digit()) || say.contains('@') {
        return false;
    }
    const VERBS: &[&str] = &["is", "are", "was", "were", "it's", "isn't", "can't", "don't", "no", "not", "yes", "has", "have"];
    !words.iter().any(|w| VERBS.contains(&w.to_lowercase().trim_matches(|c: char| c.is_ascii_punctuation()).to_string().as_str()))
}

/// A final summary that itself lists work still to do, unless what's left needs the user.
pub fn says_unfinished(say: &str) -> bool {
    let unfinished = regex::Regex::new(r"(?i)\b(still to do|still need to|remaining steps?|steps? (left|remaining)|left to do|not (yet )?(done|finished|written|pasted|added)|partly done|partially (done|complete)|next,? i('ll| will)|haven't (yet )?(done|finished|captured|added|started|pasted)|(rest|doc|write-?up|steps?)\b[^.]{0,40}\bremains\b|stopped (there|here|at)|got through (steps? )?\d+\s*[-–]\s*\d+ of)").unwrap();
    let remain = regex::Regex::new(r"(?i)\bremain\b( (the same|unchanged|open|running|available|in place))?").unwrap();
    let needs_user = regex::Regex::new(r"(?i)\b(you need to|you'll need to|you have to|waiting (for|on) you|your (password|otp|code|login|approval|confirmation)|log ?in|sign ?in|confirm(ation)? (link|email)|click the (confirm|link))\b").unwrap();
    let remains_bare = remain.captures_iter(say).any(|c| c.get(1).is_none());
    (unfinished.is_match(say) || remains_bare) && !needs_user.is_match(say)
}

/// Requests whose point is what ends up on screen ("open Spotify", "search …"): leave that app in front.
pub fn keeps_front_app(request: &str) -> bool {
    regex::Regex::new(r"(?i)^\s*(please |can you |could you )?(open|launch|start|switch to|go to|take me to|show( me)?|play|search|find|look up|google|navigate|bring up|pull up)\b")
        .unwrap()
        .is_match(request)
}

/// A request that may lead to an application form.
pub fn may_meet_forms(text: &str) -> bool {
    regex::Regex::new(r"(?i)\b(appl(y|ication)|job|internship|intern|form|fill|resume|cv|role|position|opening|hiring|linkedin|naukri|greenhouse|lever|workday)")
        .unwrap()
        .is_match(text)
}

/// Steps worth starting while the model is still writing (they act on the screen, not outside it).
pub fn starts_early(a: &Action) -> bool {
    ["click", "type", "choose", "scroll", "key", "open_url", "open_app", "autofill", "upload", "read", "review"]
        .contains(&a.kind().as_str())
}

pub fn qa_prompt(name: &str, test: &str) -> String {
    format!(
        "QA TEST “{name}”. You are an automated UI tester. Carry out these steps exactly as written, in order:\n{test}\n\nFor every line that states an expectation (Expect / Check / Verify / Should…), look at the screen and report it\nwith {{\"do\":\"assert\",\"text\":\"<the expected text, as it would literally appear on screen>\",\"pass\":true|false,\"note\":\"<what you saw>\"}}.\nPrefer exact on-screen text (a heading, label, value, title or URL), so the check can be repeated automatically.\nNobody is watching: never ask anything. If a step can't be done, assert it as failed with a note, then finish.\nFinish with done:true and a one-line verdict."
    )
}

fn is_web_ref(v: Option<&serde_json::Value>) -> bool {
    v.and_then(|v| v.as_str()).map(|s| s.to_lowercase().starts_with('w')).unwrap_or(false)
}

pub(crate) fn web_index(v: Option<&serde_json::Value>) -> Option<i64> {
    let s = v?.as_str()?;
    if !s.to_lowercase().starts_with('w') {
        return None;
    }
    s[1..].parse().ok()
}

impl Agent {
    pub(crate) async fn run(self: &Arc<Self>, request: String, opts: &RunOptions) {
        if self.platform.screen_locked() {
            return self.finish(false, "The PC is locked — unlock it and run again");
        }
        self.buddy.set_mood(Mood::Thinking);
        let (qa, test, dry) = {
            let c = self.current.lock();
            (c.qa.is_some(), c.test, c.dry)
        };
        let mut rs = RunState {
            request: request.clone(),
            dry,
            test,
            qa,
            review_in_tests: opts.review_in_tests,
            save_in_tests: opts.save_in_tests,
            ..Default::default()
        };
        // Don't start clicking around during a call unless the user says so (or memory says it's fine).
        let calls_ok = memory::facts().iter().any(|f| {
            let f = f.to_lowercase();
            f.contains("ok to work") && (f.contains("call") || f.contains("screen shar"))
        });
        if !qa && !calls_ok && self.platform.mic_in_use() {
            let reply = self
                .ask_user(
                    "You seem to be on a call (the mic is in use). Should I go ahead and use the screen?",
                    vec!["Go ahead".into(), "Not now".into()],
                    false,
                )
                .await;
            match reply {
                Some(r) if r.to_lowercase().starts_with("go") || crate::safety::is_yes(&r) => self.set_phase(Phase::Thinking),
                _ => return self.finish(false, "Okay, I'll wait until you're off the call"),
            }
        }
        let me = self.clone();
        let (model, provider) = (opts.model.clone(), opts.provider);
        let session = match tokio::task::spawn_blocking(move || me.session(model.as_deref(), provider)).await {
            Ok(Ok(s)) => Arc::new(s),
            Ok(Err(e)) => return self.finish(false, &e.to_string()),
            Err(e) => return self.finish(false, &e.to_string()),
        };
        rs.workers = Some(crate::delegation::Pool::new(
            request.clone(),
            session.provider,
            crate::config::value("DELEGATE_MODEL").unwrap_or_else(|| "sonnet".into()),
        ));
        // The next request's session starts warming now.
        self.prewarm();

        let target = self.current.lock().target.clone().filter(|_| !self.hands.hidden());
        let mut app = target.clone().or_else(|| self.platform.front_app());
        let mut message = self.intro(&request, &mut rs);
        let mut wants_look = false;
        let mut failures = 0u32;
        let (mut last_signature, mut repeats, mut same_runs) = (String::new(), 0u32, 0u32);
        let mut escalated: HashSet<String> = HashSet::new();
        let mut asked_for_answer = false;
        let mut last_screen = String::new();
        let mut shown: Option<Observation> = None;
        let (mut last_full_turn, mut looked_last_turn) = (0usize, false);
        let mut last_first = String::new();
        let max_turns = 80usize;

        for turn in 0..max_turns {
            self.hold_if_paused().await;
            if turn == max_turns - 10 {
                message += &format!("\n({turn} of {max_turns} steps used. If the current approach isn't getting closer, change it now. A long task that is making progress just carries on in a new run when these run out, so don't finish early for that; finish only if it truly can't be done. Before the steps run out, paste any snaps not yet in the doc.)");
            }
            let t_obs = Instant::now();
            let obs = Observation::capture(&*self.platform, app.as_ref()).await;
            let observe_ms = t_obs.elapsed().as_millis();
            if observe_ms > 400 {
                self.log(&format!("  observe: {observe_ms} ms"));
            }
            let continuation = self.current.lock().continuation.is_some();
            if turn == 0 && !continuation && !qa {
                let place = (
                    obs.app.as_ref().map(|a| a.name.clone()),
                    obs.page.as_ref().map(|p| p.url.clone()),
                    obs.page.as_ref().map(|p| p.title.clone()),
                );
                self.current.lock().start_place = place.clone();
                let ctx = self.context.lock().clone();
                let cache = crate::workflow::replay_cache();
                if !test
                    && !dry
                    && ctx.selected_text.is_none()
                    && ctx.selected_files.is_empty()
                    && crate::config::on("WORKFLOW_FIRST", true)
                {
                    if let Some(w) = cache.replayable(&request, place.0.as_deref(), place.1.as_deref(), place.2.as_deref()) {
                        self.log(&format!(
                            "replay-first: this exact request worked here before — replaying {} steps, no model",
                            w.steps.len()
                        ));
                        self.push_step("Done exactly this before — replaying it, no model needed", StepState::Info);
                        session.close();
                        Box::pin(self.replay_or_heal(w, HashMap::new(), None, opts)).await;
                        return;
                    }
                }
                if let Some(hint) = cache.hint(&request, place.0.as_deref(), place.1.as_deref(), place.2.as_deref()) {
                    message += &hint;
                    self.log("replay hint offered");
                }
            }
            // Know-how saved for the site or app the task is in now, the first time it gets there.
            let host = obs.page.as_ref().map(|p| memory::bare_host(&p.url)).filter(|h| !h.is_empty());
            if let Some(h) = &host {
                rs.seen.hosts.insert(h.clone());
            }
            if let Some(a) = &obs.app {
                rs.seen.apps.insert(a.name.clone());
            }
            let notes: Vec<String> = memory::scoped(obs.app.as_ref().map(|a| a.name.as_str()), host.as_deref())
                .into_iter()
                .filter(|n| !rs.seen.facts.contains(n))
                .collect();
            if !notes.is_empty() {
                rs.seen.facts.extend(notes.iter().cloned());
                let place = host.clone().or(obs.app.as_ref().map(|a| a.name.clone())).unwrap_or_else(|| "this app".into());
                message += &format!(
                    "\nNotes you saved for {place} (how to work it; follow them here):\n{}",
                    notes.iter().map(|n| format!("- {n}")).collect::<Vec<_>>().join("\n")
                );
                self.log(&format!("  memory: {} note(s) for {place}", notes.len()));
            }
            if let (Some(page), Some(h)) = (&obs.page, &host) {
                track_form(&mut rs, page, h);
            }
            // Facts that answer this page's fields, shown with it.
            if let Some(page) = &obs.page {
                let mut labels: Vec<String> = page
                    .elements
                    .iter()
                    .filter(|e| e.editable || e.dropdown || e.question.is_some())
                    .flat_map(|e| [e.question.clone(), e.placeholder.clone(), if e.editable { Some(e.text.clone()) } else { None }])
                    .flatten()
                    .collect();
                labels.push(page.title.clone());
                labels.extend(page.headings.iter().take(6).cloned());
                let signature = labels.join("\u{1}");
                if signature != rs.last_page_memory {
                    rs.last_page_memory = signature;
                    let found = memory::for_page(&labels, &rs.seen.facts, obs.app.as_ref().map(|a| a.name.as_str()), host.as_deref(), 6);
                    if !found.is_empty() {
                        rs.seen.facts.extend(found.iter().cloned());
                        message += &format!(
                            "\nFrom memory, for what's on this page (use these; no need to recall them):\n{}",
                            found.iter().map(|f| format!("- {f}")).collect::<Vec<_>>().join("\n")
                        );
                        self.log(&format!("  memory: {} fact(s) for this page", found.len()));
                    }
                }
                let fields: Vec<String> =
                    page.elements.iter().filter(|e| e.editable).map(|e| format!("w{} {}", e.index, e.extra)).collect();
                self.log(&format!(
                    "  page: {} · {} elements{}",
                    page.title.chars().take(50).collect::<String>(),
                    page.elements.len(),
                    if fields.is_empty() {
                        String::new()
                    } else {
                        format!(" · fields: {}", fields.join(" | ").chars().take(300).collect::<String>())
                    }
                ));
            }
            let known = obs.page.as_ref().map(|p| p.elements.len()).unwrap_or(obs.elements.len());
            if known < 6 || failures >= 2 {
                wants_look = true;
            }
            // The first look shows what the user circled; after that it's just in the request text.
            let circled = if turn == 0 { self.context.lock().circled.clone() } else { None };
            if let Some(c) = &circled {
                wants_look = true;
                let r = super::circle_bounds(c);
                let inside: Vec<&str> = obs.elements.iter().filter(|e| e.rect.intersects(&r)).map(|e| e.id.as_str()).take(30).collect();
                message += &format!(
                    "\nInside the circled area: {}",
                    if inside.is_empty() { "no listed elements (use the screenshot).".to_string() } else { inside.join(", ") }
                );
            }
            let mut image: Option<String> = None;
            if wants_look {
                if let Some(a) = &obs.app {
                    image = self.platform.look(a, &obs.elements, circled.as_deref()).await;
                }
            }
            wants_look = false;
            // An unchanged screen is one line, not the whole list again.
            let full = obs.text();
            let unchanged = full == last_screen;
            let mut screen = "Screen: unchanged since your last look.".to_string();
            if !unchanged || image.is_some() {
                let fresh = turn == 0 || image.is_some() || looked_last_turn || failures > 0 || turn - last_full_turn >= 6;
                screen = if fresh { full.clone() } else { observation::screen_text(&obs, shown.as_ref()).unwrap_or_else(|| full.clone()) };
                if screen == full {
                    last_full_turn = turn;
                } else {
                    self.log(&format!("  screen: changes only ({} of {} chars)", screen.len(), full.len()));
                }
            }
            last_screen = full;
            looked_last_turn = image.is_some();
            // Anything the user added mid-task comes first: it can change the plan.
            let added: Vec<String> = std::mem::take(&mut *self.added.lock());
            if !added.is_empty() {
                rs.workers = Some(crate::delegation::Pool::new(
                    request.clone(),
                    session.provider,
                    crate::config::value("DELEGATE_MODEL").unwrap_or_else(|| "sonnet".into()),
                ));
                message = format!(
                    "The user added while you were working (take it into account; it may change the plan):\n{}\n\n{message}",
                    added.iter().map(|a| format!("- {a}")).collect::<Vec<_>>().join("\n")
                );
            }
            let turn_text = format!(
                "{message}\n\n{screen}{}{}",
                match (&image, &circled) {
                    (Some(_), Some(_)) =>
                        "\n(Screenshot attached: red boxes are tagged with the same e<N> ids. The yellow loop is what the user circled.)",
                    (Some(_), None) => "\n(Screenshot attached: red boxes are tagged with the same e<N> ids.)",
                    _ => "",
                },
                crate::prompt::REPLY_JSON_ONLY
            );

            self.set_phase(Phase::Thinking);
            self.buddy.set_mood(Mood::Thinking);
            let t0 = Instant::now();
            let mut ctx = Ctx {
                app: obs.app.clone(),
                elements: obs.elements.clone(),
                fingerprint: obs.fingerprint,
                page: obs.page.clone(),
                web_area: obs.web_area,
                typed: vec![],
                seen: obs.page.clone(),
            };
            shown = Some(obs);
            // The reply streams in: its first action starts as soon as it's written.
            let (ptx, mut prx) = mpsc::unbounded_channel::<String>();
            let early_on = crate::config::on("EARLY_START", true);
            let s = session.clone();
            let send_text = turn_text.clone();
            let shot = image.clone();
            let me = self.clone();
            let measured_generation = self.generation.load(Ordering::Relaxed);
            let mut replying = AbortOnDrop(tokio::spawn(async move {
                let start = Instant::now();
                let result = s.send(&send_text, shot, if early_on { Some(ptx) } else { None }).await;
                if me.generation.load(Ordering::Relaxed) == measured_generation {
                    me.current.lock().model_seconds += start.elapsed().as_secs_f64();
                }
                result
            }));
            let mut early: Option<(Action, ActionResult, Option<Target>)> = None;
            let reply_result;
            loop {
                tokio::select! {
                    biased;
                    r = &mut replying.0 => { reply_result = Some(r); break; }
                    p = prx.recv() => {
                        let Some(text) = p else { continue };
                        let Some(first) = reply::first_action_in_partial(&text) else { continue };
                        if starts_early(&first) && reply::canonical(&first) != last_first && self.added.lock().is_empty() {
                            self.set_phase(Phase::Acting);
                            self.buddy.set_mood(Mood::Acting);
                            self.log(&format!("  early start: {} (while the model writes the rest)", reply::brief(&first)));
                            rs.last_target = None;
                            let result = self.perform(&first, &mut ctx, &mut rs).await;
                            early = Some((first, result, rs.last_target.clone()));
                        }
                        // Only the first action starts early; the rest waits for the whole reply.
                        while prx.try_recv().is_ok() {}
                        let r = (&mut replying.0).await;
                        reply_result = Some(r);
                        break;
                    }
                }
            }
            let reply = match reply_result {
                Some(Ok(Ok(r))) => r,
                Some(Ok(Err(e))) => return self.finish(false, &e.to_string()),
                Some(Err(e)) => return self.finish(false, &e.to_string()),
                None => return self.finish(false, "no reply"),
            };
            let ms = t0.elapsed().as_millis() as u64;
            self.log(&format!("turn {turn} · {ms} ms · {}", reply.chars().take(300).collect::<String>()));
            crate::replay::turn(&reply, ms);
            {
                let mut c = self.current.lock();
                c.turns += 1;
                if image.is_some() {
                    c.looks += 1;
                }
            }

            let Some(json) = reply::parse(&reply) else {
                message = format!(
                    "Your last reply wasn't a JSON object. Reply with JSON only.{}",
                    early
                        .as_ref()
                        .map(|e| format!("\n(Its first step already ran: {} → {})", reply::brief(&e.0), e.1.summary))
                        .unwrap_or_default()
                );
                continue;
            };
            let say = json.get("say").and_then(|v| v.as_str()).unwrap_or("").to_string();
            let actions: Vec<Action> = json
                .get("actions")
                .and_then(|v| v.as_array())
                .map(|a| a.iter().filter_map(|x| x.as_object().cloned()).collect())
                .unwrap_or_default();
            let is_done = json.get("done").and_then(|v| v.as_bool()).unwrap_or(false);
            if actions.is_empty() {
                failures = 0;
            }
            if !say.is_empty() && !is_done {
                self.set_narration(&say);
            }

            // A loop is the same actions three times with nothing changing.
            let signature: String = actions.iter().map(reply::canonical).collect();
            let same = !actions.is_empty() && signature == last_signature;
            same_runs = if same { same_runs + 1 } else { 0 };
            repeats = if same && (unchanged || failures > 0) { repeats + 1 } else { 0 };
            last_signature = signature.clone();
            if !actions.is_empty()
                && ((escalated.contains(&signature) && repeats >= 1) || ((repeats >= 2 || same_runs >= 12) && escalated.len() >= 2))
            {
                return self.finish(false, "I kept trying the same thing, so I stopped");
            }
            if repeats >= 2 || same_runs >= 12 {
                let why = if repeats >= 2 { "3× with nothing changing".to_string() } else { format!("{}×", same_runs + 1) };
                escalated.insert(signature);
                repeats = 0;
                same_runs = 0;
                wants_look = true;
                self.log(&format!("  loop: same actions {why} — asking for another method"));
                self.push_step("Same step repeated — trying another way", StepState::Info);
                message = format!(
                    "Your last reply repeated the same actions again ({}) and they aren't getting anywhere, so they were NOT run again. That approach failed: don't send it again. Use a different method, in this order: the keyboard (tab/shift+tab to reach the control, space or enter to press it, arrows in lists, esc to close a popup), then the other id for it (its e-id from UI Automation instead of the w-id, or the reverse), then click by x/y on the screenshot attached now. If the goal can't be reached, finish with done:true and say what's blocking.{}",
                    actions.iter().map(reply::brief).collect::<Vec<_>>().join(", "),
                    early.as_ref().map(|e| format!(" (Only its first step had already started: {} → {})", reply::brief(&e.0), e.1.summary)).unwrap_or_default()
                );
                continue;
            }

            if !actions.is_empty() {
                self.set_phase(Phase::Acting);
                self.buddy.set_mood(Mood::Acting);
            }
            let mut results: Vec<String> = vec![];
            let mut cut_short = false;
            let early_is_first = early
                .as_ref()
                .map(|e| actions.first().map(|a| reply::canonical(a) == reply::canonical(&e.0)).unwrap_or(false))
                .unwrap_or(false);
            if let Some(e) = &early {
                if !early_is_first {
                    results.push(format!("(already done while you were writing: {} → {})", reply::brief(&e.0), e.1.summary));
                    if !e.1.ok {
                        failures += 1;
                    }
                }
            }
            last_first = actions.first().map(reply::canonical).unwrap_or_default();
            let mut early = early;
            for (i, action) in actions.iter().enumerate() {
                self.hold_if_paused().await;
                if !self.added.lock().is_empty() {
                    results.push(format!("(stopped before step {}: the user added something — see above)", i + 1));
                    break;
                }
                rs.last_target = None;
                let mut action = action.clone();
                let kind = action.kind();
                // click/type/open_* already wait for the screen to settle; a long wait stacked on top is dead time.
                if kind == "wait"
                    && i > 0
                    && ["click", "type", "open_url", "open_app", "key"].contains(&actions[i - 1].kind().as_str())
                    && action.num("ms").unwrap_or(600.0) > 1000.0
                {
                    action.insert("ms".into(), serde_json::json!(1000));
                }
                // The ids the model gave point into the page list it was shown; use the same element's id now.
                if is_web_ref(action.get("id")) {
                    if let (Some(seen), Some(now)) = (&ctx.seen, &ctx.page) {
                        let n = web_index(action.get("id"));
                        match n.and_then(|n| crate::page::rematch(n, seen, now)) {
                            Some(id) => {
                                if Some(id) != n {
                                    self.log(&format!("    w{} is now w{id} (the page re-listed)", n.unwrap_or(-1)));
                                    action.insert("id".into(), serde_json::json!(format!("w{id}")));
                                }
                            }
                            None => {
                                let was = n
                                    .and_then(|n| seen.element(n))
                                    .map(|e| format!(" ({} {:?})", e.role, e.text.chars().take(40).collect::<String>()))
                                    .unwrap_or_default();
                                results.push(format!(
                                    "{}. (not done: the page changed after the steps above, and {}{was} isn't there anymore; the rest of this batch was skipped — the fresh page is below)",
                                    i + 1,
                                    action.get("id").map(|v| v.to_string()).unwrap_or_default()
                                ));
                                cut_short = true;
                                break;
                            }
                        }
                    }
                }
                // A trailing look after page actions: the page list next turn is exact and fresh.
                if kind == "look" && i > 0 && self.page_list_suffices(&ctx, &actions[..i]) {
                    results.push(format!("{}. look skipped — the fresh page list below shows the result (send look on its own if you need pixels: pictures, canvas, iframes, a native dialog)", i + 1));
                    continue;
                }
                let result = if i == 0 && early_is_first {
                    let e = early.take().unwrap();
                    rs.last_target = e.2;
                    e.1
                } else {
                    self.perform(&action, &mut ctx, &mut rs).await
                };
                if result.ok && !dry {
                    self.record_trace(&action, rs.last_target.clone());
                }
                if result.ok && ["click", "type", "key", "choose", "upload", "scroll", "shell", "fill", "autofill"].contains(&kind.as_str())
                {
                    self.current.lock().opened_last = false;
                }
                if result.look {
                    wants_look = true;
                }
                results.push(format!("{}. {}", i + 1, result.summary));
                rs.last_failed = (!result.ok).then(|| result.summary.clone());
                if !result.ok {
                    failures += 1;
                    break;
                }
                failures = 0;
                // The user's answer can change the plan ("it's saved, just click the field"): what was planned
                // after the question waits for the next turn.
                if kind == "ask" && i + 1 < actions.len() && result.summary.starts_with("the user answered") {
                    results.push("(the rest of this batch waits: plan it again with the answer above)".to_string());
                    cut_short = true;
                    break;
                }
                // Another app came to the front (a link opening the browser): the rest was planned for the old screen.
                if ["click", "key", "type"].contains(&kind.as_str()) && !dry && i + 1 < actions.len() {
                    if let Some(current) = &ctx.app {
                        if let Some(other) = self.platform.handoff(current) {
                            self.log(&format!("    {} came to the front", other.name));
                            results.push(format!(
                                "({} came to the front, so the rest of this batch was skipped — its screen is below)",
                                other.name
                            ));
                            ctx.app = Some(other);
                            cut_short = true;
                            break;
                        }
                    }
                }
                // Forms re-render as they're filled: before the next step by w-id, list the page again.
                if ["type", "choose", "click", "upload", "autofill"].contains(&kind.as_str())
                    && ctx.page.is_some()
                    && !dry
                    && actions[i + 1..].iter().any(|a| is_web_ref(a.get("id")))
                {
                    self.relist(&mut ctx).await;
                }
            }
            app = ctx.app.clone();
            let results_text = |r: &Vec<String>| if r.is_empty() { String::new() } else { format!("Results:\n{}\n", r.join("\n")) };
            if is_done && failures == 0 && (!self.added.lock().is_empty() || cut_short) {
                message = format!(
                    "Results:\n{}\n{}",
                    results.join("\n"),
                    if cut_short {
                        "(You were about to finish, but not all of your last steps ran.)"
                    } else {
                        "(You were about to finish, but the user added something.)"
                    }
                );
                continue;
            }
            // A question answered with a label instead of the answer: ask once for the answer.
            if is_done && failures == 0 && !asked_for_answer && is_question(&request) && looks_like_label(&say) {
                asked_for_answer = true;
                message = format!(
                    "{}Your final say (\"{say}\") is a label, not the answer. The user asked a question: finish again with done:true and a say that contains the answer itself, as a full sentence (e.g. \"Your roll number is 1601…\").",
                    results_text(&results)
                );
                continue;
            }
            // Screenshots taken for a write-up but not in the doc are lost work: paste them first.
            let unpasted = self.snaps.lock().0.iter().filter(|s| !s.pasted).count();
            if is_done && failures == 0 && unpasted > 0 && rs.snap_pushes < 2 {
                rs.snap_pushes += 1;
                self.log(&format!("  {unpasted} screenshots not in the doc yet — pasting before finishing"));
                message = format!(
                    "{}You were about to finish, but {unpasted} screenshot{} not in the write-up doc yet. Go to the doc (open_app its browser, switch to its tab, or open_url https://docs.new if there is none), click at the end of the document body, key ctrl+end, then paste_snaps; check with look that they went in. Then carry on with any steps of the task that remain; finish only when everything is done.",
                    results_text(&results),
                    if unpasted == 1 { " is" } else { "s are" }
                );
                continue;
            }
            if is_done
                && failures == 0
                && rs.pushed_on < 3
                && (says_unfinished(&say)
                    || says_unfinished(&reply.chars().rev().take(1500).collect::<String>().chars().rev().collect::<String>()))
            {
                rs.pushed_on += 1;
                self.log(&format!("  not done yet: “{}” — carrying on", say.chars().take(80).collect::<String>()));
                message = format!(
                    "{}You were about to finish, but your own summary says work remains (\"{}\"). The user wants the whole task done without having to say continue: do the remaining steps now. Finish only when everything is done, or when something truly needs the user (say exactly what).",
                    results_text(&results),
                    say.chars().take(200).collect::<String>()
                );
                continue;
            }
            let gave_up = json.get("failed").and_then(|v| v.as_bool()).unwrap_or(false);
            match ending(is_done && failures == 0, gave_up, rs.last_failed.is_some() && !qa, rs.warned_of_failure) {
                Ending::Failed => return self.finish(false, if say.is_empty() { "I couldn't do that" } else { &say }),
                Ending::Check => {
                    rs.warned_of_failure = true;
                    self.log("  said done after a failed action — checking");
                    message = format!(
                        "{}You were about to finish, but your last action failed ({}). Don't answer from what you already know as if it had worked. Try another way, or check with a read or look that it's really done. If you can't, finish with done:true and failed:true and say what stopped you.",
                        results_text(&results),
                        rs.last_failed.as_deref().unwrap_or("").chars().take(200).collect::<String>()
                    );
                    continue;
                }
                Ending::Finish | Ending::NotYet => {}
            }
            if is_done && failures == 0 {
                if let Some(workers) = rs.workers.as_ref().filter(|w| w.pending()) {
                    self.set_phase(Phase::Thinking);
                    message = self.collect_workers(workers, &[], true, 300).await;
                    self.push_step(&("Worker results:\n".to_owned() + &message), StepState::Info);
                    continue;
                }
                self.finish(true, if say.is_empty() { "Done" } else { &say });
                if !dry && !test {
                    let trace = self.current.lock().trace.clone();
                    let output = self
                        .steps()
                        .iter()
                        .map(|s| s.text.clone())
                        .chain(trace.iter().filter_map(|t| t.text.clone()))
                        .chain([say.clone()])
                        .collect::<Vec<_>>()
                        .join("\n");
                    memory::note_used(&memory::used(&rs.seen.facts, &output, &rs.seen.apps, &rs.seen.hosts));
                    self.learn(&session, &rs).await;
                }
                return;
            }
            if actions.is_empty() {
                results.push("(no actions taken)".into());
            }
            message = format!("Results:\n{}", results.join("\n"));
        }
        let last = self.steps().last().map(|s| s.text.clone()).unwrap_or_else(|| "nothing".into());
        self.finish(false, &format!("Ran out of steps, so I stopped. Last done: {last}. Check the screen before retrying."));
    }

    /// Whether the page list alone shows what the model needs after these actions.
    fn page_list_suffices(&self, ctx: &Ctx, prior: &[Action]) -> bool {
        let Some(page) = &ctx.page else { return false };
        if page.problem.is_some() || page.elements.len() < 6 {
            return false;
        }
        if self.platform.front_app().map(|a| a.pid) != ctx.app.as_ref().map(|a| a.pid) {
            return false;
        }
        let in_page = ["scroll", "wait", "review", "read", "extract", "recall", "remember", "show", "application", "autofill"];
        prior.iter().all(|a| is_web_ref(a.get("id")) || in_page.contains(&a.kind().as_str()))
    }

    /// The first message: the request, who and when, running apps, selection, files, clipboard, continuation,
    /// skills, memory and the job profile.
    fn intro(&self, request: &str, rs: &mut RunState) -> String {
        let ctx = self.context.lock().clone();
        let running = self.platform.running_apps();
        let date = chrono::Local::now().format("%A, %-d %B %Y at %H:%M");
        let name = self.platform.user_name();
        let mut text = format!(
            "Request: {request}\nUser: {name} · {date}\nRunning apps: {}\nDefault browser: {}",
            running.join(", "),
            self.platform.default_browser().unwrap_or_else(|| "unknown".into())
        );
        if self.hands.hidden() {
            text += if crate::worker::worker().in_user_browser() { crate::prompt::BACKGROUND_TAB } else { crate::prompt::BACKGROUND };
        }
        {
            let s = self.snaps.lock();
            if !s.0.is_empty() {
                let waiting: Vec<String> =
                    s.0.iter().filter(|x| !x.pasted).map(|x| format!("{:?}", x.caption.chars().take(60).collect::<String>())).collect();
                text += &format!(
                    "\nWrite-up screenshots so far in this task: {} ({} already pasted in the doc{}){}. Last captioned: {:?}.",
                    s.0.len(),
                    s.0.len() - waiting.len(),
                    if waiting.is_empty() {
                        String::new()
                    } else {
                        format!("; not pasted yet: {} — paste_snaps puts them in", waiting.join(", "))
                    },
                    s.1.as_ref().map(|f| format!("; saved in {}", f.display())).unwrap_or_default(),
                    s.0.last().map(|x| x.caption.chars().take(80).collect::<String>()).unwrap_or_default()
                );
            }
        }
        if let Some(c) = &ctx.circled {
            let r = super::circle_bounds(c);
            text += &format!(
                "\nThe user circled an area on screen before asking (\"this\", \"here\", \"that\" usually mean it): x {}–{}, y {}–{} in screen pixels. It's the yellow loop on the first screenshot.",
                r.x as i64, r.max_x() as i64, r.y as i64, r.max_y() as i64
            );
        }
        if let Some(sel) = ctx.selected_text.as_ref().filter(|s| !s.is_empty()) {
            text += &format!("\nSelected text (the user highlighted this before asking; \"this\", \"it\", \"that\" usually mean it):\n\"\"\"\n{}\n\"\"\"", sel.chars().take(4000).collect::<String>());
        }
        if !ctx.selected_files.is_empty() {
            text += &format!(
                "\nFiles selected in File Explorer (\"this\", \"these\", \"it\" usually mean them):\n{}",
                ctx.selected_files.iter().map(|f| format!("- {}", f.display())).collect::<Vec<_>>().join("\n")
            );
        } else if let Some(t) = &ctx.target {
            if let Some(doc) = self.platform.document_path(t) {
                text += &format!("\nFile open in {}: {}", t.name, doc.display());
            }
        }
        if ctx.selected_text.is_none() && ctx.selected_files.is_empty() {
            if let Some(c) = &ctx.copied {
                let points = crate::workflow::refers_to_context(request)
                    || regex::Regex::new(r"(?i)\b(clipboard|copied|paste|pasted)\b").unwrap().is_match(request);
                if points {
                    let when = describe_age(c.age_secs);
                    if let Some(t) = &c.text {
                        text += &format!(
                            "\nClipboard (the user copied this {when}; nothing is selected, so \"this\", \"it\", \"that\" usually mean it — but only if the request fits it, e.g. \"translate this\", \"reply to this\", \"add this to my tracker\"):\n\"\"\"\n{}\n\"\"\"",
                            t.chars().take(4000).collect::<String>()
                        );
                    }
                    if !c.files.is_empty() {
                        text += &format!(
                            "\nFiles on the clipboard (copied {when}; \"this\"/\"these\" may mean them):\n{}",
                            c.files.iter().map(|f| format!("- {}", f.display())).collect::<Vec<_>>().join("\n")
                        );
                    }
                }
            }
        }
        if rs.dry {
            text += "\nDRY RUN: the user wants to see what you'd do without anything happening. Clicks, typing, keys, choosing, uploads, emails, file/calendar changes and scripts are only shown on screen, not done — the screen won't change after them. Opening apps/websites, scrolling, reading and looking do happen. Plan the whole task as if each shown step worked, go as far as you can, then finish with done:true and a short summary of the plan.";
        }
        if let Some(earlier) = &ctx.continuation {
            if let Some(task) = earlier.task.as_ref().filter(|t| **t != earlier.request) {
                text += &format!(
                    "\n\nThe task this is all part of (the user's own instructions, still in force until everything is done):\n{task}"
                );
            }
            let steps: Vec<String> = earlier.steps.iter().rev().take(12).rev().cloned().collect();
            text += &format!(
                "\n\nThis continues an earlier task ({}):\nEarlier request: {}\nWhat happened: {}\nEarlier result: {}{}",
                earlier.when().format("%-d %b, %H:%M"),
                earlier.request,
                steps.join("; "),
                earlier.answer,
                earlier
                    .result
                    .as_ref()
                    .map(|r| format!("\nEarlier output: {}", r.plain().chars().take(1500).collect::<String>()))
                    .unwrap_or_default()
            );
            if let Some(doc) = &earlier.read_text {
                text += &format!("\nThe document the earlier task read (use this; don't open it again unless it's cut off):\n{doc}");
            }
            if !earlier.ok {
                text += "\nThe earlier task didn't finish. Pick up where it stopped (check what's already on screen, e.g. a half-typed message) instead of starting over.";
            }
        }
        let skills = crate::skills::prompt_text();
        if !skills.is_empty() {
            text += &format!("\nSkills the user taught you (follow the matching one's steps when a request fits; ask for any missing parameters):\n{skills}");
        }
        // Only the memory that matters for this request (plus core facts); the rest is one recall away.
        let about = [
            request.to_string(),
            ctx.target.as_ref().map(|a| a.name.clone()).unwrap_or_default(),
            ctx.selected_text.clone().unwrap_or_default(),
            ctx.continuation.as_ref().map(|c| c.request.clone()).unwrap_or_default(),
        ]
        .join(" ");
        text += &crate::task_memory::context(&about);
        let (facts, omitted) = memory::relevant(&about, ctx.target.as_ref().map(|a| a.name.as_str()), None, 40);
        rs.seen.facts.extend(facts.iter().cloned());
        let (profile, other): (Vec<&String>, Vec<&String>) = facts.iter().partition(|f| memory::is_profile(f));
        text += &format!(
            "\nThe user's profile (their own details: fill forms with these and never ask for them; the latest line wins if two disagree):\n- Full name: {name}\n{}",
            profile.iter().map(|f| format!("- {f}")).collect::<Vec<_>>().join("\n")
        );
        if !other.is_empty() {
            text += &format!(
                "\nOther things you remember about the user:\n{}",
                other.iter().map(|f| format!("- {f}")).collect::<Vec<_>>().join("\n")
            );
        }
        if omitted > 0 {
            text += &format!(
                "\n({omitted} more remembered facts not shown — use recall if you need something about the user that isn't here.)"
            );
        }
        if may_meet_forms(&about) {
            let jp = crate::profile::prompt_block();
            if !jp.is_empty() {
                text += &format!("\n{jp}");
            }
        }
        text
    }

    /// After a task: keep anything lasting it revealed, as edits to the closest facts.
    pub(crate) async fn collect_workers(&self, workers: &crate::delegation::Pool, ids: &[String], wait: bool, timeout: u64) -> String {
        let collecting = workers.collect(ids, wait, timeout);
        tokio::pin!(collecting);
        loop {
            tokio::select! {
                result = &mut collecting => return result,
                _ = tokio::time::sleep(Duration::from_millis(250)) => {
                    self.progress();
                    if !self.added.lock().is_empty() {
                        return workers.collect(ids,false,1).await + "\nUser guidance arrived; discard outstanding assignments and replan.";
                    }
                }
            }
        }
    }

    async fn learn(self: &Arc<Self>, session: &Arc<Session>, rs: &RunState) {
        learn_from_forms(self, rs);
        let about = [rs.request.clone()]
            .into_iter()
            .chain(self.steps().iter().rev().take(25).map(|s| s.text.clone()))
            .chain([self.ui.lock().answer.clone()])
            .collect::<Vec<_>>()
            .join("\n");
        let (near, _) = memory::relevant(&about, None, None, 30);
        let places: Vec<String> = rs.seen.hosts.iter().chain(rs.seen.apps.iter()).cloned().collect();
        let prompt = format!(
            "The task is finished. Update what you remember from what this task revealed. Worth keeping: lasting facts about the user — people and where to reach them (which app/chat), preferences (seats, airlines, food, tone), usual apps, home/work city, frequent places, accounts or usernames — and know-how for a site or app that cost you steps here and would save them next time (where something lives, a trick that worked, the name an app must be opened with). Never passwords, card numbers, OTPs, one-off details, job applications (the application tracker holds those) or what merely happened to be on screen.\nPlaces this task worked in: {}\nRelated things you already remember (numbered):\n{}\nReply with JSON only: {{\"ops\":[…]}}, each op one of\n  {{\"add\":\"<short fact>\",\"scope\":\"site:<host>\" | \"app:<App name>\" | null}}   something new; scope only for know-how that matters just there\n  {{\"update\":<n>,\"to\":\"<fact n, corrected or with the new detail>\"}}         fact n changed or gained a detail\n  {{\"remove\":<n>,\"why\":\"<what this task showed>\"}}                            fact n is no longer true\n{{\"ops\":[]}} if nothing is new.",
            if places.is_empty() { "(none)".into() } else { places.join(", ") },
            if near.is_empty() { "(nothing yet)".into() } else { near.iter().enumerate().map(|(i, f)| format!("{}. {f}", i + 1)).collect::<Vec<_>>().join("\n") }
        );
        let Ok(reply) = session.send(&prompt, None, None).await else { return };
        let Some(json) = reply::parse(&reply) else { return };
        let ops = json.get("ops").and_then(|v| v.as_array()).cloned().unwrap_or_default();
        let line = |v: Option<&serde_json::Value>| {
            v.and_then(|v| v.as_str()).map(str::trim).filter(|t| !t.is_empty() && t.len() < 240).map(String::from)
        };
        let fact = |v: Option<&serde_json::Value>| {
            let n = v.and_then(|v| v.as_u64().or_else(|| v.as_str().and_then(|s| s.parse().ok())))? as usize;
            (n >= 1 && n <= near.len()).then(|| near[n - 1].clone())
        };
        let mut removed = 0;
        for op in ops {
            if let Some(new) = line(op.get("add")) {
                if let Some(known) = memory::near_duplicate(&new) {
                    self.log(&format!("🧠 already known: {}", known.chars().take(80).collect::<String>()));
                    continue;
                }
                let scope = op.get("scope").and_then(|v| v.as_str()).and_then(memory::Scope::parse);
                memory::add(&new, scope);
                self.log(&format!("🧠 remembered: {new}"));
            } else if let (Some(old), Some(new)) = (fact(op.get("update")), line(op.get("to"))) {
                if new == old {
                    continue;
                }
                // A rewrite keeps every email, link and number.
                let lost = memory::details(&old).into_iter().any(|d| !new.contains(&d));
                if lost {
                    self.log(&format!("🧠 update skipped (it would drop details): {}", old.chars().take(60).collect::<String>()));
                    continue;
                }
                if memory::update(&old, &new) {
                    self.log(&format!("🧠 updated: {old} → {new}"));
                }
            } else if let Some(old) = fact(op.get("remove")) {
                if removed < 2 && !memory::is_profile(&old) && memory::remove(&old, op.get("why").and_then(|v| v.as_str())) {
                    removed += 1;
                    self.log(&format!("🧠 forgot: {old}"));
                }
            }
        }
    }
}

fn describe_age(secs: u64) -> String {
    match secs {
        0..=59 => "just now".into(),
        60..=119 => "a minute ago".into(),
        _ => format!("{} minutes ago", secs / 60),
    }
}

fn track_form(rs: &mut RunState, page: &Page, host: &str) {
    let fields: Vec<_> = page.elements.iter().filter(|e| e.editable || e.dropdown).collect();
    if fields.len() < 3 {
        return;
    }
    for el in fields {
        let q =
            el.question.clone().or(el.placeholder.clone()).or_else(|| (!el.text.is_empty()).then(|| el.text.clone())).unwrap_or_default();
        let q = q.trim().to_string();
        if q.len() < 3 || q.len() > 200 {
            continue;
        }
        let key = format!("{host}|{}", if el.key.is_empty() { q.clone() } else { el.key.clone() });
        let v = el.value.clone().unwrap_or_default().trim().to_string();
        rs.form_seen.entry(key).and_modify(|e| e.2 = v.clone()).or_insert((q, v.clone(), v));
    }
}

pub(crate) fn squash_value(v: &str) -> String {
    v.to_lowercase().chars().filter(|c| c.is_alphanumeric()).collect()
}

/// Answers the user typed into a form by hand during the run, kept in the job profile.
fn learn_from_forms(agent: &Agent, rs: &RunState) {
    if rs.qa || !(may_meet_forms(&rs.request) || !rs.form_seen.is_empty()) {
        return;
    }
    let not_answer = regex::Regex::new(r"(?i)\b(password|passcode|otp|one[- ]time|code|pin|cvv|cvc|card|expiry|captcha|ssn|aadhaar|pan|search|message|comment|chat|reply|compose|note|caption|tweet|post|subject|body|cover letter|description|why)\b").unwrap();
    let choose = regex::Regex::new(r"(?i)^(select|choose|--|please select|pick)").unwrap();
    let known = (memory::facts().join("\n") + &crate::profile::prompt_block()).to_lowercase();
    let profile = crate::profile::current();
    let mut kept = 0;
    let mut all: Vec<_> = rs.form_seen.values().collect();
    all.sort_by(|a, b| a.0.cmp(&b.0));
    for (question, first, last) in all {
        if kept >= 15 {
            break;
        }
        let v = last;
        if v.is_empty()
            || v == first
            || v.len() > 160
            || v.starts_with("••")
            || rs.agent_entered.contains(&squash_value(v))
            || not_answer.is_match(question)
            || choose.is_match(v)
        {
            continue;
        }
        if crate::profile::answer(question, &profile).as_deref() == Some(v.as_str()) || (v.len() >= 4 && known.contains(&v.to_lowercase()))
        {
            continue;
        }
        crate::profile::remember(question, v);
        kept += 1;
        agent.log(&format!(
            "🧠 learned from the form: “{}” → {}",
            question.chars().take(70).collect::<String>(),
            v.chars().take(60).collect::<String>()
        ));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn verdicts() {
        assert!(is_question("what's my roll number"));
        assert!(!is_question("open notepad"));
        assert!(looks_like_label("Your roll number"));
        assert!(!looks_like_label("Your roll number is 1601"));
        assert!(says_unfinished("Steps 1-6 done. Still to do: step 7"));
    assert_eq!(ending(false, false, true, false), Ending::NotYet);
    assert_eq!(ending(true, false, false, false), Ending::Finish);
    assert_eq!(ending(true, false, true, false), Ending::Check);
    assert_eq!(ending(true, false, true, true), Ending::Failed);
    assert_eq!(ending(true, true, false, false), Ending::Failed);
        assert!(!says_unfinished("Done. You need to log in to continue, the rest remains"));
        assert!(!says_unfinished("Settings remain unchanged"));
        assert!(keeps_front_app("open spotify"));
    }
}
