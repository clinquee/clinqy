import { useEffect, useRef } from 'react'

/** What Clinqy is busy with, decoding out of the noise one line at a time. */
const ACTIONS = [
  'open Safari → flights.example.com',
  'click “IndiGo 6E 2131”',
  'screenshot 370×200 → saved',
  'type “Riya Sharma”',
  'upload resume.pdf',
  'tick [x] I agree to the privacy notice',
  'ask: Pay ₹4,420 on flights.example.com?',
  'set Brightness +40 → export beach-edit.jpg',
  'launch t3.micro “tf-server” in ap-south-1',
  'message Mom: I’ll be late, stuck in traffic',
  'add event: Call with Priya, Thu 3:00 PM',
  'move invoice-sept.pdf → Downloads/PDFs',
  'find “the PDF I got from HR last week”',
  'remember: Riya prefers window seats',
  'pick “United States” from Country',
  'read page → 4 results, cheapest ₹4,420',
  'open WhatsApp from the Dock',
  'scroll Results until “Akasa QP 1104”',
]

const RAMP = '.·:-=+*#'
/**
 * Clinqy's cursor, as the app draws it (Buddy.swift): a plain triangle with its tip at the origin, no stem.
 * Here it's rasterised onto a coarse pixel grid.
 */
const TRI: [number, number][] = [[0, 0], [0, 19], [5.2, 14.2], [13.6, 14.2]]
/** The direction the tip points at rest (from the body toward the tip). */
const REST = Math.atan2(-(19 + 14.2 + 14.2) / 4, -(5.2 + 13.6) / 4)
const PX = 4 // one "pixel"
const SIZE = 2.7 // triangle scale, in screen px per unit

function inside(x: number, y: number, poly: [number, number][]) {
  let hit = false
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    const [xi, yi] = poly[i]
    const [xj, yj] = poly[j]
    if (yi > y !== yj > y && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) hit = !hit
  }
  return hit
}

/** Fills the triangle cell by cell: a light rim, a deeper blue inside, and a one-cell drop shadow. */
function drawPixelCursor(ctx: CanvasRenderingContext2D, x: number, y: number, turn: number, press: number) {
  const k = SIZE * (1 - press * 0.14)
  const c = Math.cos(turn)
  const s = Math.sin(turn)
  const poly = TRI.map(([px, py]) => [px * k * c - py * k * s, px * k * s + py * k * c] as [number, number])
  const xs = poly.map((p) => p[0])
  const ys = poly.map((p) => p[1])
  const x0 = Math.floor(Math.min(...xs) / PX) - 1
  const x1 = Math.ceil(Math.max(...xs) / PX) + 1
  const y0 = Math.floor(Math.min(...ys) / PX) - 1
  const y1 = Math.ceil(Math.max(...ys) / PX) + 1
  const on = (i: number, j: number) => inside((i + 0.5) * PX, (j + 0.5) * PX, poly)
  // Snap the tip to the grid so the cursor crawls in whole pixels, like an old screen.
  const ox = Math.round(x / PX) * PX
  const oy = Math.round(y / PX) * PX
  const cells: [number, number, boolean][] = []
  for (let j = y0; j <= y1; j++)
    for (let i = x0; i <= x1; i++) {
      if (!on(i, j)) continue
      const rim = !on(i - 1, j) || !on(i + 1, j) || !on(i, j - 1) || !on(i, j + 1)
      cells.push([i, j, rim])
    }
  ctx.fillStyle = 'rgba(0, 0, 0, 0.45)'
  for (const [i, j] of cells) ctx.fillRect(ox + (i + 1) * PX, oy + (j + 1) * PX, PX, PX)
  for (const [i, j, rim] of cells) {
    ctx.fillStyle = rim ? '#cfe0ff' : '#3b82f6'
    ctx.fillRect(ox + i * PX, oy + j * PX, PX - 0.5, PX - 0.5)
  }
}

type Snip = { text: string; col: number; row: number; born: number; clicked: number; drift: number }

const rnd = (n: number) => Math.floor(Math.random() * n)

/**
 * A full-screen ASCII field: drifting noise, Clinqy's actions decoding in and
 * out, and an ASCII cursor that flies over to click each one.
 */
export function AsciiField({ running }: { running: boolean }) {
  const ref = useRef<HTMLCanvasElement>(null)

  useEffect(() => {
    const canvas = ref.current
    const ctx = canvas?.getContext('2d')
    if (!canvas || !ctx) return
    const calm = matchMedia('(prefers-reduced-motion: reduce)').matches

    const FONT = 13
    const LINE = 17
    let cw = 8
    let cols = 0
    let rows = 0
    let dpr = 1
    let colA = new Float32Array(0)
    const buckets: number[][] = Array.from({ length: RAMP.length }, () => [])
    const resize = () => {
      dpr = Math.min(2, devicePixelRatio || 1)
      canvas.width = innerWidth * dpr
      canvas.height = innerHeight * dpr
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
      ctx.font = `${FONT}px "Geist Mono", ui-monospace, monospace`
      ctx.textBaseline = 'top'
      cw = ctx.measureText('M').width
      cols = Math.ceil(innerWidth / cw)
      rows = Math.ceil(innerHeight / LINE)
      colA = new Float32Array(cols)
    }
    resize()
    addEventListener('resize', resize)

    const mouse = { x: -999, y: -999 }
    const onMove = (e: PointerEvent) => {
      mouse.x = e.clientX
      mouse.y = e.clientY
    }
    addEventListener('pointermove', onMove, { passive: true })
    // Past the hero, veil the field more so long-form text stays easy to read.
    const onScroll = () =>
      document.documentElement.style.setProperty('--veil', String(Math.min(1, scrollY / (innerHeight * 0.7))))
    onScroll()
    addEventListener('scroll', onScroll, { passive: true })

    const snips: Snip[] = []
    let lastSpawn = -9999
    let next = 0
    const cur = { x: innerWidth * 0.7, y: innerHeight * 0.3, fx: 0, fy: 0, tx: 0, ty: 0, start: 0, target: null as Snip | null }
    const trail: { x: number; y: number }[] = []
    const heading = { turn: 0, px: cur.x, py: cur.y }
    let ripple: { x: number; y: number; at: number } | null = null

    const DECODE = 800
    const HOLD = 3400
    const OUT = 600
    const LIFE = DECODE + HOLD + OUT

    function spawn(now: number) {
      const text = ACTIONS[next++ % ACTIONS.length]
      const full = '> ' + text
      // Keep to the right of the reading column on wide screens.
      const minCol = innerWidth > 900 ? Math.floor(cols * 0.42) : 1
      const maxCol = Math.max(minCol + 1, cols - full.length - 3)
      let row = 0
      for (let tries = 0; tries < 12; tries++) {
        row = 4 + rnd(Math.max(1, rows - 8))
        if (!snips.some((s) => Math.abs(s.row - row) < 2)) break
      }
      snips.push({ text: full, col: minCol + rnd(maxCol - minCol), row, born: now, clicked: 0, drift: Math.random() < 0.5 ? -1 : 1 })
    }

    function pickTarget(now: number) {
      const ready = snips.filter((s) => !s.clicked && now - s.born > DECODE && now - s.born < DECODE + HOLD - 1200)
      if (!ready.length) return
      const s = ready[rnd(ready.length)]
      cur.target = s
      cur.fx = cur.x
      cur.fy = cur.y
      cur.start = now
    }

    let raf = 0
    let last = 0
    const t0 = performance.now()

    function frame(now: number) {
      raf = running && !calm && !document.hidden ? requestAnimationFrame(frame) : 0
      if (now - last < 50 || document.hidden) return
      last = now
      const t = (now - t0) / 1000
      ctx!.clearRect(0, 0, innerWidth, innerHeight)

      // 1. Drifting noise. Mostly empty. The left of wide screens sits under
      // the text veil, so it isn't drawn at all. Glyphs are grouped by
      // brightness so the colour changes 8 times a frame, not per glyph.
      const c0 = innerWidth > 900 ? Math.floor(cols * 0.3) : 0
      for (let c = c0; c < cols; c++) colA[c] = Math.sin(c * 0.07 + t * 0.5)
      for (const bucket of buckets) bucket.length = 0
      for (let r = 0; r < rows; r++) {
        const rowA = Math.sin(r * 0.17 - t * 0.35)
        const dy = (r - rows * 0.4) * 2
        for (let c = c0; c < cols; c++) {
          const dx = c - cols * 0.7
          const v =
            (colA[c] + rowA + Math.sin((c + r * 2) * 0.045 + t * 0.25) + Math.sin(Math.sqrt(dx * dx + dy * dy) * 0.09 - t * 0.8) + 4) / 8
          if (v < 0.62) continue
          buckets[Math.min(RAMP.length - 1, Math.floor((v - 0.62) * 22))].push(c, r)
        }
      }
      buckets.forEach((cells, k) => {
        if (!cells.length) return
        ctx!.fillStyle = `rgba(214, 222, 240, ${0.05 + (k / 22) * 0.5})`
        for (let i = 0; i < cells.length; i += 2) ctx!.fillText(RAMP[k], cells[i] * cw, cells[i + 1] * LINE)
      })

      // 2. Actions: decode in, hold, scramble out.
      // Narrow screens have no free column beside the text, so the action lines and cursor stay off.
      const inHero = scrollY < innerHeight * 0.5 && innerWidth > 900
      if (inHero && now - lastSpawn > 1100 && snips.length < 7) {
        spawn(now)
        lastSpawn = now
      }
      for (let i = snips.length - 1; i >= 0; i--) {
        const s = snips[i]
        const age = now - s.born
        if (age > LIFE) {
          snips.splice(i, 1)
          if (cur.target === s) cur.target = null
          continue
        }
        const shown = age < DECODE ? age / DECODE : age > DECODE + HOLD ? 1 - (age - DECODE - HOLD) / OUT : 1
        const flash = s.clicked ? Math.max(0, 1 - (now - s.clicked) / 700) : 0
        const y = s.row * LINE - (age / LIFE) * 10 * s.drift
        const text = s.clicked && now > s.clicked ? s.text + '  ✓' : s.text
        for (let j = 0; j < text.length; j++) {
          const ch = text[j]
          if (!ch || ch === ' ') continue
          const isPrompt = j === 0
          const done = j >= s.text.length
          ctx!.fillStyle = isPrompt || done ? `rgba(141, 255, 176, ${0.75 * shown})` : `rgba(214, 222, 240, ${(0.62 + flash * 0.38) * shown})`
          ctx!.fillText(ch, (s.col + j) * cw, y)
        }
      }

      // 3. The cursor: arc over to a decoded action, click it, pick the next.
      if (!cur.target) pickTarget(now)
      const tg = cur.target
      if (tg) {
        const age = now - tg.born
        const tx = (tg.col + 2) * cw
        const ty = tg.row * LINE - (age / LIFE) * 10 * tg.drift + LINE * 0.6
        const p = Math.min(1, (now - cur.start) / 900)
        const e = p < 0.5 ? 4 * p * p * p : 1 - Math.pow(-2 * p + 2, 3) / 2
        const dx = tx - cur.fx
        const dy = ty - cur.fy
        const len = Math.hypot(dx, dy) || 1
        const arc = Math.sin(e * Math.PI) * Math.min(80, len * 0.2)
        cur.x = cur.fx + dx * e + (-dy / len) * arc
        cur.y = cur.fy + dy * e + (dx / len) * arc
        if (p >= 1 && !tg.clicked) {
          tg.clicked = now + 120
          ripple = { x: cur.x, y: cur.y, at: now }
        }
        if (tg.clicked && now - tg.clicked > 500) cur.target = null
      } else {
        // Idle: float gently, like the app does.
        cur.y += Math.sin(t * 1.6) * 0.4
      }
      // Point the tip where it's going, easing back to rest when it stops, like the app's companion.
      const vx = cur.x - heading.px
      const vy = cur.y - heading.py
      heading.px = cur.x
      heading.py = cur.y
      const speed = Math.hypot(vx, vy)
      // Only a lean (±17°): any more and it reads as a spinning arrowhead, not a cursor.
      const off = speed > 1.5 ? Math.atan2(Math.sin(Math.atan2(vy, vx) - REST), Math.cos(Math.atan2(vy, vx) - REST)) : 0
      const want = Math.max(-0.3, Math.min(0.3, off * 0.4))
      heading.turn += (want - heading.turn) * 0.18

      // A short trail of fading pixels while it flies.
      trail.push({ x: cur.x, y: cur.y })
      if (trail.length > 7) trail.shift()
      if (speed > 1.5)
        trail.forEach((q, i) => {
          ctx!.fillStyle = `rgba(59, 130, 246, ${(i / trail.length) * 0.35})`
          ctx!.fillRect(Math.round(q.x / PX) * PX + PX, Math.round(q.y / PX) * PX + PX * 2, PX, PX)
        })

      if (ripple) {
        const rp = (now - ripple.at) / 600
        if (rp >= 1) ripple = null
        else {
          // A ring of square pixels opening out from the tip.
          const rad = 6 + rp * 40
          const count = 10 + Math.floor(rp * 18)
          ctx!.fillStyle = `rgba(120, 170, 255, ${1 - rp})`
          for (let k = 0; k < count; k++) {
            const a = (k / count) * Math.PI * 2
            ctx!.fillRect(Math.round((ripple.x + Math.cos(a) * rad) / PX) * PX, Math.round((ripple.y + Math.sin(a) * rad) / PX) * PX, PX, PX)
          }
        }
      }

      // Below the hero the field is just texture: no cursor over the content.
      if (!inHero && !cur.target && !ripple) return
      const press = ripple ? Math.max(0, 1 - (now - ripple.at) / 160) : 0
      drawPixelCursor(ctx!, cur.x, cur.y, heading.turn, press)
    }

    const onVisibility = () => {
      if (document.hidden) { cancelAnimationFrame(raf); raf = 0 }
      else if (running && !calm && !raf) raf = requestAnimationFrame(frame)
    }
    document.addEventListener('visibilitychange', onVisibility)
    if (calm) {
      // One still frame, no motion.
      for (let i = 0; i < 5; i++) spawn(-DECODE - 100)
      frame(performance.now() + 100)
      cancelAnimationFrame(raf)
    } else if (running) {
      raf = requestAnimationFrame(frame)
    }

    return () => {
      cancelAnimationFrame(raf)
      document.removeEventListener('visibilitychange', onVisibility)
      removeEventListener('resize', resize)
      removeEventListener('pointermove', onMove)
      removeEventListener('scroll', onScroll)
    }
  }, [running])

  return (
    <div className="field" aria-hidden="true">
      <canvas ref={ref} />
      <div className="field-scrim" />
    </div>
  )
}
