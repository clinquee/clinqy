import { useEffect, useState } from 'react'
import { BuddyCursor } from './BuddyCursor'
import { LiveDesk } from './LiveDesk'
import { ScenePlayer } from './ScenePlayer'
import { AsciiField } from './AsciiField'
import { ARROW, AsciiFinale } from './AsciiFinale'
import { Scramble } from './Scramble'
import { HowArt, SafetyArt, SetupArt } from './IsoArt'
import { AgentSection, QaSection } from './AgentSections'
import { SETUP_PROMPT, SETUP_PROMPT_WINDOWS } from './setupPrompt'
import { Tour, TourOffer } from './Tour'
import { AgentCycle, BrandIcon } from './BrandIcons'

const GITHUB = 'https://github.com/Amrit-Nigam/clinqy'
// Resolves the newest published Mac release independently of Windows' "latest" release.
const MAC_DMG = '/api/mac-download'
// Each platform resolves its own latest published assets, regardless of GitHub's global Latest flag.
const WIN_ZIP = '/api/windows-download'
const WIN_INSTALL = `& ([scriptblock]::Create((irm 'https://clinqy.vercel.app/api/windows-download?asset=installer'))) -Url 'https://clinqy.vercel.app/api/windows-download'`

type Platform = 'mac' | 'windows'
const detected: Platform = /Windows/i.test(navigator.userAgent) ? 'windows' : 'mac'
const DOWNLOAD: Record<Platform, { href: string; label: string }> = {
  mac: { href: MAC_DMG, label: 'Download for Mac' },
  windows: { href: WIN_ZIP, label: 'Download for Windows' },
}
const other = (p: Platform): Platform => (p === 'mac' ? 'windows' : 'mac')

/** Real requests from the README, for the strip under the hero. */
const ASKS = [
  'book me a flight to Mumbai',
  'where’s the brightness setting?',
  'tick Keynote and Design panel',
  'message mom I’ll be late',
  'what’s the phone number on my resume?',
  'in the background, add a reminder to call Raj',
  'schedule a call with Priya Thursday afternoon',
  'sort my Downloads into folders',
  'the PDF I got from HR last week',
]

/** One request, followed through each step of the loop. */
const TRACE = [
  {
    step: 'You ask',
    body: 'Tap ⌃⌥ and type, or hold it and talk. Whatever you’ve highlighted goes along, so “reply to this” just works.',
    log: '⌃⌥  “message mom I’ll be late”',
  },
  {
    step: 'It looks',
    body: 'It reads the screen the way assistive tech does: buttons, fields and lists by name, plus text recognition when an app hides them.',
    log: 'WhatsApp  →  4 chats  →  found “Mom”',
  },
  {
    step: 'It acts, then checks',
    body: 'The blue cursor flies to the target and clicks or types for real. If nothing changed, it tries another way.',
    log: 'click “Mom”  →  type message  →  text appeared ✓',
  },
  {
    step: 'It asks when it matters',
    body: 'Sending to someone counts, so it shows you the message first. Details, choices, Pay and Delete work the same way.',
    log: 'Send “I’ll be late” to Mom?  [ Send ]',
  },
]

/** Each capability, introduced by something you might actually say. */
const CAN = [
  {
    say: 'tick Keynote and Design panel',
    title: 'Clicks that check themselves',
    body: 'After every click it looks for an effect. Nothing changed? It tries a real mouse click, then a click through the page, then focus plus a key, and remembers what works on each site.',
  },
  {
    say: 'what’s the phone number on my resume?',
    title: 'Sees the whole Mac',
    body: 'Native apps through Accessibility, web pages through a browser extension, PDFs and scans through on-device text recognition, scriptable apps through AppleScript.',
  },
  {
    say: 'mummy ko bolo main late hoon',
    title: 'Talk to it, in your words',
    body: 'Hold ⌃⌥ and speak. Your Mac’s own speech model turns it into text as you talk, on the Mac. English, Hindi and Hinglish all work, and replies keep your style.',
  },
  {
    say: 'message mom I’ll be late',
    title: 'Remembers who’s who',
    body: 'It keeps lasting facts after each task: people, preferences, your usual apps. It never saves passwords, card numbers or OTPs.',
  },
  {
    say: 'do the weekly report like I showed you',
    title: 'Learns by watching',
    body: 'Click Watch & learn, do a task once yourself, and it becomes a skill with blanks to fill in next time.',
  },
  {
    say: 'check how localhost:5173 looks in my browser',
    title: 'Works with your coding agent',
    body: 'Add Clinqy as an MCP server to Claude Code, Cursor, Codex, agy or OpenCode, and they can see how your page really renders, logged in, in your own browser.',
  },
]

function Rule() {
  return (
    <div className="rule" aria-hidden="true">
      {'─'.repeat(400)}
    </div>
  )
}

export function Site({ live, onReplay }: { live: boolean; onReplay: () => void }) {
  const [copied, setCopied] = useState(false)
  const [platform, setPlatform] = useState<Platform>(detected)
  const [winCopied, setWinCopied] = useState(false)
  const [tour, setTour] = useState<'offer' | 'on' | 'off' | null>(null)
  const [toast, setToast] = useState('')
  const [versions, setVersions] = useState<Partial<Record<Platform, string>>>({})
  useEffect(() => {
    const controller = new AbortController()
    for (const p of ['mac', 'windows'] as const) {
      fetch(`/api/${p}-download?format=json`, { signal: controller.signal })
        .then(response => response.ok ? response.json() : null)
        .then(release => {
          if (release?.platform === p && /^\d+\.\d+\.\d+$/.test(release.version)) {
            setVersions(previous => ({ ...previous, [p]: release.version }))
          }
        }).catch(() => {})
    }
    return () => controller.abort()
  }, [])

  // The nav hides once you scroll down, and comes back when the pointer nears the top (or you scroll back up).
  const [navHidden, setNavHidden] = useState(false)
  useEffect(() => {
    let lastY = scrollY
    let nearTop = false
    const onScroll = () => {
      const y = scrollY
      if (y < 80) setNavHidden(false)
      else if (y > lastY + 4 && !nearTop) setNavHidden(true)
      else if (y < lastY - 30) setNavHidden(false)
      lastY = y
    }
    const onMove = (e: PointerEvent) => {
      nearTop = e.clientY < 72
      if (nearTop) setNavHidden(false)
      else if (scrollY > 80 && e.clientY > 140) setNavHidden(true)
    }
    addEventListener('scroll', onScroll, { passive: true })
    addEventListener('pointermove', onMove, { passive: true })
    return () => {
      removeEventListener('scroll', onScroll)
      removeEventListener('pointermove', onMove)
    }
  }, [])

  // Offer the tour a moment after the page switches on.
  useEffect(() => {
    if (!live) {
      setTour(null)
      return
    }
    const id = setTimeout(() => setTour((t) => t ?? 'offer'), 700)
    return () => clearTimeout(id)
  }, [live])

  function endTour(how: 'done' | 'stopped' | 'taken') {
    setTour('off')
    if (how !== 'done') {
      setToast(how === 'taken' ? 'Stopped. You’re in control.' : 'Stopped.')
      setTimeout(() => setToast(''), 2400)
    }
  }

  // The setup prompt for a platform (the visitor's own, unless they're looking at the other tab).
  const promptFor = (p: Platform) => (p === 'windows' ? SETUP_PROMPT_WINDOWS : SETUP_PROMPT)

  async function copyPrompt(p: Platform = detected) {
    try {
      await navigator.clipboard.writeText(promptFor(p))
      setCopied(true)
      setTimeout(() => setCopied(false), 2200)
    } catch {
      document.getElementById('setup')?.scrollIntoView({ behavior: 'smooth' })
    }
  }

  async function copyWinInstall() {
    try {
      await navigator.clipboard.writeText(WIN_INSTALL)
      setWinCopied(true)
      setTimeout(() => setWinCopied(false), 2200)
    } catch {
      /* the command is visible to select by hand */
    }
  }

  const copyLabel = copied ? 'Copied. Paste it into your agent' : 'Copy the setup prompt'
  const download = (p: Platform, primary: boolean) => (
    <a className={'btn ' + (primary ? 'btn-primary' : 'btn-outline')} href={DOWNLOAD[p].href} data-buddy>
      <BrandIcon name={p === 'mac' ? 'apple' : 'windows'} />
      {DOWNLOAD[p].label}{versions[p] ? ` · ${versions[p]}` : ''}
    </a>
  )

  return (
    <div className="site">
      <AsciiField running={live} />
      <BuddyCursor enabled={live && tour !== 'on'} />
      {tour === 'offer' && <TourOffer onYes={() => setTour('on')} onNo={() => setTour('off')} />}
      <Tour running={tour === 'on'} onEnd={endTour} />
      {toast && <div className="tour-toast" role="status">{toast}</div>}

      <header className={'nav' + (navHidden && tour !== 'on' ? ' is-hidden' : '')} onFocus={() => setNavHidden(false)}>
        <a className="nav-logo" href="#top" data-buddy>
          <img src="/icon.png" alt="" width={26} height={26} />
          clinqy
        </a>
        <nav aria-label="Sections">
          <a href="#how">How it works</a>
          <a href="#watch">Watch it</a>
          <a href="#agents">For agents</a>
          <a href="#safety">Safety</a>
          <a href="#setup">Set up</a>
          <button type="button" className="linklike nav-tour" onClick={() => setTour('on')} disabled={tour === 'on'}>
            Show me around
          </button>
        </nav>
        <a className="btn btn-quiet" href={GITHUB} target="_blank" rel="noreferrer" data-buddy>
          GitHub
        </a>
      </header>

      <main id="top">
        <section className="hero">
          <div className="hero-copy">
            <pre className="hero-mark" aria-hidden="true">
              {ARROW.join('\n')}
            </pre>
            <div data-tour="hello">
              <Scramble as="h1" text={'Your cursor’s\nnew buddy.'} start={live} />
            </div>
            <p className="hero-sub">It does the clicking. You watch it work.</p>
            <p className="lede">
              Press <kbd data-tour="keys">⌃⌥</kbd> (Ctrl+Alt on Windows) and say what you want. A small blue cursor goes and does it on
              screen. It opens the app, types into the address bar, ticks the boxes and fills the form, then hands your pointer back.
            </p>
            <div className="hero-ctas">
              {download(detected, true)}
              {download(other(detected), false)}
              <button type="button" className="btn btn-outline" onClick={() => copyPrompt()} data-buddy>
                <AgentCycle />
                {copied ? 'Copied. Paste it into your agent' : 'Copy the one-prompt install'}
              </button>
            </div>
            <p className="fineprint">Free and open source. macOS 14+ on Apple silicon, or Windows 10 and 11.</p>
          </div>
          <div data-tour="desk">
            <LiveDesk running={live} />
          </div>
        </section>

        <div className="asks" aria-label="Things you can ask">
          <div className="asks-track">
            {[...ASKS, ...ASKS].map((a, i) => (
              <span key={i} aria-hidden={i >= ASKS.length}>
                “{a}”
              </span>
            ))}
          </div>
        </div>

        <section className="how" id="how" aria-labelledby="how-title">
          <div className="section-head has-art">
            <div>
              <Scramble as="h2" id="how-title" text="One request, start to finish" />
              <p>Every task runs the same loop. Here it is for one message, layer by layer.</p>
            </div>
            <div className="art">
              <HowArt />
            </div>
          </div>
          <ol className="trace">
            {TRACE.map((r) => (
              <li key={r.step}>
                <h3>{r.step}</h3>
                <p>{r.body}</p>
                <code className="trace-log">{r.log}</code>
              </li>
            ))}
          </ol>
        </section>

        <Rule />
        <QaSection />

        <Rule />
        <AgentSection />

        <Rule />
        <section className="watch" id="watch">
          <div className="section-head">
            <Scramble as="h2" text="It uses your computer the way you would" />
            <p>
              No hidden APIs and no headless browser. It opens apps from the Dock, types at a human rhythm and clicks
              for real. Pick a request.
            </p>
          </div>
          <ScenePlayer />
        </section>

        <Rule />
        <section className="can" id="features">
          <Scramble as="h2" text="Say it like you’d say it" />
          <ul className="can-list">
            {CAN.map((c) => (
              <li key={c.title} data-tour={c.say.startsWith('mummy') ? 'voice' : undefined}>
                <q className="can-say">{c.say}</q>
                <div>
                  <h3>{c.title}</h3>
                  <p>{c.body}</p>
                </div>
              </li>
            ))}
          </ul>
        </section>

        <section className="safety" id="safety">
          <div className="safety-copy">
            <Scramble as="h2" text="It asks before anything you can’t take back" />
            <ul>
              <li>Pay, Buy, Book, Send, Submit and Delete wait for your OK, unless you asked for exactly that.</li>
              <li>On a call? It checks with you before acting.</li>
              <li>One click in the menu bar stops any task. A watchdog stops anything stuck for 30 seconds.</li>
              <li>Renames and moves can be undone. Deleting only moves to the Trash.</li>
            </ul>
          </div>
          <div className="art art-safety" data-tour="alert">
            <SafetyArt />
          </div>
        </section>

        <section className="setup" id="setup">
          <div className="section-head has-art">
            <div>
              <Scramble as="h2" text="Get Clinqy" />
              <p>Download the app and follow a few steps, or paste one prompt into your coding agent and it sets everything up.</p>
            </div>
            <div className="art">
              <SetupArt />
            </div>
          </div>

          <div className="platform-tabs" role="tablist" aria-label="Your computer">
            {(['mac', 'windows'] as const).map((p) => (
              <button
                key={p}
                type="button"
                role="tab"
                aria-selected={platform === p}
                className={platform === p ? 'is-on' : undefined}
                onClick={() => setPlatform(p)}
                data-buddy
              >
                {p === 'mac' ? 'Mac' : 'Windows'}
              </button>
            ))}
          </div>

          {platform === 'mac' ? (
            <div className="setup-grid" role="tabpanel" aria-label="Mac">
              <div>
                <ol className="steps">
                  <li>
                    <h3>Download</h3>
                    <p>
                      Open <code>Clinqy.dmg</code> and drag Clinqy into Applications. macOS blocks the first launch (it isn’t notarized
                      yet): System Settings → Privacy &amp; Security → Open Anyway. (You can skip this: the prompt installs Clinqy too.)
                    </p>
                    <div className="step-cta">{download('mac', true)}</div>
                  </li>
                  <li>
                    <h3>Paste one prompt into your coding agent</h3>
                    <p>
                      Claude Code, Codex, agy, Cursor, Gemini CLI, Windsurf or OpenCode. Nothing to fill in: it uses the AI you already have (Claude
                      Code, then Codex, then agy, then an API key), asks for the permissions, adds the browser extension and connects your
                      agent. It only stops when it needs you.
                    </p>
                    <div className="step-cta">
                      <button type="button" className="btn btn-primary" onClick={() => copyPrompt('mac')} data-buddy data-tour="copy">
                        <AgentCycle />
                        {copied ? 'Copied. Paste it into your agent' : 'Copy the setup prompt'}
                      </button>
                    </div>
                  </li>
                  <li>
                    <h3>Press ⌃⌥</h3>
                    <p>Tap to type, hold to talk. Ask it something, like “where’s the brightness setting?”</p>
                  </li>
                </ol>
              </div>
              <div className="setup-alt">
                <h3>The prompt</h3>
                <p>
                  Want a particular AI? Change the first line to <code>claude cli</code>, <code>codex cli</code>, <code>agy cli</code>,{' '}
                  <code>ollama qwen3-vl</code> or <code>anthropic api key</code>. No coding agent? Open Clinqy and follow its setup window
                  instead.
                </p>
                <div className="term">
                  <div className="term-bar">
                    <i />
                    <i />
                    <i />
                    <span>setup prompt</span>
                    <button type="button" className="btn btn-primary btn-small" onClick={() => copyPrompt('mac')} data-buddy>
                      {copied ? 'Copied' : 'Copy'}
                    </button>
                  </div>
                  <pre tabIndex={0}>{SETUP_PROMPT}</pre>
                </div>
              </div>
            </div>
          ) : (
            <div className="setup-grid" role="tabpanel" aria-label="Windows">
              <div>
                <ol className="steps">
                  <li>
                    <h3>Download</h3>
                    <p>
                      Unzip it and double-click <code>Install Clinqy.bat</code>. No admin rights needed. If SmartScreen warns you, click
                      More info → Run anyway. (You can skip this: the prompt installs Clinqy too.)
                    </p>
                    <p>Already on Windows 0.3.1 or newer? Run <code>clinqy update</code>. On 0.3.0 or older, reinstall from the ZIP; your settings, memory and history stay in place.</p>
                    <p>The Windows update keeps music-playing browser tabs open, reports browser tasks correctly, and rechecks pages before acting. Windows currently runs one task at a time.</p>
                    <div className="step-cta">{download('windows', true)}</div>
                  </li>
                  <li>
                    <h3>Paste one prompt into any AI you use</h3>
                    <p>
                      Claude Code, Codex, agy, Cursor, Gemini CLI, Windsurf, OpenCode, or even a chat. Nothing to fill in: it uses the AI you already
                      have (Claude Code, then Codex, then agy, then Ollama), connects your coding agents and adds the browser extension. It
                      only stops when it needs you.
                    </p>
                    <div className="step-cta">
                      <button type="button" className="btn btn-primary" onClick={() => copyPrompt('windows')} data-buddy data-tour="copy">
                        <AgentCycle />
                        {copied ? 'Copied. Paste it into your agent' : 'Copy the setup prompt'}
                      </button>
                    </div>
                  </li>
                  <li>
                    <h3>Tap Ctrl+Alt</h3>
                    <p>Type what you want and press Enter, or hold Ctrl+H and say it.</p>
                  </li>
                </ol>
              </div>
              <div className="setup-alt">
                <h3>The prompt</h3>
                <p>
                  Want a particular AI? Change the first line to <code>claude</code>, <code>codex</code>, <code>agy</code>, <code>ollama</code>{' '}
                  or <code>anthropic</code>. No AI to paste it into? After installing, run <code>clinqy setup</code> in a new terminal.
                </p>
                <div className="term">
                  <div className="term-bar">
                    <i />
                    <i />
                    <i />
                    <span>setup prompt</span>
                    <button type="button" className="btn btn-primary btn-small" onClick={() => copyPrompt('windows')} data-buddy>
                      {copied ? 'Copied' : 'Copy'}
                    </button>
                  </div>
                  <pre tabIndex={0}>{SETUP_PROMPT_WINDOWS}</pre>
                </div>
                <p className="fineprint">
                  Or install from PowerShell:{' '}
                  <button type="button" className="linklike" onClick={copyWinInstall} data-buddy>
                    {winCopied ? 'copied' : 'copy the one-line install'}
                  </button>
                </p>
              </div>
            </div>
          )}
        </section>

        <section className="finale" aria-labelledby="finale-title" data-tour="finale">
          <AsciiFinale />
          <p id="finale-title" className="finale-line">Press {detected === 'mac' ? '⌃⌥' : 'Ctrl+Alt'}. Say it. Watch it happen.</p>
          <div className="hero-ctas" data-tour="finale-cta">
            {download(detected, true)}
            <button type="button" className="btn btn-quiet" onClick={() => copyPrompt()} data-buddy>
              {copyLabel}
            </button>
          </div>
        </section>
      </main>

      <footer className="footer">
        <div className="footer-brand">
          <img src="/icon.png" alt="" width={24} height={24} />
          <span>Clinqy. Your cursor’s clingy partner.</span>
        </div>
        <div className="footer-links">
          <a href={GITHUB} target="_blank" rel="noreferrer" data-buddy>GitHub</a>
          <button type="button" className="linklike" onClick={onReplay} data-buddy>Watch the intro again</button>
        </div>
      </footer>
    </div>
  )
}
