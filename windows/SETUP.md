# Set up Clinqy on Windows, step by step

Download it, paste one prompt into the AI you already use, and you're done. This guide is the same setup written out
in full, with what you should see at each step and what to do if something goes wrong.

**You need:** Windows 10 (1903 or later) or Windows 11 on x64, and Chrome, Edge or Brave. No admin rights.

**Time:** about 5 minutes. A fresh agent took 4 minutes 11 seconds to work through the whole prompt.

## 1. Download and install

1. Open the [latest release](https://github.com/Amrit-Nigam/clinqy/releases/latest) and download
   **`Clinqy-windows-x64.zip`**.
2. Unzip it. Extract it fully rather than opening it inside the zip window.
3. Double-click **`Install Clinqy.bat`**.

If SmartScreen says it protected your PC, click **More info → Run anyway**. Clinqy isn't code-signed yet, so Windows
doesn't recognise the publisher.

**You should see:**

```text
Installing Clinqy
  App: C:\Users\<you>\AppData\Local\Programs\Clinqy
  Start menu: Clinqy
  Command: clinqy (open a new terminal to use it)

Done. Press Ctrl+Alt to open Clinqy, or hold Ctrl+H to talk.
```

Clinqy starts and its command bar opens. It's now in the Start menu, and `clinqy` works in any **new** terminal.
Terminals that were already open don't know about it yet.

## 2. Paste the setup prompt

Copy the prompt from the [main README](../README.md#setup-on-windows) or the [website](https://clinqy.vercel.app/#setup)
into the AI you use: Claude Code, Codex, agy, Cursor, Gemini CLI, Windsurf, OpenCode, or a plain chat. There's nothing to fill in.

The top two lines are the only settings, and the defaults suit most people:

```text
Model: auto
Connect to: all
```

- **Model** is the AI Clinqy thinks with. `auto` picks the first one you have, in this order: Claude Code, Codex, agy,
  Ollama. To choose one, use `claude`, `codex`, `agy`, `ollama`, `anthropic`, `openai`, `gemini` or `openrouter`.
- **Connect to** is which coding agents get Clinqy's tools. Use `all`, `none`, or comma-separated names from `claude`, `codex`, `agy`, `cursor`, `gemini`, `windsurf` and `opencode`.

Your AI then does the following. If it's a chat with no terminal, it gives you one command at a time to paste instead.

| Step | What happens | Do you need to do anything? |
|---|---|---|
| Install | Installs or updates Clinqy. Clinqy restarts. | No |
| Choose the AI | Finds what this PC has and picks by the order above. | Only if nothing is installed or logged in |
| Browser extension | Clinqy adds it to your browser, using your mouse for a moment. | Don't touch the mouse while it does this |
| Connect agents | Adds Clinqy over MCP to the agents you have. | No |
| Check | Runs `clinqy doctor` and a test task in the background. | No |

**Your AI should finish with a summary like this:**

```text
Clinqy is installed and working. `doctor` shows everything ready, and the test task
("open example.com and tell me the page title") returned "Example Domain".
```

**Restart any coding agent you connected**, or it won't see Clinqy's tools.

## 3. Check it yourself

In a new terminal:

```powershell
clinqy doctor
```

**You should see** these lines. The first shows whichever AI you're using.

```text
- Model — Claude Code CLI: ... · model sonnet
- Browser extension — connected — web pages are read and driven exactly (✓ ready)
- Voice (on-device Whisper) — installed (✓ ready)
```

Voice may say `on first use` instead. That's fine: it downloads the first time you hold Ctrl+H.

Then try a background task:

```powershell
clinqy run --background "open example.com and tell me the page title"
```

**You should see:** `The page title is "Example Domain".` Your mouse, keyboard and windows aren't touched.

## 4. Use it

| | |
|---|---|
| **Tap Ctrl+Alt** | Open the command bar, type a request, press Enter. |
| **Hold Ctrl+H** | Talk. It listens only while you hold the keys. |
| **Gear on the bar** | Open the Clinqy window: AI and model, background tasks, tasks, and every keyboard shortcut. |
| **Background switch on the bar** | Run tasks out of your way while you keep working. |
| **Ctrl+P / Ctrl+S during a task** | Pause or resume / stop. In a background task press twice within 2 seconds, so the first press still reaches your app. The rest of the time they're Print and Save as usual. |
| **Follow up**, or `clinqy add "…"` | Add to a task at any time. A finished task carries on with everything you added. |
| **Drag the capsule or the bar** | Move it anywhere. It's back in its usual place the next time it opens. |

If a background task needs your screen, a card appears at the top right and waits for you. Choose **Run in foreground**,
**Keep in background** or **Stop task**.

**To work like a tab beside yours:** in the Clinqy window, open **Background** and turn on **Work in a tab in my browser**.
Tasks then run in a blue Clinqy tab group in your own browser, with your sign-ins, while you stay in any other tab or
window. If your browser is closed, Clinqy opens it minimized.

**Voice** uses Whisper, on your PC. To use Windows' speech service, choose it under **General → Voice engine**, and turn on
Online speech recognition in Windows Settings → Privacy & security → Speech, which sends your voice to Microsoft.
`clinqy voice check` tells you whether it works on your PC. If it can't run, Clinqy uses Whisper.

**Open at login is off by default.** To have Clinqy start when you sign in, turn it on under **General** in the Clinqy
window.

## If something goes wrong

**Windows Defender quarantined Clinqy.** Open Windows Security → Virus & threat protection → Protection history, open
the Clinqy entry, and choose **Actions → Allow on device**. Then open Clinqy again. Your settings and history are kept.
Please also [open an issue](https://github.com/Amrit-Nigam/clinqy/issues) so we can report the file to Microsoft.

**`clinqy` isn't recognised.** The terminal was open before you installed. Open a new one, or use the full path:

```powershell
& "$env:LOCALAPPDATA\Programs\Clinqy\clinqy.exe" doctor
```

**Browser extension: not connected.** Check Clinqy is running, because the extension has nothing to connect to without
it. Then run `clinqy extension install`. If that doesn't work, open your browser's extensions page, turn on
**Developer mode**, click **Load unpacked** and pick `%LOCALAPPDATA%\Programs\Clinqy\extension`.

**No AI found, or a CLI isn't logged in.** Install Claude Code with `winget install Anthropic.ClaudeCode`, or run
`claude`, `codex login` or `agy` once in a new terminal to log in. Then run `clinqy setup` again.

**An API key.** Run `clinqy settings`, paste the key into the line it belongs on, and save. Don't paste keys into a chat
with an AI.

**agy shows Clinqy as connected, but its tools don't run.** agy needs your permission to use a tool. With `agy -p` it
can't ask, so it denies the tool and produces no output. To run it that way, add an allow-rule for Clinqy under
`permissions.allow` in agy's `settings.json`.

**A background task isn't signed in to a site.** The hidden browser has its own profile, because browsers don't allow
automation on your everyday one. You have two options, both in the Clinqy window under **Background**:

- Turn on **Work in a tab in my browser**. Tasks use your own browser and sign-ins, in a blue Clinqy tab group, while you
  carry on elsewhere. Sound and video play for you, and a tab playing sound stays open when the next task starts. They act in your real accounts, and your browser shows a debugging bar while a task runs.
- Or click **Sign in…**, sign in to the site in the window that opens, then click **Finish sign-in**. You only do this
  once per site. To keep those sign-ins somewhere else, change **Profile folder** on the same page.

**A coding agent can't see Clinqy.** Restart it. To check it's connected, use `claude mcp list`, `agy mcp list` or `opencode mcp list`.

**OpenCode isn't detected.** Add the OpenCode CLI to `PATH`, or set `OPENCODE_PATH` in `clinqy settings`, then run `clinqy connect opencode`.

**Still stuck?** The log is at `%LOCALAPPDATA%\Clinqy\Logs\agent.log`.

**A task says "Couldn't finish".** Clinqy couldn't do it, and says what stopped it. Use **Follow up** to tell it what to try next.

## Update or uninstall

**Update:** run `clinqy update`, or click **Update now** on the card Clinqy shows when a new version is out. It checks
the download's SHA-256, replaces the old version and restarts Clinqy. Your settings, memory, history and Open at login
are kept. It won't start while a task is running. Restart any connected coding agent afterwards.

`clinqy update --check` only looks. `UPDATE_CHECK=off` in the settings file stops the check at launch.

**On 0.3.0 or older?** Those versions don't have `clinqy update`, so update once by hand: download the latest zip and
double-click `Install Clinqy.bat`, or paste the setup prompt again.

**Uninstall:** double-click `Uninstall Clinqy.bat` in `%LOCALAPPDATA%\Programs\Clinqy`. This removes the app, its Start
menu shortcut, PATH entry, login item and `clinqy://` links, and keeps your settings and data. To delete those too, run
`uninstall.ps1 -Purge` from the same folder.

## How this guide was tested

Run on 31 October 2026 on Windows 11 with Clinqy for Windows 0.3.0.

| Step | Result |
|---|---|
| Uninstall the previous copy | The app, shortcut and folder were removed |
| Download the zip from the latest-release link | SHA-256 matched the release notes |
| Install and launch | Worked, version 0.3.0 |
| Microsoft Defender during install and first launch | No detections, and a scan of the installed files found no threats |
| Unedited prompt in a fresh Claude Code agent | Finished in 4 min 11 s, with nothing needed from the user |
| `clinqy doctor` | Model, extension and voice all ready |
| Test task in the background | Returned "Example Domain" |
| MCP in Claude Code and agy | Both listed as connected |

**Not covered by this run:**

- **A brand-new PC.** This PC already had an AI logged in, the extension in the browser, and voice downloaded, so those
  first-time steps didn't run. The prompt's "Needs you" path wasn't used.
- **SmartScreen.** The zip was downloaded with PowerShell rather than a browser, so SmartScreen had no reason to appear.
- **A plain chat with no terminal.** The prompt covers it, but it wasn't run this time.

### Added in 0.3.2

Tested on 31 October 2026 with simulated keyboard and mouse input.

| Check | Result |
|---|---|
| A page fails and the model answers from memory | Challenged, then reported as failed, with nothing saved to memory |
| Follow-up during a task, after it, and later again | All picked up, with the task's context |
| Ctrl+P and Ctrl+S on the screen | Pause, resume and stop all worked, repeatedly |
| Ctrl+S in a background task | One press left the task running, and a second within 2 seconds stopped it |
| Dragging the capsule and the bar | Both moved by exactly the drag, and the capsule was back at the top center for the next task |

### Added in 0.3.1

Run on 31 October 2026 on a build of 0.3.1, before its release.

| Check | Result |
|---|---|
| Tasks in a Clinqy tab, with Claude Code and agy | Reading, searching, two tabs and sending a Gmail message all worked, and the active tab never changed |
| Browser closed when a task starts | Clinqy opened it minimized, and the task ran after the extension connected |
| Hidden browser left behind by a killed app | Replaced automatically, and the task ran |
| `clinqy update` | Refused during a running task, then installed the latest release and restarted Clinqy. It returned at once through a pipe |
| `clinqy update` to a newer version | Tested as a reinstall, because no newer release exists yet |
| agy | Models listed, background and desktop tasks worked, and a real Clinqy tool call succeeded |
| Windows speech with a microphone | Not tested. On this PC Windows blocked it until Online speech recognition is turned on |
| Windows speech accuracy | The older built-in engine made clear mistakes on five sample requests, such as "gym a LAN" for "gmail and". The newer engine couldn't be measured |
| Microsoft Defender | No detections on this build |
