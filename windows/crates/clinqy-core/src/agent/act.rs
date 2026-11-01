//! The actions: one `perform` that dispatches each to its handler, plus the handlers for apps (UI Automation
//! elements, text found by OCR, screen points, keys, menus, windows) and the agent's own (ask, show, recall…).

use super::run::{squash_value, web_index, ActionResult, Ctx, RunState};
use super::*;
use crate::background::Route;
use crate::taskstore::{tasks, State};
use crate::observation;
use crate::platform::{Element, Point, Rect, WindowOp};
use crate::reply::{Action, ActionExt};
use crate::safety;

pub(crate) fn acts(role: &str) -> bool {
    let r = role.to_lowercase();
    ![
        "radio",
        "radiobutton",
        "checkbox",
        "switch",
        "option",
        "menuitemradio",
        "menuitemcheckbox",
        "tab",
        "tabitem",
        "textbox",
        "textfield",
        "textarea",
        "searchfield",
        "combobox",
        "listbox",
        "row",
        "cell",
        "heading",
        "statictext",
        "text",
        "group",
        "radiogroup",
        "slider",
        "treeitem",
        "edit",
        "listitem",
        "dataitem",
    ]
    .contains(&r.as_str())
}

pub(crate) fn is_form_submit(label: &str) -> bool {
    regex::Regex::new(r"(?i)\bsubmit\b|^\s*(send|finish|complete) (my |the |your )?(application|form)\b").unwrap().is_match(label)
}

/// "Ready to submit?": a go-ahead for the form's Submit, not a clarifying question.
fn asks_to_submit(a: &Action) -> bool {
    let q = a.str("question").unwrap_or("");
    if a.list("options").len() > 2 || q.contains(" or ") {
        return false;
    }
    regex::Regex::new(r"(?i)(\b(ready to|shall i|should i|ok(ay)? to|go ahead( and)?|can i|want me to|confirm|good to)\b[^?]{0,40}\b(submit|apply|send)\b|^\s*(submit|apply|send)\b[^?]{0,40}\?)")
        .unwrap()
        .is_match(q)
}

/// "Submit with your resume attached?", "Should I go ahead?": a decision, not a detail.
pub(crate) fn is_confirmation(text: &str) -> bool {
    let question = text.find('?').map(|i| &text[..=i]).unwrap_or(text);
    if regex::Regex::new(r"(?i)\b(what|which|who|whom|where|when|how much|how many)\b.*\bshould i (put|enter|use|write|fill|type|say|give|choose|select|answer|add|list|mention)\b")
        .unwrap()
        .is_match(question)
    {
        return false;
    }
    regex::Regex::new(r"(?i)\b(submit|send it|should i|shall i|go ahead|ready to|confirm|okay to|ok to)\b").unwrap().is_match(question)
}

fn asks_for_personal_details(q: &str) -> bool {
    !is_confirmation(q)
        && regex::Regex::new(r"(?i)\byour\s+(\w+\s+){0,2}?(name|e-?mail|phone|mobile|number|college|university|cgpa|gpa|degree|graduat\w*|linkedin|github|portfolio|address|city|gender|birth|dob|age|skills?|stack|experience|resume|cv)\b")
            .unwrap()
            .is_match(q)
}

/// The profile's answer to an ask that's a single form question it covers.
fn profile_answer(a: &Action) -> Option<(String, String)> {
    let q = a.str("question")?;
    if is_confirmation(q) || a.flag("sensitive") || q.matches('?').count() > 1 {
        return None;
    }
    let asked = q.find('?').map(|i| &q[..=i]).unwrap_or(q);
    let ans = crate::profile::answer(asked, &crate::profile::current())?;
    let options: Vec<String> = a.list("options").iter().map(|o| o.to_lowercase()).collect();
    if !options.is_empty() && !options.iter().any(|o| o.contains(&ans.to_lowercase()) || ans.to_lowercase().contains(o.as_str())) {
        return None;
    }
    Some((q.to_string(), ans))
}

impl Agent {
    pub(crate) fn begin(&self, text: &str) -> usize {
        let i = self.push_step(text, StepState::Running);
        self.log(&format!("  → {}", self.ui.lock().steps.get(i).map(|s| s.text.clone()).unwrap_or_default()));
        i
    }

    pub(crate) fn end(&self, i: usize, r: ActionResult) -> ActionResult {
        self.set_step(i, if r.ok { StepState::Ok } else { StepState::Failed }, None);
        if r.ok {
            self.log(&format!("    ← {}", r.summary.chars().take(240).collect::<String>().replace('\n', " ⏎ ")));
        } else {
            self.log(&format!("    ✗ {}", r.summary));
        }
        r
    }

    /// Consequential clicks (pay, book, send, delete…) the request didn't clearly ask for need the user's OK.
    pub(crate) async fn confirm_risky(&self, label: &str, rs: &mut RunState) -> bool {
        if rs.user_confirmed {
            return true;
        }
        let Some(what) = safety::needs_confirmation(label, &rs.request) else { return true };
        let reply = self.ask_user(&format!("About to click “{what}”. Go ahead?"), vec!["Yes, go ahead".into(), "No".into()], false).await;
        let yes = reply.map(|r| safety::is_yes(&r)).unwrap_or(false);
        if yes {
            rs.user_confirmed = true;
        }
        yes
    }

    /// Before clicking a control: a form's final Submit shows the review card; other consequential clicks are
    /// confirmed. None = go ahead, else why not.
    pub(crate) async fn approve(&self, label: &str, role: &str, ctx: &Ctx, rs: &mut RunState) -> Option<String> {
        if !acts(role) {
            return None;
        }
        if !rs.user_confirmed && is_form_submit(label) {
            if let Some(page) = &ctx.page {
                if let Some(ok) = self.review_before_submit(page, rs).await {
                    return if ok { None } else { Some(self.edited_review()) };
                }
            }
        }
        if self.confirm_risky(label, rs).await {
            None
        } else {
            Some(format!(
                "the user said not to click {:?}; stop and tell them where things stand",
                label.chars().take(40).collect::<String>()
            ))
        }
    }

    pub(crate) fn edited_review(&self) -> String {
        match self.last_review_note.lock().clone() {
            Some(n) => format!("the user chose Edit on the review: \"{n}\". Make that change, then submit again"),
            None => "the user chose Edit on the review without saying what; ask them what to change".into(),
        }
    }

    /// Why acting on the app the model saw would be wrong now: it quit, or its pid belongs to a new process.
    fn stale_app(&self, ctx: &Ctx) -> Option<String> {
        let app = ctx.app.as_ref()?;
        (!self.platform.is_same_process(app)).then(|| format!("{} quit or restarted since the last look; look again", app.name))
    }

    pub(crate) async fn refresh(&self, ctx: &mut Ctx) {
        let Some(app) = ctx.app.clone() else { return };
        let scan = self.platform.scan(&app, 150).await;
        ctx.elements = scan.elements;
        ctx.fingerprint = scan.fingerprint;
        let bridge = crate::bridge::bridge();
        if self.platform.is_browser(&app) && bridge.serves(&app.exe) {
            if let Some(page) = bridge.snapshot(Some(&app.exe)).await {
                ctx.web_area = self.platform.web_area(&app).await.or(page.estimated_area);
                self.adopt(page, ctx);
                return;
            }
        }
        ctx.page = None;
    }

    pub(crate) async fn relist(&self, ctx: &mut Ctx) {
        let Some(app) = ctx.app.clone() else { return };
        let Some(page) = crate::bridge::bridge().snapshot(Some(&app.exe)).await else { return };
        if let Some(old) = &ctx.page {
            if old.elements.len() != page.elements.len() {
                self.log(&format!("    page re-listed: {} → {} elements", old.elements.len(), page.elements.len()));
            }
        }
        self.adopt(page, ctx);
    }

    fn adopt(&self, page: crate::page::Page, ctx: &mut Ctx) {
        if let Some(old) = &ctx.page {
            ctx.typed = ctx.typed.iter().filter_map(|(i, t)| crate::page::rematch(*i, old, &page).map(|n| (n, t.clone()))).collect();
        }
        ctx.page = Some(page);
    }

    async fn screen_changed(&self, app: &AppRef, from: u64, ms: u64) -> bool {
        for _ in 0..(ms / 60).max(1) {
            tokio::time::sleep(Duration::from_millis(60)).await;
            if self.platform.fingerprint(app).await != from {
                return true;
            }
        }
        false
    }

    /// Looks an element up by id; if the screen changed since it was listed, finds the same control again.
    async fn resolve(&self, id: Option<&serde_json::Value>, ctx: &mut Ctx, rs: &mut RunState) -> Option<Element> {
        let app = ctx.app.clone()?;
        let id = id?.as_str()?.to_string();
        let wanted = observation::lookup(&id, &ctx.elements)?.clone();
        rs.last_target = Some(Target { kind: "ax".into(), role: wanted.role.clone(), label: wanted.label.clone() });
        if self.platform.fingerprint(&app).await == ctx.fingerprint {
            return Some(wanted);
        }
        if let Some(r) = self.platform.element_rect(wanted.handle) {
            if r.w > 2.0 && r.h > 2.0 {
                return Some(Element { rect: r, ..wanted });
            }
        }
        self.refresh(ctx).await;
        if let Some(t) = observation::twin(&wanted, &ctx.elements) {
            return Some(t.clone());
        }
        let near = |e: &Element| e.rect.center().distance(wanted.rect.center());
        ctx.elements
            .iter()
            .find(|e| e.role == wanted.role && e.label == wanted.label)
            .or_else(|| ctx.elements.iter().find(|e| e.label == wanted.label))
            .or_else(|| {
                ctx.elements
                    .iter()
                    .filter(|e| e.role == wanted.role && near(e) < 40.0)
                    .min_by(|a, b| near(a).partial_cmp(&near(b)).unwrap())
            })
            .cloned()
    }

    /// One action: in a background run the policy decides first, and every action is checkpointed so a crash can
    /// never leave a side effect looking undone.
    pub(crate) async fn perform(self: &Arc<Self>, action: &Action, ctx: &mut Ctx, rs: &mut RunState) -> ActionResult {
        let kind = action.kind();
        if self.hands.hidden() && !rs.dry {
            let has_page = ctx.page.as_ref().map(|p| p.connection == crate::worker::CONNECTION).unwrap_or(false);
            if has_page && kind == "click" && !action.contains_key("id") && !action.contains_key("x") {
                return ActionResult::fail("In the background, click an element by its w-id from the page's list, not by its text.");
            }
            if let Route::Attention(reason) = crate::background::route(action, has_page) {
                let id = self.task_id();
                tasks().update(id.as_deref(), Some(State::NeedsAttention), Some(&reason), None, None);
                let reply = self.ask_user(&format!("{reason} You can continue this task in the foreground, or stop it."), vec!["Keep background mode".into(), "Continue in foreground".into(), "Stop task".into()], false).await;
                match reply.as_deref() {
                    Some("Continue in foreground") => {
                        self.leave_background();
                        // A moment to take their hands off the mouse: it's about to move.
                        tokio::time::sleep(Duration::from_millis(1500)).await;
                        ctx.app = None;
                        ctx.page = None;
                        ctx.web_area = None;
                        ctx.elements.clear();
                        tasks().update(id.as_deref(), Some(State::Running), Some("Continuing in foreground"), None, Some(false));
                    }
                    Some("Keep background mode") => {
                        tasks().update(id.as_deref(), Some(State::Running), Some("Continuing after your answer"), None, None);
                        return ActionResult::fail(format!("{reason} Use a supported action or a page in the background browser."));
                    }
                    _ => return self.stop_here().await,
                }
            }
        }
        let id = self.task_id();
        if !tasks().begin_action(id.as_deref(), &kind) {
            self.log("couldn't save the task checkpoint");
            return self.stop_here().await;
        }
        let result = self.execute(action, ctx, rs).await;
        let done = self.steps().iter().filter(|s| s.state == StepState::Ok).count();
        tasks().end_action(id.as_deref(), &kind, result.ok, done);
        result
    }

    /// Stops the run from inside it. `cancel` aborts this very task, which only takes effect at its next pause: it
    /// waits here for that, because anything it did on the way would mark the finished run as busy again.
    async fn stop_here(self: &Arc<Self>) -> ActionResult {
        self.cancel();
        std::future::pending().await
    }

    async fn execute(self: &Arc<Self>, action: &Action, ctx: &mut Ctx, rs: &mut RunState) -> ActionResult {
        let kind = action.kind();
        if rs.dry {
            if let Some(r) = self.rehearse(&kind, action, ctx, rs).await {
                return r;
            }
        }
        if ["type", "choose", "autofill", "fill"].contains(&kind.as_str()) {
            for k in ["text", "option", "value"] {
                if let Some(v) = action.str(k) {
                    rs.agent_entered.insert(squash_value(v));
                }
            }
        }
        let web = super::run::web_index(action.get("id")).is_some();
        let has_id = action.contains_key("id");
        match kind.as_str() {
            "delegate" => {
                self.current.lock().requires_fresh_work = true;
                let line = self.begin("Delegate independent work");
                let Some(pool) = rs.workers.as_mut() else {
                    return ActionResult::fail("Workers unavailable");
                };
                let jobs = action.get("jobs").cloned().unwrap_or(serde_json::Value::Null);
                match serde_json::from_value(jobs).map_err(anyhow::Error::from).and_then(|jobs| pool.submit(jobs)) {
                    Ok(status) => self.end(line, ActionResult::ok(status)),
                    Err(error) => self.end(line, ActionResult::fail(error.to_string())),
                }
            }
            "collect" => {
                let line = self.begin("Collect worker results");
                let Some(pool) = rs.workers.as_ref() else {
                    return ActionResult::fail("Workers unavailable");
                };
                let ids: Vec<String> = action
                    .get("ids")
                    .and_then(|v| v.as_array())
                    .map(|a| a.iter().filter_map(|v| v.as_str().map(String::from)).collect())
                    .unwrap_or_default();
                let wait = action.get("wait").and_then(|v| v.as_bool()).unwrap_or(false);
                let timeout = action.get("timeout").and_then(|v| v.as_u64()).unwrap_or(90);
                self.set_phase(Phase::Thinking);
                self.end(line, ActionResult::ok(self.collect_workers(pool, &ids, wait, timeout).await))
            }
            "open_app" => self.open_app(action, ctx).await,
            "open_url" => self.open_url(action, ctx, rs).await,
            "click" if web => self.web_click(action, ctx, rs).await,
            "upload" if ctx.page.is_some() => self.upload(action, ctx, rs).await,
            "review" if ctx.page.is_some() => self.review_form(ctx, rs).await,
            "autofill" if ctx.page.is_some() => Box::pin(self.autofill(ctx, rs)).await,
            "choose" if web => self.choose(action, ctx, rs).await,
            "type" if web => self.web_type(action, ctx, rs).await,
            "type" if !has_id && ctx.page.is_some() => self.type_focused_page(action, ctx).await,
            "point" | "mark" if web => self.web_point(action, ctx, rs).await,
            "scroll" if ctx.page.is_some() => self.web_scroll(action, ctx).await,
            "read" => self.read(action, ctx).await,
            "click" if !has_id && action.get("x").is_none() && action.str("text").is_some() => self.click_text(action, ctx, rs).await,
            "click" if !has_id => self.click_point(action, ctx).await,
            "click" => self.click_element(action, ctx, rs).await,
            "type" => self.type_native(action, ctx, rs).await,
            "key" => {
                let Some(keys) = action.str("keys") else { return ActionResult::fail("key needs keys") };
                let line = self.begin(&format!("Press {keys}"));
                if let Some(app) = &ctx.app {
                    self.platform.bring_to_front(app).await;
                }
                if let Some(why) = safety::blocked_chord(keys, &rs.request) {
                    return self.end(line, ActionResult::fail(why));
                }
                self.buddy.click();
                if let Err(why) = self.platform.press(keys) {
                    return self.end(line, ActionResult::fail(why));
                }
                let mut changed = false;
                if let Some(app) = ctx.app.clone() {
                    changed = self.screen_changed(&app, ctx.fingerprint, 450).await;
                    ctx.fingerprint = self.platform.fingerprint(&app).await;
                    // A key can bring up another window (ctrl+n, alt+tab).
                    if let Some(front) = self.platform.front_app() {
                        if front.pid != app.pid {
                            ctx.app = Some(front);
                        }
                    }
                }
                self.end(line, ActionResult::ok(format!("pressed {keys}{}", if changed { "" } else { " (no visible change)" })))
            }
            "scroll" => {
                let Some(app) = ctx.app.clone() else { return ActionResult::fail("no app") };
                let up = action.str("dir").map(|d| d.eq_ignore_ascii_case("up")).unwrap_or(false);
                let line = self.begin(if up { "Scroll up" } else { "Scroll down" });
                self.platform.scroll(&app, up).await;
                ctx.fingerprint = self.platform.fingerprint(&app).await;
                self.end(line, ActionResult::ok(if up { "scrolled up" } else { "scrolled down" }))
            }
            "shell" | "powershell" | "applescript" => {
                let Some(cmd) = action.str("cmd").or_else(|| action.str("script")) else { return ActionResult::fail("shell needs cmd") };
                if kind == "applescript" && !looks_like_powershell(cmd) {
                    return ActionResult::fail(
                        "this is Windows: there's no AppleScript. Use shell with a PowerShell command (COM objects script Office apps)",
                    );
                }
                let line = self.begin("Look something up");
                let (status, out) = self.platform.shell(cmd, 20).await;
                let hint = if status == 0 { String::new() } else { shell_hint(&out) };
                self.end(
                    line,
                    ActionResult {
                        ok: status == 0,
                        summary: format!(
                            "exit {status}{}{hint}",
                            if out.is_empty() { String::new() } else { format!(": {}", out.chars().take(2000).collect::<String>()) }
                        ),
                        look: false,
                    },
                )
            }
            "dictionary" => ActionResult::fail(
                "Windows apps have no AppleScript dictionary; script Office apps through PowerShell COM with shell, or work on screen",
            ),
            "point" | "mark" => {
                let (rect, name) = if has_id {
                    match self.resolve(action.get("id"), ctx, rs).await {
                        Some(el) => (Some(el.rect), el.short_label()),
                        None => {
                            return ActionResult::fail(format!(
                                "element {} isn't on screen anymore",
                                action.get("id").map(|v| v.to_string()).unwrap_or_default()
                            ))
                        }
                    }
                } else if let (Some(x), Some(y)) = (action.num("x"), action.num("y")) {
                    let scale = self.platform.shot_scale();
                    let (w, h) = (action.num("w").unwrap_or(36.0) * scale, action.num("h").unwrap_or(36.0) * scale);
                    (self.platform.screen_point(x, y).map(|p| Rect::new(p.x - w / 2.0, p.y - h / 2.0, w, h)), "that".to_string())
                } else {
                    (None, String::new())
                };
                let Some(rect) = rect else { return ActionResult::fail("point needs an id, or x/y on the last screenshot") };
                let line = self.begin(&format!("Show {name}"));
                self.buddy.mark(rect, action.str("label")).await;
                self.current.lock().linger = 3.5;
                self.end(line, ActionResult::ok("marked it on screen with a circle and arrow"))
            }
            "ask" if !rs.reviewed_form && !rs.user_confirmed && ctx.page.is_some() && asks_to_submit(action) => {
                rs.reviewed_form = true;
                let line = self.begin("Review before submitting");
                let page = ctx.page.clone().unwrap();
                match self.review_before_submit(&page, rs).await {
                    None => {
                        self.set_step(line, StepState::Info, None);
                        Box::pin(self.ask(action, ctx, rs)).await
                    }
                    Some(true) => self.end(
                        line,
                        ActionResult::ok(
                            "the user checked every answer on the form and approved submitting: submit now, without asking again",
                        ),
                    ),
                    Some(false) => {
                        let why = self.edited_review();
                        self.end(line, ActionResult::fail(why))
                    }
                }
            }
            "ask" => self.ask(action, ctx, rs).await,
            "assert" => {
                let text = action.str("text").unwrap_or("").to_string();
                let pass = action.flag("pass");
                let line = self.begin(&format!("Check “{}”", text.chars().take(50).collect::<String>()));
                self.checks.lock().push(Check { text: text.clone(), pass, note: action.str("note").unwrap_or("").into() });
                self.buddy.signal(pass);
                self.end(line, ActionResult::ok(format!("recorded check: {} {text}", if pass { "PASS" } else { "FAIL" })))
            }
            "show" => {
                let Some(card) = ResultCard::from_action(action) else { return ActionResult::fail("show needs text or items") };
                self.push_step(&format!("Showed: {}", card.title), StepState::Info);
                self.current.lock().run_result = Some(card.clone());
                self.show_card(card);
                ActionResult::ok("shown to the user on screen")
            }
            "recall" => {
                let query = action.str("query").unwrap_or("");
                let line = self.begin(&format!("Recall {}", query.chars().take(40).collect::<String>()));
                let hits = crate::memory::search(query);
                rs.seen.facts.extend(hits.iter().take(5).cloned());
                let changes = crate::memory::history();
                let mut lines: Vec<String> = hits
                    .iter()
                    .map(|h| {
                        let was = crate::memory::earlier(h, &changes);
                        format!(
                            "- {h}{}",
                            if was.is_empty() {
                                String::new()
                            } else {
                                format!(" (earlier: {})", was.iter().map(|w| format!("“{w}”")).collect::<Vec<_>>().join("; "))
                            }
                        )
                    })
                    .collect();
                let live: HashSet<String> = crate::memory::facts().into_iter().collect();
                let gone: Vec<_> =
                    crate::memory::search_history(query).into_iter().filter(|c| c.new.is_none() && !live.contains(&c.old)).collect();
                if !gone.is_empty() {
                    lines.push("No longer true (forgotten):".into());
                    lines.extend(gone.iter().map(|c| format!("- {} ({}, {})", c.old, c.why, c.at.get(..10).unwrap_or(""))));
                }
                self.end(
                    line,
                    ActionResult::ok(if lines.is_empty() {
                        "nothing remembered about that".to_string()
                    } else {
                        format!("remembered:\n{}", lines.join("\n"))
                    }),
                )
            }
            "remember" => {
                let Some(fact) = action.str("fact") else { return ActionResult::fail("remember needs fact") };
                crate::memory::add(fact, action.str("scope").and_then(crate::memory::Scope::parse));
                self.push_step(&format!("Remembered: {fact}"), StepState::Info);
                ActionResult::ok("saved")
            }
            "remember_answer" => {
                let (Some(q), Some(a)) = (action.str("question"), action.str("answer")) else {
                    return ActionResult::fail("remember_answer needs question and answer");
                };
                if !rs.test || rs.save_in_tests {
                    crate::profile::remember(q, a);
                }
                self.push_step(&format!("Saved answer: {}", q.chars().take(40).collect::<String>()), StepState::Info);
                ActionResult::ok("saved for future forms")
            }
            "look" => ActionResult { ok: true, summary: "screenshot attached next turn".into(), look: true },
            "wait" if action.str("for").is_some() => {
                let secs = action.num("timeout").unwrap_or(10.0).clamp(1.0, 120.0);
                self.wait_for(action.str("for").unwrap(), action.flag("gone"), secs, ctx).await
            }
            "wait" => self.wait(action, ctx).await,
            "snap" => self.snap(action, ctx).await,
            "paste_snaps" => self.paste_snaps(ctx).await,
            "tab" => self.tab(action, ctx).await,
            "menu" => {
                let (Some(path), Some(app)) = (action.str("path"), ctx.app.clone()) else {
                    return ActionResult::fail("menu needs path (\"File > Export…\") and an app in front");
                };
                let line = self.begin(&format!("Menu: {}", path.chars().take(40).collect::<String>()));
                if let Some(why) = self.stale_app(ctx) {
                    return self.end(line, ActionResult::fail(why));
                }
                self.platform.bring_to_front(&app).await;
                let (ok, note) = self.platform.menu(&app, path).await;
                tokio::time::sleep(Duration::from_millis(300)).await;
                self.refresh(ctx).await;
                self.end(line, if ok { ActionResult::ok(note) } else { ActionResult::fail(note) })
            }
            "window" => {
                let Some(app) = ctx.app.clone() else { return ActionResult::fail("no app") };
                let op = action.str("op").unwrap_or("").to_lowercase();
                let what = match op.as_str() {
                    "move" => match (action.num("x"), action.num("y")) {
                        (Some(x), Some(y)) => WindowOp::Move(Point::new(x, y)),
                        _ => return ActionResult::fail("window move needs x and y (screen pixels)"),
                    },
                    "resize" => match (action.num("w").or(action.num("width")), action.num("h").or(action.num("height"))) {
                        (Some(w), Some(h)) => WindowOp::Resize(w, h),
                        _ => return ActionResult::fail("window resize needs w and h"),
                    },
                    "minimize" => WindowOp::Minimize,
                    "restore" => WindowOp::Restore,
                    "maximize" | "fullscreen" => WindowOp::Maximize(action.get("on").and_then(|v| v.as_bool()).unwrap_or(true)),
                    "close" => WindowOp::Close,
                    "raise" => WindowOp::Raise,
                    _ => return ActionResult::fail("window op: move, resize, minimize, restore, maximize, close or raise"),
                };
                let line = self.begin(&format!("Window: {op}"));
                if let Some(why) = self.stale_app(ctx) {
                    return self.end(line, ActionResult::fail(why));
                }
                let (ok, note) = self.platform.window(&app, what, action.str("title")).await;
                self.refresh(ctx).await;
                self.end(line, if ok { ActionResult::ok(note) } else { ActionResult::fail(note) })
            }
            "application" | "pdf" | "media" | "email" | "extract" | "table" | "event" | "calendar" | "reminder" | "files" | "schedule" => {
                self.task_action(&kind, action, ctx, rs).await
            }
            _ => ActionResult::fail(format!("unknown action {kind:?}")),
        }
    }

    async fn open_app(&self, action: &Action, ctx: &mut Ctx) -> ActionResult {
        let Some(name) = action.str("name") else { return ActionResult::fail("open_app needs a name") };
        let line = self.begin(&format!("Open {name}"));
        let Some(app) = self.platform.open_app(name).await else {
            return self.end(line, ActionResult::fail(format!("Couldn't find an app called {name}")));
        };
        let shown = app.name.clone();
        ctx.app = Some(app);
        self.current.lock().opened_last = true;
        self.refresh(ctx).await;
        self.end(line, ActionResult::ok(format!("{shown} is now frontmost")))
    }

    async fn ask(&self, action: &Action, ctx: &mut Ctx, rs: &mut RunState) -> ActionResult {
        let q = action.str("question").unwrap_or("").to_string();
        // The job profile answers standard application questions (once per question).
        if !rs.qa && !rs.profile_offered.contains(&q) {
            if let Some((q2, a)) = profile_answer(action) {
                rs.profile_offered.insert(q2.clone());
                self.log(&format!("  profile answers “{}”", q2.chars().take(60).collect::<String>()));
                return ActionResult {
                    ok: false,
                    summary: format!("NOT ASKED — the job-application profile already answers this: {q2} → {a}. Use it."),
                    look: false,
                };
            }
        }
        // Memory first (once per question).
        if !rs.memory_checked.contains(&q) {
            rs.memory_checked.insert(q.clone());
            let mut parts = vec![q.clone()];
            parts.extend(q.split(|c| ",;:?()\n".contains(c)).filter(|p| p.trim().len() >= 3).map(|p| p.trim().to_string()));
            let host = ctx.page.as_ref().map(|p| crate::memory::bare_host(&p.url));
            let mut hits = crate::memory::for_page(&parts, &rs.seen.facts, ctx.app.as_ref().map(|a| a.name.as_str()), host.as_deref(), 8);
            if hits.is_empty() && asks_for_personal_details(&q) {
                hits = crate::memory::search(&q).into_iter().take(15).collect();
            }
            if !hits.is_empty() {
                rs.seen.facts.extend(hits.iter().cloned());
                self.log(&format!("  memory answers the question ({} fact(s)) — not asked", hits.len()));
                return ActionResult {
                    ok: false,
                    summary: format!(
                        "NOT ASKED — you already remember this about the user (use it, and ask only for what's truly missing):\n{}",
                        hits.iter().map(|h| format!("- {h}")).collect::<Vec<_>>().join("\n")
                    ),
                    look: false,
                };
            }
        }
        if rs.qa {
            return ActionResult::fail(
                "this is an unattended test — nobody can answer; assert the missing information as a failed check and finish",
            );
        }
        if q.is_empty() {
            return ActionResult::fail("ask needs a question");
        }
        let options = action.list("options");
        let sensitive = action.flag("sensitive");
        let line = self.begin(&format!("Ask: {}", q.chars().take(60).collect::<String>()));
        self.buddy.set_mood(Mood::Idle);
        let has_options = !options.is_empty();
        let reply = self.ask_user(&q, options, sensitive).await;
        let Some(reply) = reply.filter(|r| !r.is_empty()) else {
            return self.end(line, ActionResult::fail("the user didn't answer; stop here and say what's still needed"));
        };
        if sensitive {
            self.current.lock().secrets.push(reply.clone());
        } else {
            self.log(&format!("  user answered: {}", reply.chars().take(200).collect::<String>()));
        }
        rs.user_answers.push(reply.clone());
        if has_options && safety::is_yes(&reply) {
            rs.user_confirmed = true;
        }
        // An answer to an application form's question is kept for the next application (never a code).
        let code = regex::Regex::new(r"(?i)\b(otp|code|password|passcode|pin|cvv)\b").unwrap();
        if !sensitive
            && (!rs.test || rs.save_in_tests)
            && !rs.qa
            && ctx.page.is_some()
            && super::run::may_meet_forms(&rs.request)
            && !is_confirmation(&q)
            && !code.is_match(&q)
            && reply.len() < 300
            && !safety::is_yes(&reply)
        {
            crate::profile::remember(&q, &reply);
        }
        self.set_phase(Phase::Acting);
        self.buddy.set_mood(Mood::Acting);
        if let Some(app) = &ctx.app {
            self.platform.bring_to_front(app).await;
        }
        self.end(line, ActionResult::ok(format!("the user answered: {reply}")))
    }

    async fn click_element(&self, action: &Action, ctx: &mut Ctx, rs: &mut RunState) -> ActionResult {
        let Some(app) = ctx.app.clone() else { return ActionResult::fail("no app") };
        let Some(el) = self.resolve(action.get("id"), ctx, rs).await else {
            return ActionResult::fail(format!(
                "element {} isn't on screen anymore",
                action.get("id").map(|v| v.to_string()).unwrap_or_default()
            ));
        };
        let line = self.begin(&format!("Click {}", el.short_label()));
        if let Some(why) = self.stale_app(ctx) {
            return self.end(line, ActionResult::fail(why));
        }
        if let Some(why) = self.approve(&el.label, &el.role, ctx, rs).await {
            return self.end(line, ActionResult::fail(why));
        }
        self.platform.bring_to_front(&app).await;
        let method = match self.platform.click_element(el.handle, &app, ctx.fingerprint).await {
            Ok(m) => m,
            Err(why) => return self.end(line, ActionResult::fail(why)),
        };
        let changed = self.screen_changed(&app, ctx.fingerprint, 600).await;
        ctx.fingerprint = self.platform.fingerprint(&app).await;
        self.log(&crate::clicks::line("ax", &app.name, &method, changed, if method == "real" { 2 } else { 1 }));
        self.buddy.clear_highlight();
        if let Some(front) = self.platform.handoff(&app) {
            ctx.app = Some(front);
        }
        self.end(line, ActionResult::ok(format!("clicked {}{}", el.describe(), if changed { "" } else { " (no visible change)" })))
    }

    /// By the text it shows, found with OCR: for apps whose controls UI Automation doesn't list.
    async fn click_text(&self, action: &Action, ctx: &mut Ctx, rs: &mut RunState) -> ActionResult {
        let (Some(app), Some(want)) = (ctx.app.clone(), action.str("text").map(str::trim).filter(|t| !t.is_empty())) else {
            return ActionResult::fail("click needs an id, a text or x/y");
        };
        let line = self.begin(&format!("Click “{}”", want.chars().take(32).collect::<String>()));
        if let Some(why) = self.stale_app(ctx) {
            return self.end(line, ActionResult::fail(why));
        }
        if let Some(why) = self.approve(want, "button", ctx, rs).await {
            return self.end(line, ActionResult::fail(why));
        }
        self.platform.bring_to_front(&app).await;
        let Some(boxes) = self.platform.ocr(&app).await else { return self.end(line, ActionResult::fail("can't read the window")) };
        let key = |t: &str| t.to_lowercase().trim_matches(|c: char| c.is_whitespace() || c.is_ascii_punctuation()).to_string();
        let w = key(want);
        let mut hits: Vec<&crate::platform::TextBox> = boxes.iter().filter(|b| key(&b.text) == w).collect();
        if hits.is_empty() {
            hits = boxes.iter().filter(|b| format!(" {} ", key(&b.text)).contains(&format!(" {w} "))).collect();
        }
        hits.sort_by(|a, b| {
            if (a.rect.y - b.rect.y).abs() > 6.0 {
                a.rect.y.partial_cmp(&b.rect.y).unwrap()
            } else {
                a.rect.x.partial_cmp(&b.rect.x).unwrap()
            }
        });
        let mut spots: Vec<&crate::platform::TextBox> = vec![];
        for h in hits {
            if !spots.iter().any(|s| s.rect.intersects(&h.rect)) {
                spots.push(h);
            }
        }
        let nth = action.num("nth").unwrap_or(1.0).max(1.0) as usize;
        if spots.len() < nth {
            let near: Vec<String> =
                boxes.iter().filter(|b| observation::similar(&b.text, want)).take(5).map(|b| format!("{:?}", b.text)).collect();
            return self.end(
                line,
                ActionResult::fail(format!(
                    "no text {want:?} on the window{}",
                    if near.is_empty() { String::new() } else { format!("; similar: {}", near.join(", ")) }
                )),
            );
        }
        let spot = spots[nth - 1];
        let fp = self.platform.fingerprint(&app).await;
        if let Err(why) = self.platform.click_at(spot.rect.center(), Some(app.pid)).await {
            return self.end(line, ActionResult::fail(why));
        }
        let changed = self.screen_changed(&app, fp, 600).await;
        ctx.fingerprint = self.platform.fingerprint(&app).await;
        self.buddy.clear_highlight();
        self.log(&crate::clicks::line("text", &app.name, "real", changed, 1));
        let more = if spots.len() > nth {
            format!(" ({} places show it; this was #{nth} from the top — add \"nth\" for another)", spots.len())
        } else {
            String::new()
        };
        self.end(
            line,
            ActionResult::ok(format!("clicked the text {:?}{more}{}", spot.text, if changed { "" } else { " (no visible change)" })),
        )
    }

    async fn click_point(&self, action: &Action, ctx: &mut Ctx) -> ActionResult {
        let (Some(x), Some(y)) = (action.num("x"), action.num("y")) else {
            return ActionResult::fail("click needs an id, or x/y on the last screenshot");
        };
        let Some(p) = self.platform.screen_point(x, y) else { return ActionResult::fail("click by x/y needs a screenshot first (look)") };
        let line = self.begin("Click");
        if let Some(why) = self.stale_app(ctx) {
            return self.end(line, ActionResult::fail(why));
        }
        if let Some(app) = &ctx.app {
            self.platform.bring_to_front(app).await;
        }
        if let Err(why) = self.platform.click_at(p, ctx.app.as_ref().map(|a| a.pid)).await {
            return self.end(line, ActionResult::fail(why));
        }
        tokio::time::sleep(Duration::from_millis(450)).await;
        if let Some(app) = ctx.app.clone() {
            ctx.fingerprint = self.platform.fingerprint(&app).await;
        }
        self.end(line, ActionResult::ok(format!("clicked at ({}, {}) on the screenshot", x as i64, y as i64)))
    }

    async fn type_native(&self, action: &Action, ctx: &mut Ctx, rs: &mut RunState) -> ActionResult {
        let Some(app) = ctx.app.clone() else { return ActionResult::fail("no app") };
        let Some(text) = action.str("text") else { return ActionResult::fail("type needs text") };
        let submit = action.flag("submit");
        let line = self.begin(&format!("Type “{}”", text.chars().take(40).collect::<String>()));
        self.platform.bring_to_front(&app).await;
        if let Some(why) = self.stale_app(ctx) {
            return self.end(line, ActionResult::fail(why));
        }
        let mut target = "the focused field".to_string();
        let mut field: Option<u64> = None;
        if action.contains_key("id") {
            let Some(el) = self.resolve(action.get("id"), ctx, rs).await else {
                return self.end(line, ActionResult::fail("element isn't on screen anymore"));
            };
            if let Err(why) = self.platform.focus_element(el.handle, &app).await {
                return self.end(line, ActionResult::fail(why));
            }
            target = el.describe();
            field = Some(el.handle);
        }
        self.buddy.set_typing(true);
        let r = self.platform.type_text(text, &app).await;
        self.buddy.set_typing(false);
        if let Err(why) = r {
            return self.end(line, ActionResult::fail(why));
        }
        // The field itself says whether the text is in it. Apps that host web content (WhatsApp, Teams) report
        // focus on their outer window, so the focused value can't tell; the field we typed into can.
        let reads = |h: u64| self.platform.element_value(h);
        if let Some(h) = field.filter(|h| reads(*h).is_some()) {
            if !reads(h).map(|v| observation::similar(&v, text)).unwrap_or(false) {
                // Once more: focus it again and paste, replacing whatever is there.
                let _ = self.platform.focus_element(h, &app).await;
                self.platform.select_all();
                tokio::time::sleep(Duration::from_millis(60)).await;
                self.platform.paste(text);
                tokio::time::sleep(Duration::from_millis(250)).await;
                if !reads(h).map(|v| observation::similar(&v, text)).unwrap_or(false) {
                    let shows = reads(h).unwrap_or_default().trim().chars().take(60).collect::<String>();
                    return self.end(
                        line,
                        ActionResult::fail(format!("the text didn't go into {target} (it shows {shows:?}); look again before retrying")),
                    );
                }
            }
        }
        let mut sent_note = "";
        if submit {
            tokio::time::sleep(Duration::from_millis(120)).await;
            let _ = self.platform.press("enter");
            let _ = self.screen_changed(&app, ctx.fingerprint, 500).await;
            // A chat or search box empties when Enter sends it; if the text is still there, nothing was sent.
            if let Some(h) = field.filter(|h| reads(*h).is_some()) {
                if reads(h).map(|v| observation::similar(&v, text)).unwrap_or(false) {
                    sent_note = " — but the text is still in the field, so it may not have been sent (check before saying it was)";
                }
            }
        }
        ctx.fingerprint = self.platform.fingerprint(&app).await;
        self.buddy.clear_highlight();
        self.end(
            line,
            ActionResult::ok(format!(
                "typed {:?} into {target}{}{sent_note}",
                text.chars().take(60).collect::<String>(),
                if submit { " and pressed Enter" } else { "" }
            )),
        )
    }

    /// Best source first: the web page, a PDF in the browser, a file the window has open, then OCR of the screen.
    async fn read(&self, action: &Action, ctx: &mut Ctx) -> ActionResult {
        let line = self.begin("Read");
        if let Some(path) = action.str("path") {
            let p = crate::paths::expand(path);
            return match crate::files::read_text(&p).await {
                Some(t) => {
                    let name = p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                    self.current.lock().read_text = Some(format!("{name}:\n{t}"));
                    self.end(line, ActionResult::ok(format!("text of {name}:\n{t}")))
                }
                None => self.end(line, ActionResult::fail(format!("couldn't read {path} (check the path with files find)"))),
            };
        }
        let short = |t: &Option<String>| t.as_ref().map(|t| t.chars().count() < 80).unwrap_or(true);
        let (mut text, mut source): (Option<String>, String) = (None, String::new());
        if let Some(page) = &ctx.page {
            let url = page.url.to_lowercase();
            if !url.ends_with(".pdf") && (url.starts_with("http") || url.starts_with("file")) {
                text = crate::bridge::bridge()
                    .perform("read", page, serde_json::json!({}), 8.0)
                    .await
                    .ok()
                    .and_then(|r| r["text"].as_str().map(String::from));
                source = "the web page".into();
            }
            if short(&text) && url.contains(".pdf") {
                if let Some(t) = crate::files::read_url_pdf(&page.url).await {
                    text = Some(t);
                    source = "the PDF".into();
                }
            }
        }
        if short(&text) {
            if let Some(app) = &ctx.app {
                if let Some(doc) = self.platform.document_path(app) {
                    if let Some(t) = crate::files::read_text(&doc).await {
                        source = format!("the document {}", doc.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default());
                        text = Some(t);
                    }
                }
            }
        }
        if short(&text) {
            if let Some(app) = &ctx.app {
                if let Some(boxes) = self.platform.ocr(app).await {
                    let t = boxes.iter().map(|b| b.text.as_str()).collect::<Vec<_>>().join("\n");
                    if !t.trim().is_empty() {
                        text = Some(t);
                        source = "the screen (text recognition)".into();
                    }
                }
            }
        }
        let Some(text) = text.filter(|t| !t.trim().is_empty()) else {
            return self.end(line, ActionResult::fail("couldn't read any text here; try look"));
        };
        if !source.starts_with("the screen") {
            self.current.lock().read_text = Some(format!("{source}:\n{text}"));
        }
        self.end(line, ActionResult::ok(format!("text from {source}:\n{text}")))
    }

    async fn wait(&self, action: &Action, ctx: &mut Ctx) -> ActionResult {
        let ms = action.num("ms").unwrap_or(600.0).clamp(0.0, 5000.0) as u64;
        let Some(app) = ctx.app.clone().filter(|_| ms >= 1500) else {
            tokio::time::sleep(Duration::from_millis(ms)).await;
            if let Some(app) = ctx.app.clone() {
                ctx.fingerprint = self.platform.fingerprint(&app).await;
            }
            return ActionResult::ok(format!("waited {ms} ms"));
        };
        // A long wait ends once the screen changed and then held still for 0.8 s.
        let started = Instant::now();
        let mut last = self.platform.fingerprint(&app).await;
        let (mut changed, mut still) = (false, Instant::now());
        while started.elapsed().as_millis() < ms as u128 {
            tokio::time::sleep(Duration::from_millis(250)).await;
            let now = self.platform.fingerprint(&app).await;
            if now != last {
                changed = true;
                still = Instant::now();
                last = now;
            } else if changed && still.elapsed() >= Duration::from_millis(800) {
                break;
            }
        }
        ctx.fingerprint = last;
        let waited = started.elapsed().as_millis() as u64;
        ActionResult::ok(if waited + 200 < ms { format!("waited {waited} ms (the screen settled)") } else { format!("waited {ms} ms") })
    }

    /// Waits until `text` shows (or, with gone, stops showing): the page wakes us; otherwise cheap polls of the
    /// window's text, with OCR as the last word.
    async fn wait_for(&self, text: &str, gone: bool, secs: f64, ctx: &mut Ctx) -> ActionResult {
        let want = text.trim().to_lowercase();
        let Some(app) = ctx.app.clone().filter(|_| !want.is_empty()) else {
            return ActionResult::fail("wait needs for:\"<text>\" and an app in front");
        };
        let line = self.begin(&if gone {
            format!("Wait for “{}” to go", text.chars().take(30).collect::<String>())
        } else {
            format!("Wait for “{}”", text.chars().take(30).collect::<String>())
        });
        let started = Instant::now();
        // A long wait is progress, not a stuck step.
        let beat = {
            let progress = self.last_progress.clone();
            tokio::spawn(async move {
                loop {
                    *progress.lock() = Instant::now();
                    tokio::time::sleep(Duration::from_secs(2)).await;
                }
            })
        };
        let bridge = crate::bridge::bridge();
        if let Some(page) = &ctx.page {
            if let Ok(r) = bridge
                .perform("waitText", page, serde_json::json!({"text": text, "gone": gone, "ms": (secs * 1000.0) as u64}), secs + 3.0)
                .await
            {
                if r["met"] == true {
                    beat.abort();
                    self.refresh(ctx).await;
                    return self.end(
                        line,
                        ActionResult::ok(format!(
                            "{text:?} {} (after {:.1} s)",
                            if gone { "is gone" } else { "shows" },
                            started.elapsed().as_secs_f64()
                        )),
                    );
                }
            }
        }
        let mut gone_since: Option<Instant> = None;
        let result = loop {
            let use_ocr = started.elapsed().as_secs_f64() >= secs;
            let seen = self.shows(&want, &app, ctx.page.as_ref(), use_ocr).await;
            if gone {
                if seen {
                    gone_since = None;
                } else if let Some(since) = gone_since {
                    if since.elapsed() >= Duration::from_millis(500) {
                        if !self.shows(&want, &app, ctx.page.as_ref(), true).await {
                            break true;
                        }
                        gone_since = None;
                    }
                } else {
                    gone_since = Some(Instant::now());
                }
            } else if seen {
                break true;
            }
            if started.elapsed().as_secs_f64() >= secs && gone_since.is_none() {
                break false;
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
        };
        beat.abort();
        self.refresh(ctx).await;
        let took = started.elapsed().as_secs_f64();
        if result {
            return self.end(line, ActionResult::ok(format!("{text:?} {} (after {took:.1} s)", if gone { "is gone" } else { "shows" })));
        }
        let mut near = String::new();
        if !gone {
            if let Some(page) = &ctx.page {
                if let Ok(r) = bridge.perform("read", page, serde_json::json!({}), 8.0).await {
                    let all = format!("{}\n{}", r["title"].as_str().unwrap_or(""), r["text"].as_str().unwrap_or(""));
                    let close = closest(text, &all);
                    if let Some(hit) = close.iter().find(|l| words_in_order(text, l)) {
                        return self.end(
                            line,
                            ActionResult::ok(format!("“{}” shows (what {text:?} meant)", hit.chars().take(80).collect::<String>())),
                        );
                    }
                    if !close.is_empty() {
                        near = format!("; closest on the page: {}", close.iter().map(|c| format!("“{c}”")).collect::<Vec<_>>().join(", "));
                    }
                }
            }
        }
        self.end(
            line,
            ActionResult::fail(format!(
                "after {} s {text:?} {}{near}; look at what's there instead",
                secs as i64,
                if gone { "still shows" } else { "hasn't appeared" }
            )),
        )
    }

    async fn shows(&self, want: &str, app: &AppRef, page: Option<&crate::page::Page>, ocr: bool) -> bool {
        if let Some(page) = page {
            if let Ok(r) = crate::bridge::bridge().perform("read", page, serde_json::json!({}), 6.0).await {
                if format!("{}\n{}", r["title"].as_str().unwrap_or(""), r["text"].as_str().unwrap_or("")).to_lowercase().contains(want) {
                    return true;
                }
            }
        }
        let scan = self.platform.scan(app, 300).await;
        if scan.window.to_lowercase().contains(want)
            || scan.focused.to_lowercase().contains(want)
            || scan.elements.iter().any(|e| {
                e.label.to_lowercase().contains(want) || e.value.as_deref().map(|v| v.to_lowercase().contains(want)).unwrap_or(false)
            })
        {
            return true;
        }
        if ocr {
            if let Some(boxes) = self.platform.ocr(app).await {
                return boxes.iter().map(|b| b.text.to_lowercase()).collect::<Vec<_>>().join(" ").contains(want);
            }
        }
        false
    }

    async fn tab(&self, action: &Action, ctx: &mut Ctx) -> ActionResult {
        let op = action.str("op").unwrap_or("list").to_lowercase();
        let id = action.get("id").and_then(|v| {
            v.as_i64().or_else(|| v.as_str().and_then(|s| s.chars().filter(|c| c.is_ascii_digit()).collect::<String>().parse().ok()))
        });
        let bridge = crate::bridge::bridge();
        if !bridge.is_connected() {
            return ActionResult::fail("the browser extension isn't connected");
        }
        let exe = ctx.app.as_ref().filter(|a| self.platform.is_browser(a)).map(|a| a.exe.clone());
        if op != "list" && id.is_none() {
            return ActionResult::fail(format!("tab {op} needs id (from tab list)"));
        }
        match op.as_str() {
            "list" => match bridge.tabs(exe.as_deref()).await {
                Ok(t) if t.is_empty() => ActionResult::ok("no tabs"),
                Ok(t) => ActionResult::ok(format!("tabs in the front window:\n{}", crate::bridge::describe_tabs(&t))),
                Err(e) => ActionResult::fail(e.to_string()),
            },
            "switch" => {
                let line = self.begin("Switch tab");
                if let Err(e) = bridge.switch_tab(id.unwrap(), exe.as_deref()).await {
                    return self.end(line, ActionResult::fail(e.to_string()));
                }
                tokio::time::sleep(Duration::from_millis(400)).await;
                self.refresh(ctx).await;
                let title = ctx.page.as_ref().map(|p| p.title.chars().take(80).collect::<String>()).unwrap_or_default();
                self.end(line, ActionResult::ok(format!("tab {} is in front: {title}", id.unwrap())))
            }
            "close" => {
                let line = self.begin("Close tab");
                if let Err(e) = bridge.close_tab(id.unwrap(), exe.as_deref()).await {
                    return self.end(line, ActionResult::fail(e.to_string()));
                }
                tokio::time::sleep(Duration::from_millis(300)).await;
                self.refresh(ctx).await;
                self.end(line, ActionResult::ok(format!("closed tab {}", id.unwrap())))
            }
            "look" | "read" => {
                let line = self.begin("Read another tab");
                let Some(page) = bridge.snapshot_tab(id.unwrap(), exe.as_deref()).await else {
                    return self.end(line, ActionResult::fail(format!("couldn't read tab {}", id.unwrap())));
                };
                self.end(
                    line,
                    ActionResult::ok(format!(
                        "tab {} (read only — switch to it to act on it): {}\nURL: {}\n{}{}",
                        id.unwrap(),
                        page.title,
                        page.url,
                        page.list(),
                        if page.text.is_empty() {
                            String::new()
                        } else {
                            format!("\nText on screen: {}", page.text.chars().take(4000).collect::<String>())
                        }
                    )),
                )
            }
            _ => ActionResult::fail("tab op: list, switch, close or look"),
        }
    }

    async fn snap(&self, action: &Action, ctx: &mut Ctx) -> ActionResult {
        let Some(app) = ctx.app.clone() else { return ActionResult::fail("no app to screenshot") };
        let given = action.str("caption").unwrap_or("").trim().to_string();
        let number = self.snaps.lock().0.len() + 1;
        let caption = snap_caption(&given, number);
        let line = self.begin(&format!("Screenshot: {}", caption.chars().take(40).collect::<String>()));
        self.platform.bring_to_front(&app).await;
        tokio::time::sleep(Duration::from_millis(600)).await;
        let Some(shot) = self.platform.screenshot(&app).await else {
            return self.end(line, ActionResult::fail("couldn't capture the window"));
        };
        let file = self.save_snap(&shot.png, &caption);
        let waiting = {
            let mut s = self.snaps.lock();
            s.0.push(Snap { caption: caption.clone(), png: shot.png.clone(), pasted: false });
            s.2 = Some(Instant::now());
            let len = s.0.len();
            if len > 80 {
                s.0.drain(0..len - 80);
            }
            s.0.iter().filter(|x| !x.pasted).count()
        };
        self.platform.set_clipboard_png(&shot.png);
        self.end(
            line,
            ActionResult::ok(format!(
                "screenshot taken ({:?}), copied{}; {waiting} not pasted into the doc yet",
                caption.chars().take(60).collect::<String>(),
                file.map(|f| format!(" and saved to {}", f.display())).unwrap_or_default()
            )),
        )
    }

    fn save_snap(&self, png: &[u8], caption: &str) -> Option<PathBuf> {
        let mut s = self.snaps.lock();
        if s.1.is_none() {
            let stamp = chrono::Local::now().format("%Y-%m-%d %H.%M").to_string();
            let dir = crate::paths::home().join("Pictures").join("Clinqy Screenshots").join(stamp);
            if std::fs::create_dir_all(&dir).is_ok() {
                s.1 = Some(dir);
            }
        }
        let folder = s.1.clone()?;
        let count = std::fs::read_dir(&folder)
            .map(|d| d.flatten().filter(|e| e.path().extension().map(|x| x == "png").unwrap_or(false)).count())
            .unwrap_or(0);
        let name: String = regex::Regex::new(r#"[/\\\n\r\t"*?<>|:]+"#)
            .unwrap()
            .replace_all(caption, " ")
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
            .chars()
            .take(80)
            .collect();
        let path = folder.join(format!("{:02} {name}.png", count + 1));
        std::fs::write(&path, png).ok().map(|_| path)
    }

    async fn paste_snaps(&self, ctx: &mut Ctx) -> ActionResult {
        let Some(app) = ctx.app.clone() else { return ActionResult::fail("no app") };
        let todo: Vec<(usize, Snap)> = {
            let s = self.snaps.lock();
            s.0.iter().enumerate().filter(|(_, x)| !x.pasted).map(|(i, x)| (i, x.clone())).collect()
        };
        if todo.is_empty() {
            let n = self.snaps.lock().0.len();
            return ActionResult::fail(if n == 0 {
                "no screenshots taken yet; use snap first".to_string()
            } else {
                format!("all {n} screenshots are already pasted; snap new steps first")
            });
        }
        let line = self.begin(&format!("Paste {} screenshots", todo.len()));
        self.platform.bring_to_front(&app).await;
        let saved = self.platform.clipboard_text();
        self.platform.set_target(Some(&app));
        for (i, snap) in &todo {
            if let Some(s) = self.snaps.lock().0.get_mut(*i) {
                s.pasted = true;
            }
            self.platform.set_clipboard_text(&snap.caption);
            let _ = self.platform.press("ctrl+v");
            tokio::time::sleep(Duration::from_millis(250)).await;
            let _ = self.platform.press("enter");
            self.platform.set_clipboard_png(&snap.png);
            let _ = self.platform.press("ctrl+v");
            tokio::time::sleep(Duration::from_millis(1800)).await;
            let _ = self.platform.press("enter");
            let _ = self.platform.press("enter");
            tokio::time::sleep(Duration::from_millis(150)).await;
        }
        self.platform.set_target(None);
        if let Some(t) = saved {
            self.platform.set_clipboard_text(&t);
        }
        ctx.fingerprint = self.platform.fingerprint(&app).await;
        let folder = self.snaps.lock().1.clone();
        self.end(
            line,
            ActionResult::ok(format!(
                "pasted {} captioned screenshots where the caret was ({:?} … {:?}){}",
                todo.len(),
                todo.first().map(|t| t.1.caption.chars().take(40).collect::<String>()).unwrap_or_default(),
                todo.last().map(|t| t.1.caption.chars().take(40).collect::<String>()).unwrap_or_default(),
                folder.map(|f| format!("; all of them are also saved in {}", f.display())).unwrap_or_default()
            )),
        )
    }

    /// Dry run: mark the target and say what would happen. None = the action only looks, so it really runs.
    async fn rehearse(&self, kind: &str, action: &Action, ctx: &mut Ctx, rs: &mut RunState) -> Option<ActionResult> {
        const LOOK_ONLY: &[&str] = &[
            "open_app",
            "open_url",
            "scroll",
            "look",
            "read",
            "wait",
            "recall",
            "ask",
            "show",
            "point",
            "mark",
            "review",
            "assert",
            "extract",
            "dictionary",
        ];
        let op = action.str("op").unwrap_or("").to_lowercase();
        let read_ops: &[(&str, &[&str])] = &[
            ("event", &["list", "find", "search", "free", "busy"]),
            ("calendar", &["list", "find", "search", "free", "busy"]),
            ("reminder", &["list"]),
            ("files", &["find", "search", "list", "reveal", "show"]),
            ("application", &["find", "check", "list", "show"]),
            ("pdf", &["info"]),
            ("media", &["info"]),
            ("tab", &["list", "look", "read"]),
        ];
        if LOOK_ONLY.contains(&kind) || read_ops.iter().any(|(k, ops)| *k == kind && ops.contains(&op.as_str())) {
            return None;
        }
        if kind == "files" && ["organize", "sort", "tidy"].contains(&op.as_str()) && !action.flag("apply") {
            return None;
        }
        let text = action.str("text").map(|t| format!("“{}”", t.chars().take(40).collect::<String>())).unwrap_or_default();
        let what = match kind {
            "click" => "click".to_string(),
            "type" => format!("type {text}"),
            "choose" => format!("choose “{}”", action.str("option").unwrap_or("").chars().take(40).collect::<String>()),
            "upload" => format!("upload {}", action.str("file").and_then(|f| f.rsplit(['/', '\\']).next()).unwrap_or("a file")),
            "key" => format!("press {}", action.str("keys").unwrap_or("?")),
            "email" => format!("email {}", action.list("to").join(", ")),
            "event" | "calendar" => {
                format!("add “{}” to the calendar at {}", action.str("title").unwrap_or(""), action.str("start").unwrap_or("?"))
            }
            "reminder" => format!("{} reminder “{}”", if op.is_empty() { "add" } else { &op }, action.str("title").unwrap_or("")),
            "table" => format!(
                "write {} rows to {}",
                action.get("rows").and_then(|r| r.as_array()).map(|a| a.len()).unwrap_or(0),
                action.str("to").unwrap_or("csv")
            ),
            "shell" | "applescript" => "run a command".to_string(),
            _ => format!("{kind}{}", if op.is_empty() { String::new() } else { format!(" {op}") }),
        };
        let (mut rect, mut name) = (None, None);
        if action.contains_key("id") {
            if let Some(n) = web_index(action.get("id")) {
                match self.web_target(n, ctx, rs) {
                    Some((el, r)) => {
                        rect = Some(r);
                        name = Some(el.text);
                    }
                    None => return Some(ActionResult::fail(format!("element w{n} isn't on screen"))),
                }
            } else {
                match self.resolve(action.get("id"), ctx, rs).await {
                    Some(el) => {
                        rect = Some(el.rect);
                        name = Some(el.short_label());
                    }
                    None => return Some(ActionResult::fail("element isn't on screen")),
                }
            }
        } else if kind == "click" {
            if let (Some(x), Some(y)) = (action.num("x"), action.num("y")) {
                rect = self.platform.screen_point(x, y).map(|p| Rect::new(p.x - 18.0, p.y - 18.0, 36.0, 36.0));
            } else if let Some(t) = action.str("text") {
                name = Some(t.to_string());
            }
        }
        let target = name.map(|n| format!(" · {}", n.chars().take(30).collect::<String>())).unwrap_or_default();
        let line = self.begin(&format!("Would {what}{target}"));
        if let Some(r) = rect {
            self.buddy.mark(r, Some(&format!("would {what}").chars().take(24).collect::<String>())).await;
            tokio::time::sleep(Duration::from_millis(700)).await;
        } else {
            self.buddy.bubble(Some(&format!("would {what}")), 2.0);
            tokio::time::sleep(Duration::from_millis(500)).await;
        }
        self.current.lock().linger = 3.5;
        Some(self.end(
            line,
            ActionResult::ok(format!(
                "DRY RUN — not done: would {what}{target}. The screen didn't change; plan the next step as if it had worked."
            )),
        ))
    }

    /// Replays a workflow with no model; if a step breaks, the model finishes the job and the workflow is updated.
    /// Returns true if the model had to step in.
    pub(crate) async fn replay_or_heal(
        self: &Arc<Self>,
        workflow: crate::workflow::Workflow,
        params: std::collections::HashMap<String, String>,
        qa_test: Option<String>,
        opts: &RunOptions,
    ) -> bool {
        if self.platform.screen_locked() {
            self.finish(false, "The PC is locked — unlock it and run again");
            return false;
        }
        let mut app = self.current.lock().target.clone().or_else(|| self.platform.front_app());
        self.set_phase(Phase::Acting);
        self.buddy.set_mood(Mood::Acting);
        self.log(&format!("replay “{}” · {} steps, no model", workflow.name, workflow.steps.len()));
        let mut rs = RunState { request: self.request(), qa: qa_test.is_some(), test: opts.test, ..Default::default() };
        for (i, step) in workflow.steps.iter().enumerate() {
            self.set_narration(&step.summary());
            if step.action == "expect" {
                let want = step.to_action(&params, None).str("text").unwrap_or("").to_string();
                let mut pass = false;
                for _ in 0..5 {
                    if self.text_visible(&want, app.as_ref()).await {
                        pass = true;
                        break;
                    }
                    tokio::time::sleep(Duration::from_millis(600)).await;
                }
                self.push_step(
                    &format!("Check “{}”", want.chars().take(50).collect::<String>()),
                    if pass { StepState::Ok } else { StepState::Failed },
                );
                self.log(&format!("  {} expect {want}", if pass { "✓" } else { "✗" }));
                self.buddy.signal(pass);
                if qa_test.is_some() {
                    self.checks.lock().push(Check {
                        text: want,
                        pass,
                        note: if pass { String::new() } else { "not visible on screen".into() },
                    });
                    self.current.lock().trace.push(step.clone());
                    continue;
                }
                if !pass {
                    return Box::pin(self.heal(&workflow, i, &format!("expected “{want}” isn't on screen"), &params, qa_test, opts)).await;
                }
                continue;
            }
            let mut obs = observation::Observation::capture(&*self.platform, app.as_ref()).await;
            let mut id = None;
            if let Some(t) = &step.target {
                for attempt in 0..5 {
                    if attempt > 0 {
                        tokio::time::sleep(Duration::from_millis(500)).await;
                        obs = observation::Observation::capture(&*self.platform, app.as_ref()).await;
                    }
                    id = find_target(t, &obs);
                    if id.is_some() {
                        break;
                    }
                }
                if id.is_none() {
                    return Box::pin(self.heal(&workflow, i, &format!("couldn't find {} “{}”", t.role, t.label), &params, qa_test, opts))
                        .await;
                }
            }
            let mut ctx = Ctx {
                app: obs.app.clone(),
                elements: obs.elements.clone(),
                fingerprint: obs.fingerprint,
                page: obs.page.clone(),
                web_area: obs.web_area,
                typed: vec![],
                seen: obs.page.clone(),
            };
            rs.last_target = None;
            let r = self.perform(&step.to_action(&params, id), &mut ctx, &mut rs).await;
            if !r.ok {
                return Box::pin(self.heal(&workflow, i, &r.summary, &params, qa_test, opts)).await;
            }
            self.current.lock().trace.push(step.clone());
            app = ctx.app.clone();
        }
        if let Some(mut w) = crate::workflow::workflows().all().into_iter().find(|w| w.id == workflow.id) {
            w.runs += 1;
            crate::workflow::workflows().update(w);
        }
        let qa = self.current.lock().qa.is_some();
        self.finish(true, &if qa { "Test finished (replayed, no model)".to_string() } else { format!("Done: {}", workflow.name) });
        false
    }

    async fn heal(
        self: &Arc<Self>,
        workflow: &crate::workflow::Workflow,
        index: usize,
        reason: &str,
        params: &std::collections::HashMap<String, String>,
        qa_test: Option<String>,
        opts: &RunOptions,
    ) -> bool {
        self.log(&format!("  heal from step {}: {reason}", index + 1));
        self.push_step(
            &format!("Step {} changed ({}) — adapting", index + 1, reason.chars().take(60).collect::<String>()),
            StepState::Info,
        );
        let remaining: Vec<String> =
            workflow.steps[index..].iter().enumerate().map(|(i, s)| format!("{}. {}", i + 1, s.summary())).collect();
        let mut request = format!(
            "You're continuing the saved workflow “{}”. Steps before this point already ran. It got stuck at: {} — {reason}. Finish it from there, adapting to what's on screen now. Remaining steps:\n{}",
            workflow.name,
            workflow.steps[index].summary(),
            remaining.join("\n")
        );
        if !params.is_empty() {
            request += &format!("\nValues: {}", params.iter().map(|(k, v)| format!("{k} = {v}")).collect::<Vec<_>>().join(", "));
        }
        let qa_name = self.current.lock().qa.clone();
        if let Some(t) = &qa_test {
            request = format!("{}\n\n{request}", super::run::qa_prompt(qa_name.as_deref().unwrap_or(&workflow.name), t));
        }
        self.set_phase(Phase::Thinking);
        Box::pin(self.run(request, opts)).await;
        let done_steps = workflow.steps[..index].iter().filter(|s| s.action != "expect").count();
        let trace = self.current.lock().trace.clone();
        let enough = trace.len() > done_steps && trace.len() as f64 >= workflow.steps.len() as f64 * 0.6;
        if self.phase() == Phase::Done && qa_test.is_none() && enough {
            if let Some(mut w) = crate::workflow::workflows().all().into_iter().find(|w| w.id == workflow.id) {
                w.steps = trace;
                w.healed_at = Some(chrono::Utc::now().to_rfc3339());
                w.runs += 1;
                crate::workflow::workflows().update(w);
                self.log("  workflow updated with the fixed steps");
            }
        }
        true
    }

    /// Deterministic check: does this text appear on screen?
    async fn text_visible(&self, text: &str, app: Option<&AppRef>) -> bool {
        let want = text.trim().to_lowercase();
        let Some(app) = app.filter(|_| !want.is_empty()) else { return false };
        let obs = observation::Observation::capture(&*self.platform, Some(app)).await;
        if obs.text().to_lowercase().contains(&want) {
            return true;
        }
        if let Some(page) = &obs.page {
            if page.title.to_lowercase().contains(&want) || page.url.to_lowercase().contains(&want) {
                return true;
            }
            if let Ok(r) = crate::bridge::bridge().perform("read", page, serde_json::json!({}), 8.0).await {
                if r["text"].as_str().unwrap_or("").to_lowercase().contains(&want) {
                    return true;
                }
            }
        }
        self.platform
            .ocr(app)
            .await
            .map(|b| b.iter().map(|x| x.text.to_lowercase()).collect::<Vec<_>>().join(" ").contains(&want))
            .unwrap_or(false)
    }
}

/// The element on screen matching a saved target: role+label, then the label, then containment.
fn find_target(t: &Target, obs: &observation::Observation) -> Option<String> {
    let want = t.label.to_lowercase();
    if t.kind == "web" {
        let page = obs.page.as_ref()?;
        let e = &page.elements;
        return e
            .iter()
            .find(|x| x.role == t.role && x.text.to_lowercase() == want)
            .or_else(|| e.iter().find(|x| x.text.to_lowercase() == want))
            .or_else(|| e.iter().find(|x| x.role == t.role && !want.is_empty() && x.text.to_lowercase().contains(&want)))
            .map(|x| format!("w{}", x.index));
    }
    let e = &obs.elements;
    e.iter()
        .find(|x| x.role == t.role && x.label.to_lowercase() == want)
        .or_else(|| e.iter().find(|x| x.label.to_lowercase() == want))
        .or_else(|| e.iter().find(|x| x.role == t.role && !want.is_empty() && x.label.to_lowercase().contains(&want)))
        .map(|x| x.id.clone())
}

fn looks_like_powershell(s: &str) -> bool {
    regex::Regex::new(r"(?i)\b(Get-|Set-|New-Object|Start-Process|\$\w+\s*=|-ComObject)").unwrap().is_match(s)
}

/// A snap's caption as it goes in the doc: "Step 3: …" as is, otherwise numbered in order.
pub(crate) fn snap_caption(given: &str, n: usize) -> String {
    if given.is_empty() {
        return format!("Step {n}");
    }
    if regex::Regex::new(r"(?i)^(step|task|part|q(uestion)?)\s*\d").unwrap().is_match(given) {
        return given.to_string();
    }
    format!("Step {n}: {given}")
}

/// What a failed command's error means and what to do instead.
fn shell_hint(out: &str) -> String {
    if out.contains("is not recognized as") || out.contains("CommandNotFoundException") {
        return "\n→ That command isn't available on this PC. Use a PowerShell cmdlet (Get-ChildItem, Get-Content, Test-Path…), or do it on screen.".into();
    }
    if out.contains("Cannot find path") || out.contains("ItemNotFoundException") {
        return "\n→ Check the path: quote paths with spaces and use $HOME (\"$HOME\\Downloads\\resume stuff\\a.pdf\"), and list the folder or use files find to get the exact name.".into();
    }
    if out.contains("Access is denied") || out.contains("UnauthorizedAccess") {
        return "\n→ Windows refused access (a protected folder or an admin-only change). Don't retry it; tell the user what needs their permission.".into();
    }
    String::new()
}

/// Up to three lines of `text` sharing the most words with `want`.
pub(crate) fn closest(want: &str, text: &str) -> Vec<String> {
    let words =
        |s: &str| s.to_lowercase().split(|c: char| !c.is_alphanumeric()).filter(|w| w.len() >= 3).map(String::from).collect::<HashSet<_>>();
    let target = words(want);
    if target.is_empty() {
        return vec![];
    }
    let mut scored: Vec<(String, f64)> = text
        .split(['\n', '·', '|'])
        .map(str::trim)
        .filter(|l| l.len() >= 3 && l.len() <= 160)
        .filter_map(|l| {
            let share = words(l).intersection(&target).count() as f64 / target.len() as f64;
            (share >= 0.34).then(|| (l.to_string(), share))
        })
        .collect();
    scored.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap());
    let mut seen = HashSet::new();
    scored.into_iter().map(|x| x.0).filter(|l| seen.insert(l.to_lowercase())).take(3).map(|l| l.chars().take(80).collect()).collect()
}

/// Every word of `want` appears in `line` in order, at most 3 other words between each pair.
pub(crate) fn words_in_order(want: &str, line: &str) -> bool {
    let w =
        |t: &str| t.to_lowercase().split(|c: char| !c.is_alphanumeric()).filter(|s| !s.is_empty()).map(String::from).collect::<Vec<_>>();
    let (need, have) = (w(want), w(line));
    if need.len() < 2 || have.len() > need.len() + 8 {
        return false;
    }
    let mut at: isize = -1;
    for word in &need {
        let start = (at + 1) as usize;
        let Some(i) = have[start.min(have.len())..].iter().position(|h| h == word).map(|p| p + start) else { return false };
        if at >= 0 && i as isize - at > 4 {
            return false;
        }
        at = i as isize;
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn helpers() {
        assert!(is_form_submit("Submit application"));
        assert!(!is_form_submit("Easy Apply"));
        assert!(is_confirmation("Submit with your resume attached?"));
        assert!(!is_confirmation("What should I put for your college?"));
        assert!(words_in_order("Policy created", "Policy lab7-ecr created."));
        assert_eq!(snap_caption("Step 3: done", 1), "Step 3: done");
        assert_eq!(snap_caption("Chose plan", 2), "Step 2: Chose plan");
        assert!(!acts("checkbox"));
        assert!(acts("button"));
    }
}
