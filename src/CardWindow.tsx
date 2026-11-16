import { useState, type ReactNode } from 'react'
const ROW_HEIGHT = 205
const OVERSCAN = 8
export function CardWindow({ children }: { children: ReactNode[] }) {
  const [scrollTop, setScrollTop] = useState(0)
  if (children.length <= 100) return <>{children}</>
  const start = Math.max(0, Math.floor(scrollTop / ROW_HEIGHT) - OVERSCAN)
  const end = Math.min(children.length, start + 32)
  return (
    <div
      className="virtual-card-list"
      tabIndex={0}
      aria-label="Scrollable task cards"
      onScroll={(event) => setScrollTop(event.currentTarget.scrollTop)}
    >
      <div style={{ height: start * ROW_HEIGHT }} aria-hidden="true" />
      {children.slice(start, end)}
      <div style={{ height: (children.length - end) * ROW_HEIGHT }} aria-hidden="true" />
    </div>
  )
}
