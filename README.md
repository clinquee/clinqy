<p align="center"><img src="assets/AppIcon.png" alt="" width="128" height="128"></p>

# Clinqy

**Your cursor's clingy partner.** Your Mac, on autopilot — and you can watch it work.

Clinqy is a macOS menu-bar assistant that uses your Mac the way you would. Press **⌃⌥**, type or say what you want, and a small glowing companion cursor goes and does it on screen. It clicks the Dock, types into the address bar, ticks the checkboxes and fills the form. It asks you before anything consequential, remembers useful things about you, and can learn a task by watching you do it once.

```
"book me a flight to Mumbai"         "where's the brightness setting?"
"tick Keynote and Design panel"      "what's the phone number on my resume?"
"message mom I'll be late"           "in the background, add a reminder to call Raj"
```

> **On Windows?** Clinqy runs there too, with the same browser extension, settings and workflows. [**Download it for Windows**](https://clinqy.vercel.app/api/windows-download) and see [Setup on Windows](#setup-on-windows).

## Setup guide

Download, paste one prompt into your coding agent, done. It needs macOS 14 or later on Apple silicon.

**1. Download** **[`Clinqy.dmg`](https://clinqy.vercel.app/api/mac-download)**, open it and drag Clinqy into Applications. Clinqy isn't notarized by Apple yet, so the first time you open it macOS blocks it: open **System Settings → Privacy & Security**, scroll down and click **Open Anyway**. (You can skip this step: the prompt installs Clinqy too, and then macOS doesn't block it.)

**2. Paste this into your coding agent** (Claude Code, Codex, agy, Cursor, Gemini CLI, Windsurf or OpenCode). There's nothing to fill in. It uses the AI you already have, in this order: Claude Code, then Codex, then agy, then an API key. It asks for Clinqy's permissions, adds the browser extension (Clinqy loads it into your browser itself), connects the agent you pasted it into, and checks everything. Want a particular AI? Change the first line to `claude cli`, `codex cli`, `agy cli`, `ollama qwen3-vl` or `anthropic api key` (or `openai`, `gemini`, `openrouter`).

````text
Model: auto
Connect to: this agent

Set up Clinqy for Mac (https://github.com/Amrit-Nigam/clinqy) on this Mac for me, using the two lines above. Run the
commands yourself. Only stop when you need my answer or a click that only I can do.

1. Install Clinqy (this also updates an older copy). It needs macOS 14+ on Apple silicon and no admin rights:
     curl -fsSL -o /tmp/Clinqy.dmg https://clinqy.vercel.app/api/mac-download
     v=$(hdiutil attach -nobrowse /tmp/Clinqy.dmg | grep -o '/Volumes/.*'); pkill -x Clinqy; rm -rf /Applications/Clinqy.app
     ditto "$v/Clinqy.app" /Applications/Clinqy.app; hdiutil detach -quiet "$v"; open /Applications/Clinqy.app
   From then on use the full path: c=/Applications/Clinqy.app/Contents/MacOS/Clinqy
2. Set up the model with `$c model <name>`, then read what it prints.
   - "auto" (or blank): run `$c model auto`. It uses what this Mac has: Claude Code, then Codex, then agy, then an API
     key. If it has none of them, install Claude Code (`curl -fsSL https://claude.ai/install.sh | bash`) and run
     `$c model claude`.
   - Otherwise map my choice: claude, codex, agy, ollama <model>, or an API key: anthropic, openai, gemini, openrouter.
   - It checks that the model really answers. If it says a CLI isn't logged in, ask me to run `claude` (or `codex`,
     `agy`) once in a new terminal and log in, wait for me, then run `$c model test`.
   - API key: don't ask me to paste the key into this chat. Run `$c settings` (it opens the file), tell me which line
     to paste the key into, wait until I've saved it, then run `$c model test`.
3. Run `$c permissions`. Clinqy asks macOS for what it still needs. Tell me to turn each one it lists on for Clinqy in
   System Settings → Privacy & Security, wait for me, and run it again until it says all are on. (After Screen
   Recording, macOS asks to quit and reopen Clinqy: tell me to let it.)
4. Add the browser extension with `$c extension install` (add `chrome`, `arc`, `brave` or `edge` to pick one). Clinqy
   loads it by itself and moves the mouse for a minute, so tell me before you run it. If it fails, walk me through it
   by hand: it prints the folder to pick.
5. Connect coding agents with `$c connect <names>` (claude, codex, agy, cursor, gemini, windsurf, opencode). "this agent" means
   you: Claude Code → claude, Codex → codex, Antigravity → agy, Cursor → cursor, Gemini CLI → gemini, Windsurf →
   windsurf, OpenCode → opencode. Skip this if it says none.
6. Check it: run `$c doctor`, then `~/.local/bin/clinqy run --dry "open example.com"`, and show me the planned steps.
   Fix anything that isn't ready (the log is ~/Library/Logs/Clinqy/agent.log). Finish with a short summary, and tell
   me: tap ⌃⌥ (Control + Option) to type a request, hold it to say it.
````

**3. Tap ⌃⌥** and ask something, like "where's the brightness setting?"

**No coding agent?** Open Clinqy: the first time, its setup window walks you through the model, the permissions, the browser extension and the keys (menu-bar icon → **Set Up Clinqy…** brings it back). The Dashboard tab shows usage and lets you change the active provider, model and shortcuts. Or do the same in a terminal:

```bash
clinqy model              # which AI Clinqy uses; `clinqy model agy` (or claude, codex, ollama…) picks one and checks it answers
clinqy permissions        # which macOS permissions Clinqy still needs (it asks macOS for them)
clinqy extension install  # Clinqy loads its own extension into your browser (add chrome, arc, brave or edge to choose)
clinqy connect claude     # add Clinqy to coding agents over MCP: claude, codex, agy, cursor, gemini, windsurf, opencode
clinqy doctor             # what's ready
```

**Updates.** Clinqy for Mac checks GitHub for a new version once a day. When there is one, it asks once, and the menu-bar menu shows **Update to Clinqy x.y.z…**: it installs it and reopens, keeping your settings, memory, history and permissions. You can also run **Check for Updates…** from the menu, or `clinqy update` in a terminal.

API keys go in the settings file (`clinqy settings` opens it); all the settings are explained in [Choosing the model](#choosing-the-model) and [Configuration](#configuration). Building from source instead? See [Build & run](#build--run).

While a task runs, Clinqy uses an IOKit `PreventUserIdleSystemSleep` assertion to keep the Mac awake. Foreground tasks also prevent idle display sleep. Overlapping tasks share reference-counted assertions; finishing, failing, stopping, or quitting releases the relevant leases. Queued tasks hold none. This prevents idle sleep, not manual locking, lid-close sleep, or shutdown.

Mac releases use `MAC_VERSION` as the version source. `./make-dmg.sh` builds `dist/Clinqy.dmg` and a portable SHA-256 file; `./scripts/verify-mac-release.sh` checks the signed bundle and bundled extension. After committing and pushing release sources, maintainers run `./scripts/stage-mac-release.sh` on the signing Mac to upload a draft using the existing certificate. Merging into `main` runs Mac checks; only a successful main-branch check can publish a staged draft whose Mac sources match the merged commit. Windows stays the repository's latest release. The website, README and setup prompt use a stable Mac download endpoint that selects published Mac releases, so drafts and merge-time publishing do not break download links. No signing private key is uploaded to CI. Windows download buttons and setup commands resolve the latest published `windows-v` ZIP and installer independently; the site displays each platform’s published version. On Windows 0.3.1+, `clinqy update` upgrades in place. Windows 0.3.0 and older should reinstall the latest ZIP, keeping their data.

## Telegram tasks and attachments (Mac)

Open **Telegram…** from Clinqy's menu to connect your bot and pair your private chat. Send a photo or file with a caption such as “send this image to Onik on WhatsApp” or “summarize this PDF”. Clinqy downloads the attachment to your Mac and gives the task its exact local path.

Choose **Normal** (uses the Mac's screen and input) or **Background** (isolated browser tabs and supported file tools) before each new task. Say “use normal mode Clinqy”, `foreground: …`, or `background: …` to choose in the request. The mode-choice message becomes one status card that updates in place and shows the final outcome. Background browser tasks use the same concurrent queue as the Mac UI; desktop work has its own slot.

You can send files first, then an instruction, or reply to an earlier attachment. Album files stay together. New messages start separate requests; reply to a task's status message to add instructions or files to that task. `/new <task>` always creates a separate request. A new application link is never silently appended to another application.

Each file must fit Telegram's 20 MB download limit. Failed or missing attachments prevent execution without blocking the next queued task. Downloaded files stay in `~/Library/Application Support/Clinqy/Telegram/` for follow-ups. `/runs` (also `/tasks`) lists this chat's tasks; `/task <id>` selects one. `/status`, `/result`, `/screenshot` and `/stop` accept a task ID. `/stop` stops only the selected Telegram task; `/stop all` clears Telegram tasks and pending choices without stopping unrelated Mac work.

Questions have task-specific reply buttons that expire after answering. Reply to the question itself when several tasks need input. Passwords and codes stay on the Mac. Asking “how can I do it?” keeps the task paused. **Open task on Mac** or `/open` reveals its pinned tab/window; solve a CAPTCHA yourself there, then reply when done.

`/status` or “how far along?” shows the selected task's mode, stage and completed steps. Automatic progress edits the existing card rather than posting new messages. `/screenshot` captures only the task's pinned tab/window, without selecting unrelated windows, and pauses during private input. Images are sent on request; completion sends no automatic photo or image-error message. Attached images reach the model as actual visual input. For requested page images, Clinqy discovers article sources and sends actual photos; blocked downloads can use a crop of the fully visible image in the owned task tab. Media requests require acknowledged photo delivery before reporting success. Grouped browser work uses one parent card, with child questions routed to the correct task and detailed results available on demand.

`/result` or “what did you fill?” shows the full output, including every form field, warnings and links; long output spans message chunks. Form submission still requires a review of the actual answers with **Submit** or **Edit**. Changed answers or another form require a new review. Completion distinguishes filling from submission and avoids repeating an automatically generated result card. Follow-ups such as “change the location to Pune” retain the previous task's output as context for 30 minutes. Saved text outcomes remain available after restarting.

Run `tests/telegram.sh` and `node tests/telegram-screenshot.mjs` to check conversation routing, attachment handling and screenshot targeting with mocked APIs. `tests/site/telegram-review.html` is a local-only demo form for background conversation checks; it never sends an application anywhere.

## Isolated background work (Mac)

Background web tasks default to **Clinqy's own inactive tabs in your signed-in browser**, controlled through the Clinqy extension. They appear in a **Clinqy** tab group where supported (Arc uses separate tabs) while you continue using other tabs, windows or apps. The task stays pinned to its browser connection and can only read or act on its own tabs. Existing website sessions are shared with that browser profile; password-manager prompts, security dialogs and expired logins may still need your input. Chrome displays its debugging indicator while the task is attached.

Install or reload the extension, then choose **Dashboard → Background → Signed-in browser tabs** (the default). With multiple connected browsers, Clinqy prefers `BACKGROUND_BROWSER` (Google Chrome by default); otherwise it uses the focused connected browser, or the sole connection. Connect only the intended profile if multiple profiles are open in the same browser. A missing or disconnected extension stops browser work instead of switching to a different browser or your desktop. On completion, debugging detaches and result tabs remain available. At the next task, old inactive task tabs close; an active result tab or one playing audio is handed over to you.

While Clinqy works, its tab shows a temporary **◉ Clinqy** title, a blue page-edge halo and a small status badge. A page-local cursor follows targets and shows click ripples without moving your system pointer in background mode. Feedback lets clicks pass through, respects reduced motion and disappears when work finishes or the connection closes. Your page's latest title is restored afterward.

Normal foreground navigation also uses the extension when connected: one request opens one identified tab. Retrying an uncertain open reuses its tab instead of creating a duplicate. Streamed and final actions recognize equivalent address spellings such as `youtube.com` and `https://www.youtube.com/`.

**Separate headless Chrome** remains available in Background settings, or via `BACKGROUND_WEB_MODE=headless` in the settings file (`extension` selects signed-in tabs). This option uses its own data directory at `~/Library/Application Support/Clinqy/ChromeWorker/` and separate sign-ins. Use **Clinqy menu → Sign In to Worker Chrome…**, then **Finish Worker Chrome Sign-in** before running a headless task.

Use **Show Background Work** to open the task tab, or the screenshot view in headless mode. Files, PDFs, media and supported services use direct tools. Finder reveal, native app input, clipboard shortcuts, arbitrary shell/AppleScript and conversions that open iWork require an explicit switch to foreground mode. Background browser control is not a separate macOS desktop or sandbox for native apps.

**Tasks & Recovery…** and Telegram **`/tasks`** read the same persisted task state: current stage, completed steps, last confirmed action and results. Requests, attachment paths and checkpoints are saved in owner-only `~/Library/Application Support/Clinqy/tasks.sqlite`. Existing `tasks.json` records are imported once; the original file is preserved. Writes update a single durable SQLite row per checkpoint; the UI holds recent tasks while older records remain searchable by ID. After a restart, active tasks become **Interrupted**, retaining any in-flight action marker. They never resume or repeat sends/submissions automatically. Check the real outcome and send fresh instructions. Restored queued requests require review: start them in the Mac panel or use **`/run <id>`** in the paired Telegram chat. Missing files and unreadable task storage prevent execution. Downloading/staged attachments and unanswered questions are not resumed; resend any message that did not receive an acceptance reply.

Actions distinguish **confirmed**, **unverified**, **failed** and **refused** outcomes. Input sent to an app is not automatically a confirmed checkpoint. Uncertain sends/submissions stay stopped until the requested outcome is checked with fresh evidence; generic visual changes and closed dialogs do not prove success. Native screenshots, accessibility elements and coordinate actions are bound to one observed window; stale or ambiguous targets require another observation.

Scheduled requests and daily workflows always start in background mode with no foreground selection, clipboard or follow-up context. Each occurrence is saved as a unique task before the schedule advances, so a handoff retry cannot create a duplicate job. Restored queued occurrences require review; interrupted submissions never replay automatically. New schedules default to catching up once after wake/relaunch, coalescing missed repeats. The New Schedule menu also offers skipping runs more than two hours late; older schedules keep that previous skip behavior. Storage failures and skipped runs appear in the Schedules menu. Schedules run locally while Clinqy is open and the Mac is awake; closing the chat window does not quit Clinqy.

Validation: `zsh tests/browser-navigation.sh` checks URL and streamed-action identity. `node tests/extension-background.mjs` checks extension task ownership, inactive tab creation, uncertain-open deduplication across worker restarts, focus emulation, audio-preserving cleanup and failed attachment with mocked browser APIs. `zsh tests/background-tasks.sh` checks persistence, interruption, queue review and capability routing. `zsh tests/chrome-worker.sh` uses two temporary headless Chrome profiles and local dummy pages to check form input, upload bytes and intercepted choosers, screenshots, targeting, orphan cleanup, disconnect handling and unchanged host clipboard/foreground application. It never uses your signed-in browser or submits to an external site.

`zsh tests/scheduler.sh` checks durable schedule dispatch, failed writes, restart deduplication and missed-run policy. `zsh tests/observations.sh` checks screenshot scaling and stale-window geometry without operating your desktop.

`zsh tests/native-compatibility.sh` probes native targeting against two disposable fixture windows only. It checks exact-window observations, moved-window rejection and unchanged foreground app, pointer, clipboard and existing window order. It explicitly skips when Accessibility permission or the graphical session is unavailable; it never prompts for permissions or sends input to your applications. A passing fixture probe does not enable general native background control. Legacy daily workflow schedules still run only during their configured minute; new scheduled requests expose their missed-run policy explicitly.

## Setup on Windows

Download, paste one prompt into your coding agent, done. It needs Windows 10 (1903 or later) or Windows 11, on x64, and no admin rights.

**1. Download** **`Clinqy-windows-x64.zip`** from the [latest Windows download](https://clinqy.vercel.app/api/windows-download), unzip it and double-click **`Install Clinqy.bat`**. It installs Clinqy to `%LOCALAPPDATA%\Programs\Clinqy`, adds it to the Start menu, puts the `clinqy` command on your PATH and starts it. Open at login is off until you turn it on in settings (Dashboard → General). The app isn't code-signed yet, so if Windows SmartScreen warns you, click **More info → Run anyway**. If Microsoft Defender quarantines it, open Windows Security → Protection history, choose the Clinqy entry and allow it on your device. (You can skip this step: the prompt installs Clinqy too.)

**2. Paste this into any AI you use** (Claude Code, Codex, agy, Cursor, Gemini CLI, Windsurf, OpenCode, or a chat with no terminal, which walks you through it). There's nothing to fill in. It uses the AI you already have, in this order: Claude Code, then Codex, then agy, then Ollama. It connects your coding agents, has Clinqy add its own browser extension, and checks everything. Want a particular AI? Change the first line to `claude`, `codex`, `agy`, `ollama` or `anthropic` (or `openai`, `gemini`, `openrouter`).

````text
Model: auto
Connect to: all

Set up Clinqy for Windows (https://github.com/Amrit-Nigam/clinqy) on this PC for me, using the two lines above. Run the
commands yourself in PowerShell. Only stop when you need my answer or a click that only I can do. If you can't run
commands here, tell me to open PowerShell, give me one command at a time to paste, and work from what I send back.

1. Install Clinqy (this also updates an older copy). It needs Windows 10 or 11 and no admin rights:
     powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((irm 'https://clinqy.vercel.app/api/windows-download?asset=installer'))) -Url 'https://clinqy.vercel.app/api/windows-download'"
   From then on use the full path, because PATH only updates in new terminals:
     $c = "$env:LOCALAPPDATA\Programs\Clinqy\clinqy.exe"
2. Tell me Clinqy is about to use my mouse for a moment to add its browser extension, then run setup:
     & $c setup --model <Model> --connect <Connect to>
   Model is auto, or one of claude, codex, agy, ollama, anthropic, openai, gemini, openrouter. Auto uses what this PC
   has: Claude Code, then Codex, then agy, then Ollama. Connect to is all, none, or names with commas from claude, codex,
   agy, cursor, gemini, windsurf, opencode. "this agent" means you. Setup does everything it can and ends with what's ready and a
   "Needs you" list.
3. Work through "Needs you", then run the same setup command again, until it says everything is ready:
   - No AI installed: install Claude Code with `winget install Anthropic.ClaudeCode`.
   - A CLI isn't logged in: ask me to run `claude` (or `codex login`, or `agy`) once in a new terminal, and wait for me.
   - An API key: don't ask me to paste it into this chat. Run `& $c settings` (it opens the file), tell me which line to
     paste the key into, and wait until I've saved it.
   - The extension: walk me through it by hand with the folder setup printed.
4. Check it: run `& $c doctor`, then `& $c run --background "open example.com and tell me the page title"`, and show me
   the result. Fix anything that fails (the log is %LOCALAPPDATA%\Clinqy\Logs\agent.log).
5. Finish with a short summary, and tell me: tap Ctrl+Alt to type a request, hold Ctrl+H to say it, the gear on the bar
   opens settings (AI and model, background tasks, all the keys), and any coding agent you connected needs a restart to
   see Clinqy's tools.
````

**3. Tap Ctrl+Alt** and ask something.

**Want every step, what you should see and fixes for common problems?** Read the [step-by-step Windows setup guide](windows/SETUP.md).

**No AI to paste it into?** Run this in a new terminal after installing:

```powershell
clinqy setup
```

It does the same steps and ends with a "Needs you" list. Each step also works alone: `clinqy model`, `clinqy models`, `clinqy extension install`, `clinqy connect all` and `clinqy doctor`.

### The Clinqy window

Click the gear on the command bar, or the tray icon → **Dashboard…**, for the same setup and dashboard as on the Mac:

- **AI & Model:** switch between Claude Code, Codex, agy and the rest, and choose from the models each one really offers on this device. Each device keeps its own choice. Automatic uses the first one you have.
- **Background:** the switch for background tasks, signing in to the background browser, and the live view.
- **Tasks:** what ran, what happened, and what to check after an interruption.
- **Shortcuts:** change the keys, and see every shortcut in one place.
- **Overview, Usage, General:** requests and tokens, warnings, Open at login, voice language, memory.

### Background tasks

Say "in the background" in a request, or turn on **Background** on the bar, and Clinqy works in a hidden Chrome or Edge with its own profile while you keep your mouse, keyboard and windows. A small badge shows it's working: click it to watch, pause, steer or stop.

- Web pages, files and PDFs work hidden. Sites that need a login: sign in once under **Background → Sign in…**, because the hidden browser has its own sign-ins.
- If a task needs a desktop app, a card in the top right says **Clinqy needs the foreground**, with **Run in foreground**, **Keep in background** and **Stop task**. It waits for you, and tells you when it switches.
- Questions and form reviews come on the same card, which never takes the keyboard from you.

### Using it

| | |
|---|---|
| **Tap Ctrl+Alt** | open the command bar, type what you want, press Enter |
| **Hold Ctrl+H** | talk: it listens only while you hold it, and sends when you let go (the voice model downloads the first time) |
| **Ctrl+Alt while it works** | add something or change the plan, **Pause / Resume**, or **Stop** |
| **Enter** | send your request or answer |
| **Click the tray icon while it works** | stop at once (the tray menu also has Pause) |
| **Esc** | close the bar |

The bar's footer has **Dry run**, **Background**, **Circle**, **Watch**, **Skills**, **History** and the settings gear. Only the left Alt key counts, so typing with AltGr never opens Clinqy. To use other keys, set `HOTKEY=ctrl+win` (or `ctrl+shift`, `alt+win`) or `TALK_HOTKEY=ctrl+shift+space` in the settings file. A quick tap of Ctrl+H still reaches the app in front (Replace, History…).

**Updating** means running the installer again; your settings, memory and history are kept. **Uninstalling** means double-clicking `Uninstall Clinqy.bat` in `%LOCALAPPDATA%\Programs\Clinqy`. More detail, including building from source, is in [windows/README.md](windows/README.md).

---

## Features

- **One agent loop.** A long-lived Claude session (or Antigravity session with `--agy`) reads the screen, picks actions, acts, checks the result and repeats until the task is done. Each step takes about 1–2 s.
- **Works like a person.** It opens apps from the Dock (or Spotlight), opens websites by typing into the address bar, types at a human rhythm with real key codes, and clicks for real. Your pointer is put back where it was.
- **Clicks that check themselves.**
  - **Checks every click.** After each click it looks for an effect. If nothing changed, it tries the next way: a real mouse click, then a click through the page, then focus plus a key (for checkboxes, tabs and options). It remembers which way works on each site.
  - **Aims carefully.** It waits until the target stops moving, and clicks a spot that isn't covered (a badge over a button's middle).
  - **Re-finds elements.** If the page re-rendered the element, it re-reads the page and finds the same element again, even when a count in its name changed.
  - **Dropdowns.** It searches the list the dropdown opened and scrolls lists that load as you go. Matching is loose ("USA" = "United States", "Sr." = "Senior", "Bangalore" = "Bengaluru"). If the list can't be clicked, it uses the arrow keys.
  - **Uploads.** A file goes into the page's upload field directly, through the site's own upload button (even one that makes its field on the spot), or through the Mac file picker as a last resort.
  - **Apps with few listed elements.** In WhatsApp and other apps that expose little to Accessibility, it clicks text it finds on screen with text recognition.
- **Companion cursor.** A glowing blue arrow rides beside your pointer. It flies in arcs to its targets, frames what it's about to use, ripples on click, and floats away when you're idle. It can **mark** things on screen for you with a hand-drawn circle and arrow ("where is…").
- **Sees the whole Mac.**
  - Native apps through the Accessibility tree (Electron apps too).
  - Web pages through a **browser extension**: exact elements, verified typing that survives autofill, dropdowns, reading.
  - Documents through PDFKit, and scans or images through on-device OCR.
  - Scriptable apps through their **AppleScript dictionaries** in foreground mode; background mode uses supported direct tools and an isolated Chrome worker.
- **Voice.** Hold ⌃⌥ and talk. On macOS 26 the **Mac's own speech model** (SpeechAnalyzer, the one behind Dictation, Notes and Voice Memos) writes the text on-device as you speak, so it's ready a moment after you stop. Nothing to download into Clinqy. Before macOS 26, Apple dictation does it.
- **Asks when it needs you.** It asks for details, choices and passwords (hidden input), with quick-choice buttons or a voice answer.
- **Safety enforced in code:**
  - Clicks on Pay, Buy, Book, Send, Submit, Delete and similar need your OK, unless you asked for exactly that.
  - It checks with you before acting while you're on a call.
  - A one-click stop sits in the menu bar.
  - A watchdog stops a run that's stuck for 30 s.
- **Result cards.** Options, prices, plans and summaries appear in a card you can copy from.
- **History.** Every run is saved. You can **Continue** from one or **Run again**.
- **Memory.** After each task it keeps lasting facts about you (people, preferences, usual apps). It never saves passwords, card numbers or OTPs.
- **Persistent task memory (Mac).** Runs are also archived in a local SQLite search index, beyond the History window's 200 recent runs. Each new task retrieves a small amount of related experience, including outcomes, steps and linked follow-up corrections. Exact repeats of proven, non-sensitive routes are checked before model-session setup; other matches guide the agent while it checks the current screen. Explicit corrections stop the old route being replayed as proven. A correction to the latest task can attach for up to 24 hours; other automatic follow-ups attach for 20 minutes. Existing retained history is imported automatically; records already discarded by older builds cannot be reconstructed. Clearing History clears the task archive too.
- **Parallel delegation (Mac).** The lead can assign independent research, analysis, drafting and review jobs to separate model sessions while continuing its own work. Up to three workers run at once by default; dependencies wait for their inputs, and results return automatically or through `collect`. Workers read supplied files/public URLs; `browser:true` reads pages in their own headless Chrome tabs using the worker profile's sign-ins. They return evidence and drafts to the lead, which handles edits, clicks and submissions. Stopping or failing the parent cancels its workers. Worker failures/timeouts stop dependent jobs while independent jobs continue. User corrections cancel outstanding jobs; late results from cancelled jobs are ignored. Worker results and assignments are retained in task memory. Runs that generate content through workers require fresh reasoning and cannot become UI-only replays with stale text. Delegation is chosen for substantial independent work; simple tasks stay direct. Concurrent model requests can use more tokens or encounter provider rate limits.
- **Windows memory and workers.** The Windows core also keeps a SQLite task archive beyond the recent History menu, retrieves prior outcomes and follow-up corrections, streams API replies, and runs bounded asynchronous workers with dependencies and duplicate reuse. Windows workers currently accept public HTTP text and local text files; browser-authenticated sources use the Mac isolated worker. Worker-generated tasks always require fresh reasoning rather than a UI-only replay.
- **Runtime efficiency.** HTTP providers stream validated early actions, retain a bounded conversation with explicit historical excerpts, and retry rate limits within a request deadline. Mac actions use direct app/browser navigation and immediate input by default; `HUMAN_MOTION=on` restores decorative waiting. DOM candidate and frame caches invalidate when documents change; geometry and field values remain fresh. Shared source snapshots are scoped to one task. Run logs separate model time from task wall time; Mac logs also record startup, action and checkpoint phases (overlapping phases must not be added as total wall time).
- **Watch & learn.** Click *Watch & learn*, do a task yourself, and press ⌃⌥ to stop. It becomes a reusable **skill** with fill-in parameters.
- **Selected text and the clipboard.** Whatever you had highlighted is sent along with your request. With nothing highlighted, something you copied in the last 10 minutes counts as "this" ("translate this", "reply to this", "add this to my tracker"). Clipboard text is only sent when the request points at it, and password-manager copies are never kept.
- **Saved workflows first.** If a request matches a saved workflow (same words, only the typed values differ: "message mom I'm stuck in traffic" vs. the saved "message mom I'll be late"), it's replayed with no model. The model only steps in to heal a step whose target is gone. Turn it off with `WORKFLOW_FIRST=off`.
- **Calendar & Reminders.** Events and reminders go straight through EventKit, with no clicking through Calendar. "Schedule a call with Priya Thursday afternoon" checks your free time and books the first slot that fits.
- **Files.** Finds files through Spotlight: name, content, the site a download came from, who sent it ("the PDF I got from HR last week"). It also renames in bulk, moves files and sorts Downloads into subfolders. Every rename or move can be undone. Deleting only moves to the Trash.
- **Moving data between apps.** It pulls tables out of a web page, a PDF or a CSV and writes them into a CSV, a new Numbers or Excel document, the clipboard (paste into any spreadsheet), or a web form.
- **Dry run.** Toggle **Dry run** in the command bar (or start a request with "dry run:") and the companion points at everything it would click and type, without doing it. Opening apps and sites, scrolling and reading still happen so it can plan the whole path.
- **Follow-ups by voice.** After a spoken task finishes, the mic stays open for 5 s: "now email that to Rahul" builds on what just happened. Silence, "no thanks" or "bas" closes it. `FOLLOW_UP=off` turns it off.
- **Hindi and Hinglish.** Menu → **Voice Language**: Auto-detect, English, Hinglish (Hindi-English written in Latin letters, the way people text) or Hindi. Requests in any of these are understood, and replies and messages keep your style.
- **Never touches your tabs.** Websites open in new tabs. It only reuses tabs it opened itself.

## Requirements

- macOS 14+ on Apple silicon (tested on an M4), or Windows 10 (1903+) / 11 on x64 with the [Windows download](#setup-on-windows) (the rest of this list is for building the Mac app)
- Swift 5.9+ (Xcode Command Line Tools are enough)
- A model to drive it, one of:
  - [Claude Code](https://claude.com/claude-code), [Codex CLI](https://github.com/openai/codex) or [Antigravity CLI (`agy`)](https://antigravity.google/docs/cli/overview), installed and logged in (your existing login is used), or
  - an API key for Anthropic, OpenAI, Gemini or OpenRouter, or
  - a local model through Ollama or any OpenAI-compatible server.

  See [Choosing the model](#choosing-the-model).
- Chrome, Arc, Brave or Edge for the browser extension (optional but recommended)

## Build & run

```bash
./build.sh run        # builds build/Clinqy.app, signs it, and launches it
```

On first launch, grant the permissions Clinqy asks for (menu bar icon → **Check Permissions…**):

| Permission | Why |
|---|---|
| Accessibility | Read buttons and fields, click and type |
| Screen Recording | Screenshots and OCR when the Accessibility tree isn't enough |
| Microphone & Speech Recognition | Voice input |
| Automation | AppleScript fallback for scriptable apps |
| Calendars & Reminders | Adding and finding events and reminders (asked the first time you schedule something) |

The first `./build.sh` on a Mac creates a self-signed "CursorBoy Local Signing" certificate in your login keychain and signs every build with it. macOS ties Accessibility and Screen Recording to the app's signature, so this keeps them granted across rebuilds. Without it each rebuild would quietly lose them while System Settings still showed Clinqy switched on.

Voice uses the speech model macOS already keeps for Dictation. If this Mac doesn't have the one for your voice language yet, macOS fetches it once (it's shared with the rest of the system).

### Browser extension

1. Open `chrome://extensions` (or `arc://extensions`, `brave://extensions`…).
2. Turn on **Developer mode** and click **Load unpacked**.
3. Pick the `extension/` folder in this repo.

It connects to the app on `ws://127.0.0.1:47823`, and only browser-extension origins are accepted. The app reloads the extension by itself when its version (in `manifest.json`) differs from the one the app was built with; `clinqy extension reload` forces it. Elements in embedded frames (e.g. a Greenhouse form inside a careers page) are listed and driven like the rest.

## Using it

| | |
|---|---|
| **⌃⌥** (tap Control + Option together) | Open the command bar |
| **⌃⌥** (hold) | Talk; release to send |
| **⌃⌥** while working | Tap: add context or change the plan mid-task · hold: say it |
| **⏹** (command bar or menu bar) | Stop the current task |
| **Esc** | Close the command bar |
| **Watch & learn** | Record yourself doing a task; ⌃⌥ or ⏹ to stop and learn it |
| **Skills / History** | Footer tabs in the command bar |

### URL scheme (for scripting)

Every link must carry `&token=<~/.config/clinqy/cli-token>` (`?token=` when it has no other parameters): web pages can open `clinqy://` links too, and must not be able to start tasks or answer questions. The `clinqy` command adds it for you.

```
clinqy://run?task=<text>[&test=1][&dry=1]   run a task in the frontmost app (test=1: not saved to history or memory; dry=1: dry run)
clinqy://answer?text=<text>         answer the current question
clinqy://add?text=<text>            add context to the running task
clinqy://cancel                     stop the current task
clinqy://qa?path=<file>|text=<test>&out=<report.json>[&relearn=1][&model=…]
clinqy://workflow?name=<name>[&<input>=<value>…]
clinqy://watch · clinqy://stop-watching
clinqy://reload-extension
clinqy://browser?cmd=page|read|url&id=<id>  what's in the focused browser tab → Application Support/Clinqy/cli/<id>.txt
```

## The `clinqy` command: QA and workflows for any coding agent

`./build.sh` installs `clinqy` to `~/.local/bin`. Any terminal or coding agent (Antigravity CLI, Claude Code, Codex, Cursor, OpenCode…) can call it. It hands the job to the running app, which has the permissions, the browser extension and the cursor.

```bash
clinqy qa tests/qa/                      # run every test in a folder
clinqy qa login.md --json                # one test, machine-readable report
clinqy qa "Go to https://example.com
Expect: Example Domain"                     # inline test
clinqy qa login.md --relearn --model opus
clinqy run "open github"                 # a task, like one asked in the app (saved; carries on by itself if it runs out of steps)
clinqy run --test "open localhost:3000"  # a throwaway run: not saved, no carrying on
clinqy run --dry "book a cab home"       # show every click and keystroke, do none
clinqy workflow "Fill form" "Your name=Priya"
clinqy workflows
```

**QA tests** are plain English, one step per line, with an optional `# Title`. Lines starting with **Expect / Check / Verify** are assertions:

```markdown
# Feedback form: name and sessions
Go to http://127.0.0.1:8765/form.html
Type Amrit Nigam as the name
Tick Keynote and Design panel
Expect: the page title shows name=Amrit Nigam
```

- **First run (learn):** the model carries out the test and compiles a **deterministic script** (actions, how to find each target, and checks). It's saved in `.clinqy/` next to the test, so you can commit it.
- **Every run after that (replay):** **no model**. Each step is found by role and label, and each check is "this text is on screen". It's fast (about 4 s for the example), free and repeatable.
- **UI changed? (heal):** if a step can't find its target, the model takes over from there only, the test still reports pass or fail, and the compiled script is updated.
- **Result:** `PASS`/`FAIL` with each check and the steps before a failure. Exit code 0 means everything passed. `--json` gives the full report (name, passed, mode `replay`/`learned`/`healed`, durationMs, steps, checks, message).
- Tests run unattended: the agent never asks questions, doesn't touch History or memory, and loads pages fresh.
- **QA cursor:** during tests the companion becomes an **amber targeting reticle with a "QA" tag**. Checks flash ✓ (green pop) or ✕ (red shake).

### The `/clinqy` skill for coding agents

[`skills/clinqy/SKILL.md`](skills/clinqy/SKILL.md) teaches a coding agent when and how to use the `clinqy` command: read the tab you have open (`clinqy page`, `clinqy page read`), click through a flow in your real browser (`clinqy run --test "…"`), and run your plain-English UI tests (`clinqy qa`). It also tells the agent to say before it takes over your screen and never to submit, send, pay or delete unless you asked for exactly that.

Install it for Claude Code:

```bash
mkdir -p ~/.claude/skills/clinqy && curl -fsSL https://raw.githubusercontent.com/Amrit-Nigam/clinqy/main/skills/clinqy/SKILL.md -o ~/.claude/skills/clinqy/SKILL.md
```

Claude Code then uses it on its own when you say things like "check my browser" or "test this in the browser", or when you type `/clinqy`. Other agents (Cursor, Codex, agy, Gemini CLI, Windsurf and OpenCode) can use Clinqy over MCP instead; see step 5 of the [setup guide](#setup-guide).

**Workflows (routines without a model).** Every successful run records exactly what it did. In **History**, hover a run and click **Save workflow**. Typed text becomes named inputs, defaulting to the original values. Saved workflows appear under **Skills → Workflows**:
- **Run:** replays it with no model.
- **Daily…:** schedules it (for example 09:00, once a day).
- **Delete.**

From the terminal: `clinqy workflow <name> "Input=value"`. A step that breaks is healed by the model, and the workflow is saved with the fix.

**How runs are going.** `Clinqy stats [days]` gives the success rate (overall and per app), the slowest runs, a per-turn breakdown of model time vs action time (from `agent.log`), and the most common failure reasons and failed steps. `Clinqy stats --last` shows the latest run turn by turn. A **Clicks** section shows how often the first click worked, which fallbacks rescued the rest, and the sites and apps where clicks struggle most. What it learns about each site is kept in `~/Library/Application Support/Clinqy/click-hints.json`.

## MCP server (Claude Code, Antigravity CLI, Codex, Cursor, OpenCode…)

`Clinqy mcp` runs Clinqy as a stdio [MCP](https://modelcontextprotocol.io) server with no extra dependencies. Register it in Claude Code with:

```bash
claude mcp add clinqy -- /Applications/Clinqy.app/Contents/MacOS/Clinqy mcp
```

Or in Antigravity CLI (`agy`) with:

```bash
agy mcp add clinqy -- /Applications/Clinqy.app/Contents/MacOS/Clinqy mcp
```

OpenCode can connect Clinqy for every project with:

```bash
opencode mcp add clinqy --global -- /Applications/Clinqy.app/Contents/MacOS/Clinqy mcp
```

Or run `clinqy connect opencode`. OpenCode is a coding-agent client here; the AI provider Clinqy itself uses is chosen separately with `clinqy model`.

| Tool | Read-only | What it does |
|---|---|---|
| `clinqy_run` | no | Carries out a plain-English task (`task`, optional `dry`, `timeout` in s, default 300) and returns the steps and the final answer. It isn't saved to History or memory. |
| `clinqy_look` | yes | What's in front: the browser tab through the extension (`mode`: `page`, `read` or `url`), or the app's window and controls through Accessibility |
| `clinqy_stats` | yes | The `stats` report (`days`, `last`) |

The server hands tasks to the running app with `clinqy://` links, the same way the `clinqy` command does, and starts the app if it isn't running. It handles one task at a time. If the client cancels a call, the task is stopped in the app.

## Choosing the model

By default Clinqy runs on the Claude Code CLI with your Claude login. To switch to Antigravity CLI (`agy`) with your Google login, pass `--agy` on the command line or set `PROVIDER=agy-cli` (or `USE_AGY=1`) in `~/.config/clinqy/env`. [`env.example`](env.example) has every option ready to uncomment:

| Option | Lines in `~/.config/clinqy/env` |
|---|---|
| Claude Code CLI (default) | nothing, or `PROVIDER=claude-cli` |
| Antigravity CLI (`agy`) | `PROVIDER=agy-cli` or `USE_AGY=1` (or `--agy` flag) |
| Codex CLI | `PROVIDER=codex-cli` |
| Anthropic API | `PROVIDER=anthropic` and `ANTHROPIC_API_KEY=sk-ant-…` |
| OpenAI API | `PROVIDER=openai` and `OPENAI_API_KEY=sk-…` |
| Gemini API | `PROVIDER=gemini` and `GEMINI_API_KEY=…` |
| OpenRouter | `PROVIDER=openrouter` and `OPENROUTER_API_KEY=sk-or-…` |
| Ollama | `PROVIDER=ollama` and `LOCAL_MODEL=qwen3-vl` |
| Any OpenAI-compatible server | `PROVIDER=openai-compatible`, `OPENAI_BASE_URL=…`, `OPENAI_COMPATIBLE_API_KEY=…` and `LOCAL_MODEL=…` |

On macOS, Codex also has an opt-in persistent transport:

```bash
PROVIDER=codex-cli
CODEX_TRANSPORT=app-server
```

This uses the installed Codex CLI's existing sign-in and one live, ephemeral conversation per Clinqy session. Each turn sends only its new input and screenshot. Clinqy's outer harness executes actions; the embedded Codex process has no execution environments, inherited MCP servers are explicitly disabled, and app/plugin, shell, browser and computer tools are disabled. The adapter checks effective restrictions before inference and refuses incompatible configurations. It was checked against Codex CLI 0.165.0. The [official app-server protocol](https://learn.chatgpt.com/docs/app-server) changes over time, so this transport remains opt-in. Leave `CODEX_TRANSPORT` unset or choose `exec` for the existing per-turn compatibility transport.

An interrupted, timed-out or disconnected app-server turn is **never replayed or automatically retried through exec**. Start a new task after checking its outcome. `zsh tests/codex-session.sh` exercises a local fake process, including blocked pipes and cancellation, without calling a model. Set `CLINQY_CODEX_PREFLIGHT=/absolute/path/to/codex` when running that test to additionally check the installed CLI's configuration and thread restrictions; this preflight creates no inference turn and changes no sign-in settings.

For example, Antigravity CLI:

```bash
PROVIDER=agy-cli
```

Put each `KEY=value` on its own line, with no comment after the value. `chmod 600 ~/.config/clinqy/env` keeps your keys private.

If `PROVIDER` isn't set, Clinqy uses the `claude` CLI when it's installed (or `agy` when `--agy` or `USE_AGY=1` is set). Without it, Clinqy uses the first API key it finds, then `agy` or Codex CLI.

`CLAUDE_MODEL` / `AGY_MODEL` (the agent) and `FAST_MODEL` (the helper for routine steps) work with every provider. Leave them as `sonnet` / `haiku` / `opus` to get each provider's matching tier, or set any model id the provider accepts. On macOS, optional `CODEX_MODEL` selects an explicit Codex CLI model ID; leave it unset to use Codex's configured default:

| Provider | `haiku` (fast) | `sonnet` (agent, default) | `opus` |
|---|---|---|---|
| agy-cli | gemini-3.8-flash (low effort) | gemini-3.8-flash | gemini-3.1-pro |
| anthropic | claude-haiku-5-5 | claude-sonnet-5-5 | claude-opus-5-5 |
| openai | gpt-5.6-luna | gpt-5.6-terra | gpt-5.6-sol |
| gemini | gemini-3.5-flash-lite | gemini-3.6-flash | gemini-3.6-flash |
| openrouter | anthropic/claude-haiku-5.5 | anthropic/claude-sonnet-5.5 | anthropic/claude-opus-5.5 |
| codex-cli | the CLI's default | the CLI's default | the CLI's default |
| ollama, openai-compatible | `LOCAL_MODEL` | `LOCAL_MODEL` | `LOCAL_MODEL` |

Notes:
- **Use a vision model.** Clinqy sometimes sends a screenshot.
- **Speed.** The Claude CLI, the Antigravity CLI (`agy`) and the HTTP APIs keep one conversation per task, so each turn costs only model time. Anthropic replies are prompt-cached, and only the newest screenshot is sent again. Codex CLI has no long-lived chat mode, so it starts once per turn and is noticeably slower.
- **Effort.** `CLAUDE_EFFORT` and `AGY_EFFORT` also set the reasoning effort for models.
- **Rate limits.** The system prompt is about 10k tokens. A free-tier OpenAI account (10k tokens/min) can't fit it on the larger models.
- **Which one is in use.** Menu bar → **Check Permissions…** shows the current provider.

## Configuration

Optional `KEY=value` lines in `~/.config/clinqy/env` (start from [`env.example`](env.example)):

| Key | Default | |
|---|---|---|
| `PROVIDER` | `claude-cli` | Which model service to use (use `agy-cli` or `--agy` / `USE_AGY=1` for Antigravity, see [Choosing the model](#choosing-the-model)) |
| `ANTHROPIC_API_KEY` · `OPENAI_API_KEY` · `GEMINI_API_KEY` · `OPENROUTER_API_KEY` · `OPENAI_COMPATIBLE_API_KEY` | | API keys for the HTTP providers |
| `OPENAI_BASE_URL` | per provider | Endpoint for `openai`, `ollama` or `openai-compatible` |
| `LOCAL_MODEL` | `qwen3-vl` | Model for `ollama` / `openai-compatible` |
| `CLAUDE_PATH` · `AGY_PATH` · `CODEX_PATH` | auto-detected | Path to each CLI |
| `OPENCODE_PATH` | auto-detected | Path to the OpenCode CLI, for `clinqy connect opencode` |
| `CLAUDE_MODEL` / `AGY_MODEL` | `sonnet` | Model for the agent (any provider) |
| `CODEX_MODEL` (macOS) | Codex default | Optional explicit model ID for Codex CLI |
| `CLAUDE_EFFORT` / `AGY_EFFORT` | `low` | `low` is noticeably faster per step |
| `VOICE_LANGUAGE` | `auto` | `auto` (the Mac's language), `en`, `hinglish`, `hi`, or a locale like `en-GB` (the menu setting wins) |
| `VOICE_MODEL` | `speech` | Mac: which of Apple's models hears languages both cover, `speech` (SpeechTranscriber) or `dictation` (DictationTranscriber, the system Dictation's). Hindi always uses `dictation` |
| `WHISPER_MODEL` | `small-q5_1` | Windows only: the whisper.cpp model |
| `FAST_MODEL` | `haiku` | Faster model for routine steps; `off` to use only the main model |
| `DELEGATION` | on | `off`: disable independent task workers |
| `DELEGATE_MODEL` | Mac: `FAST_MODEL` or lead; Windows: sonnet tier | Model for independent workers; follows the lead's provider |
| `DELEGATE_CONCURRENCY` | 3 | Simultaneous independent workers, clamped to 1–6; at most 24 jobs per task |
| `DELEGATE_TIMEOUT` | 90 | Seconds per running worker, clamped to 10–300; queued jobs wait for a slot/dependencies |
| `DELEGATE_EFFORT` | low | Mac worker reasoning effort; the lead checks and combines results |
| `HUMAN_MOTION` | off | Mac: await decorative cursor motion and human-paced launcher/address typing |
| `WORKFLOW_FIRST` | on | `off`: always ask the model, even when a saved workflow matches |
| `UPDATE_CHECK` | on | Mac: `off` stops the daily check for a new version on GitHub |
| `FOLLOW_UP` | on | `off`: don't keep the mic open after a spoken task |
| `FAST_AUTO` | on | `off`: the fast model only takes over when the main model plans routine steps |
| `REPLAY_RECORD` | off | `on`: record each run as an offline replay fixture |

### Your data (all local)

| File | What |
|---|---|
| `~/.config/clinqy/memory.md` | Facts Clinqy remembers about you (edit freely, or menu → **Edit Memory…**) |
| `~/Library/Application Support/Clinqy/models/bge-small-en-v1.5/` | The on-device retrieval model memory search uses (~130 MB, downloaded once from Hugging Face; nothing about you is sent). `CLINQY_EMBEDDINGS=system` in `~/.config/clinqy/env` keeps the built-in system vectors instead |
| `~/.config/clinqy/memory.format` | The memory format version. A newer build upgrades older (or hand-edited) memory once on first launch, app or `clinqy` command: list styles and headings cleaned up, exact duplicates merged, the old file kept as `memory.backup-<date>.md` |
| `~/.config/clinqy/memory.history.jsonl` | Every memory update and removal (old wording, new wording, why), so recall can say what a fact used to be |
| `~/Library/Application Support/Clinqy/history.json` | Recent run history (200 entries in the UI) |
| `~/Library/Application Support/Clinqy/task-memory.sqlite` | Persistent task archive and full-text index on Mac; includes linked follow-ups, steps, outcomes and full retained History records. SQLite's `-wal` and `-shm` companion files are managed automatically |
| `~/Library/Application Support/Clinqy/replays.json.sqlite` | Durable learned procedures; the 150-route in-memory window is only a cache |
| `~/Library/Application Support/Clinqy/tasks.sqlite` | Durable per-task recovery checkpoints; imports legacy `tasks.json` once |
| `~/Library/Application Support/Clinqy/skills.json` | Learned skills |
| `~/Library/Application Support/Clinqy/workflows.json` | Saved workflows (and schedules) |
| `~/Library/Application Support/Clinqy/applications.json` | Job applications Clinqy filled or sent |
| `~/Library/Application Support/Clinqy/file-moves/` | Renames/moves it made, for `files undo` |
| `~/Library/Logs/Clinqy/agent.log` | Step-by-step log (secrets masked) |

## Tests

```bash
swift build --build-system native
zsh tests/background-tasks.sh          # task checkpoints and background routing
zsh tests/scheduler.sh                 # durable handoff, restart dedupe and missed-run policy
zsh tests/observations.sh              # immutable capture coordinates and geometry guards
zsh tests/codex-session.sh             # persistent protocol/isolation tests, no model calls
.build/debug/Clinqy --selftest     # safety rules, reply parsing, stats parsing, replay fixtures, scripting dictionaries
.build/debug/Clinqy replay tests/replay   # recorded runs re-checked offline
zsh tests/task-memory.sh              # archive, follow-ups, redaction, retention
zsh tests/route-memory.sh             # fast reuse, durable procedures, correction invalidation
zsh tests/delegation.sh               # bounded workers, dependencies, dedup, cancellation
zsh tests/delegation-worker.sh        # source loading and independent session lifecycle
zsh tests/efficiency.sh               # 10k checkpoints, network SSE, source sharing, process cancellation
zsh tests/extraction.sh               # bounded extraction and lossless CSV append
zsh tests/benchmarks.sh               # synthetic 100–10k tasks and 2k/20k archive benchmark
zsh tests/background-tasks.sh
zsh tests/telegram.sh
zsh tests/chrome-worker.sh            # isolated real Chrome profiles, local dummy pages
cargo test --manifest-path windows/Cargo.toml -p clinqy-core --lib
cargo clippy --manifest-path windows/Cargo.toml -p clinqy-core --all-targets -- -D warnings
(cd website && npm ci && npm run build && npm audit)
tests/run.sh [filter]                 # live app/model end-to-end tests; requires installed Clinqy
```

Website tooling requires Node.js 22.12 or newer.

On the development Mac (optimized synthetic fixtures), 10,000-task checkpoint pairs improved from a 79.3 ms median to 0.17 ms, and a 20,000-task broad memory query from 7,255 ms to 54 ms. Reopening the migrated 10,000-task store took 3.4 ms; the one-time JSON migration took 135 ms. Six simulated 100 ms worker jobs took 625 ms serially and 208 ms with three workers. These measure local overhead and scheduler concurrency, not live-model or website speed. Reproduce with `tests/benchmarks.sh` and `tests/delegation.sh`.

**Replay fixtures** (`tests/replay/*.json`) are recorded runs: the page snapshots the extension sent, plus the model's reply for each turn. Replaying them needs no browser, model or screen. Each turn is checked against pure code:
- how the reply is parsed into actions
- which clicks need your OK
- which elements kept or changed their w-id since the previous snapshot (drift)
- what was added, removed or changed
- which field has focus

`expect` holds the known-good answers. `Clinqy replay <file> --bless` writes the current answers into it. To record live runs, set `REPLAY_RECORD=on` in `~/.config/clinqy/env`. Fixtures go to `~/Library/Logs/Clinqy/replays/`. They hold whatever the page showed, so strip personal data before committing one.

`Clinqy watch <app> <text> [--gone] [--timeout s]` waits until text appears in an app, or with `--gone` until it disappears. It listens for Accessibility notifications and falls back to polling. It's handy for checking what `Watch.until` sees.

`tests/run.sh` needs the app running and the extension in Chrome. It opens its own Chrome window and refuses to act unless its test page is in front. It covers:
- checkboxes that only accept real clicks, radio buttons, text fields and dropdowns
- a Pay button, both declined and confirmed
- reading a PDF
- Watch & learn followed by running the learned skill
- clicks that need more than a centre click (`clicks.html`): a dropdown that loads its options as it scrolls, an upload button that makes its file field on the spot, a button half-covered by a badge, and a button the page keeps re-rendering

Test runs aren't saved to History or memory.

Other debug commands: `--run <bundle-id|-> "<task>"` (run from the terminal with a timed log), `--transcribe <audio>`, `--snapshots`, `--reload-extension`, `--click-label/--type/--key` (act like the user).

## How it's built

```
Sources/Clinqy/
  Agent.swift        the loop: observe → LLM → act → report; actions, asking, history, memory
  AgentPrompt.swift  the system prompt (action vocabulary and rules)
  Brain.swift        persistent `claude` (or `agy` with `--agy`) stream-json session, pre-warmed
  Providers.swift    other model services: Anthropic/OpenAI/Gemini/OpenRouter/Ollama APIs, Claude, Codex & Antigravity (agy) CLI
  AXEngine.swift     Accessibility: element trees, focus, typing, key combos
  Hand.swift         human-paced actions: Dock/Spotlight, address bar, clicks, typing
  Buddy.swift        the companion cursor (CoreAnimation overlay per screen)
  UI.swift           command bar, status island, result card, history, skills
  BrowserBridge.swift + extension/   page context and actions via the browser extension
  Reader.swift       documents (PDFKit/AppKit) and OCR (Vision)
  Scripting.swift    AppleScript dictionaries for scriptable apps
  Safety.swift       risky-click confirmation, call detection
  Voice.swift, SpeechModel.swift, Transcription.swift   push-to-talk with the Mac's own speech model (SpeechAnalyzer)
  Recorder.swift, Skills.swift       watch & learn
  History.swift      run history and result cards
  Workflow.swift     deterministic workflows (steps + targets), store; replay/heal/QA live in Agent.swift
  Router.swift       before the model: saved-workflow matching, follow-up dismissals
  FastLane.swift     routine steps on a faster model, handed back to the main one on anything risky
  Events.swift       calendar events and reminders (EventKit)
  Files.swift        Spotlight file search, rename/move/organize with undo, trash
  Tables.swift       extract tables and write rows (CSV, Numbers/Excel, clipboard)
  Clipboard.swift    what the user copied recently ("this" when nothing is selected)
  Pdf.swift, Media.swift             PDF and video/audio jobs in the background
  NameHints.swift, MemoryTidy.swift  name-aware voice correction; memory clean-up
  MemoryGraph.swift  links facts that share a person, place, app or detail; retrieval spreads along the links
  TextEncoder.swift  bge-small retrieval model run with Accelerate (memory and saved-run similarity)
  Applications.swift                 job-application tracker
  MCPServer.swift    `Clinqy mcp`: stdio MCP server relaying to the running app
  Watch.swift        wait for text to appear/vanish via AXObserver notifications (polling fallback)
  Stats.swift        `Clinqy stats`: runs.jsonl + per-turn timings and click outcomes from agent.log
  Clicks.swift       click log lines and per-site memory of which way of clicking works
  Replay.swift       offline replay of recorded page snapshots + replies (tests/replay)
bin/clinqy        the command-line entry point (qa · run · workflow · workflows)
tests/qa/            example plain-English QA tests (compiled scripts in tests/qa/.clinqy/)
```

## Privacy

Everything except the model calls stays on your Mac. That covers screen reading, voice (the Mac's own speech model, on-device), memory, history, skills and logs. Requests and screen summaries go only to the model provider you chose: your Claude, Antigravity (`agy`), or Codex CLI login, the API you gave a key for, or a local model, in which case nothing leaves your Mac.

### Direct controls for coding agents

Connect with `clinqy connect claude --skill` or `clinqy connect codex --skill`, then restart the agent.
The [Clinqy skill](skills/clinqy/SKILL.md) explains `/clinqy`, task delegation, and the direct observe/act/wait/verify/release tools.
Existing personal skills are preserved; `--replace-skill` explicitly updates one.
Run local workflow benchmarks with `python3 tests/benchmarks/run.py` (`--help` for options).
