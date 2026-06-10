// Tiny fetch wrapper for the Pode JSON API (same-origin in prod, proxied in dev).
async function request(path, options = {}) {
  const res = await fetch(path, {
    headers: { 'Content-Type': 'application/json' },
    ...options,
  })
  const text = await res.text()
  const data = text ? JSON.parse(text) : null
  if (!res.ok) {
    const msg = (data && (data.error || data.message)) || `HTTP ${res.status}`
    throw new Error(msg)
  }
  return data
}

export const api = {
  health: () => request('/api/health'),
  connections: () => request('/api/connections'),
  saveConnections: (body) => request('/api/connections', { method: 'PUT', body: JSON.stringify(body) }),
  connectionHealth: () => request('/api/connections/health'),

  // Phase 2 — mapping
  mappingList: () => request('/api/mapping'),
  mappingUsers: (tenant) => request(`/api/mapping/users/${tenant}`),
  mappingSync: (tenant) => request(`/api/mapping/sync/${tenant}`, { method: 'POST' }),
  mappingAutoMatch: () => request('/api/mapping/automatch', { method: 'POST' }),
  mappingSave: (rows) => request('/api/mapping', { method: 'PUT', body: JSON.stringify({ rows }) }),
  mappingImportCsv: (csv) => request('/api/mapping/import', { method: 'POST', body: JSON.stringify({ csv }) }),
  mappingExportUrl: () => '/api/mapping/export',

  // Provisioning — create target MailUsers
  provisioningDomains: () => request('/api/provisioning/domains'),
  provisioningPreview: (body) => request('/api/provisioning/preview', { method: 'POST', body: JSON.stringify(body) }),
  provisioningExecute: (body) => request('/api/provisioning/execute', { method: 'POST', body: JSON.stringify(body) }),
  provisioningLatest: () => request('/api/provisioning/latest'),

  // Phase 4 — migration setup
  migrationSetupStatus: () => request('/api/migration-setup/status'),
  migrationSetupCreate: (item) => request('/api/migration-setup/create', { method: 'POST', body: JSON.stringify({ item, confirm: true }) }),

  // Phase 3 — preflight
  preflightRun: () => request('/api/preflight/run', { method: 'POST' }),
  preflightLatest: () => request('/api/preflight/latest'),
  preflightExportHtmlUrl: (runId) => `/api/preflight/export/${runId}.html`,
  preflightExportCsvUrl: (runId) => `/api/preflight/export/${runId}.csv`,
}
