import { useEffect, useRef, useState } from 'react'
import { CursorArrow } from '../shared/Cursor'

/**
 * The clingy part: a companion arrow rides beside the visitor's pointer,
 * flies over to frame anything marked data-buddy, and floats off when idle.
 */
export function BuddyCursor({ enabled }: { enabled: boolean }) {
  const arrow = useRef<HTMLDivElement>(null)
  const frame = useRef<HTMLDivElement>(null)
  const [supported, setSupported] = useState(false)

  useEffect(() => {
    const fine = matchMedia('(pointer: fine)').matches
    const calm = matchMedia('(prefers-reduced-motion: reduce)').matches
    setSupported(fine && !calm)
  }, [])

  useEffect(() => {
    if (!enabled || !supported) return
    const pos = { x: innerWidth * 0.7, y: innerHeight * 0.4 }
    const vel = { x: 0, y: 0 }
    const mouse = { x: pos.x, y: pos.y, seen: false }
    let target: Element | null = null
    let lastMove = performance.now()
    let raf = 0

    const wake = () => { if (!raf && !document.hidden) raf = requestAnimationFrame(tick) }
    const onMove = (e: PointerEvent) => {
      mouse.x = e.clientX
      mouse.y = e.clientY
      mouse.seen = true
      lastMove = performance.now()
      target = (e.target as Element | null)?.closest('[data-buddy]') ?? null
      wake()
    }
    const onLeave = () => { target = null; wake() }

    const tick = (now: number) => {
      raf = 0
      if (document.hidden) return
      const el = arrow.current
      const fr = frame.current
      if (!el || !fr) return
      let tx = mouse.x + 18
      let ty = mouse.y + 16
      let framing = false
      if (target) {
        const r = target.getBoundingClientRect()
        tx = r.right - 10
        ty = r.bottom - 8
        framing = true
        fr.style.transform = `translate(${r.left - 6}px, ${r.top - 6}px)`
        fr.style.width = `${r.width + 12}px`
        fr.style.height = `${r.height + 12}px`
      }
      const idle = now - lastMove > 2600
      if (idle && !framing) { tx += 40; ty -= 30 }
      // Critically-damped-ish spring: a touch of lag reads as "following".
      const k = framing ? 0.09 : 0.14
      vel.x = (vel.x + (tx - pos.x) * k) * 0.72
      vel.y = (vel.y + (ty - pos.y) * k) * 0.72
      pos.x += vel.x
      pos.y += vel.y
      const tilt = Math.max(-14, Math.min(14, vel.x * 0.8))
      el.style.transform = `translate(${pos.x}px, ${pos.y}px) rotate(${tilt}deg)`
      el.style.opacity = mouse.seen ? '1' : '0'
      fr.style.opacity = framing ? '1' : '0'
      if (Math.hypot(tx - pos.x, ty - pos.y) > 0.1 || Math.hypot(vel.x, vel.y) > 0.1) wake()
    }

    window.addEventListener('pointermove', onMove, { passive: true })
    document.addEventListener('pointerleave', onLeave)
    window.addEventListener('scroll', wake, { passive: true })
    window.addEventListener('resize', wake)
    document.addEventListener('visibilitychange', wake)
    wake()
    return () => {
      cancelAnimationFrame(raf)
      window.removeEventListener('pointermove', onMove)
      document.removeEventListener('pointerleave', onLeave)
      window.removeEventListener('scroll', wake)
      window.removeEventListener('resize', wake)
      document.removeEventListener('visibilitychange', wake)
    }
  }, [enabled, supported])

  if (!supported) return null
  return (
    <>
      <div ref={frame} className="buddy-frame" aria-hidden="true" />
      <div ref={arrow} className="buddy" aria-hidden="true">
        <CursorArrow size={20} />
      </div>
    </>
  )
}
