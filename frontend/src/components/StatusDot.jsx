// Shared status pill used across panels.
const COLORS = {
  ok: '#1e8e3e',
  connected: '#1e8e3e',
  pass: '#1e8e3e',
  PASS: '#1e8e3e',
  warn: '#f9ab00',
  WARN: '#f9ab00',
  'not-configured': '#9aa0a6',
  loading: '#9aa0a6',
  error: '#d93025',
  down: '#d93025',
  block: '#d93025',
  BLOCK: '#d93025',
}

export function StatusDot({ status, label }) {
  const color = COLORS[status] ?? '#9aa0a6'
  return (
    <span className="status-pill">
      <span className="dot" style={{ backgroundColor: color }} />
      {label ?? status}
    </span>
  )
}
