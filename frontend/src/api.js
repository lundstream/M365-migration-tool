// Pode's JSON serializer collapses single-element arrays into a bare object, so a list with
// exactly one item arrives as {…} instead of [{…}] and breaks .map() in the UI. We re-expand
// known list fields (recursively, incl. nested) so the frontend always sees arrays.
const ARRAY_KEYS = new Set([
  'rows', 'users', 'batches', 'jobs', 'groups', 'permissions', 'mailboxes', 'items', 'plan',
  'results', 'tenants', 'services', 'mailboxBatches', 'fileMoves', 'manifests', 'columns',
  'domains', 'notReady',
])
function normalizeArrays(node) {
  if (Array.isArray(node)) { node.forEach(normalizeArrays); return node }
  if (node && typeof node === 'object') {
    for (const k of Object.keys(node)) {
      const v = node[k]
      if (ARRAY_KEYS.has(k) && v != null && !Array.isArray(v)) node[k] = [v]
      normalizeArrays(node[k])
    }
  }
  return node
}

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
  return normalizeArrays(data)
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
  migrationConfig: () => request('/api/migration-setup/config'),
  migrationConfigSave: (body) => request('/api/migration-setup/config', { method: 'PUT', body: JSON.stringify(body) }),

  // Phase 9 — manifest / groups / permissions
  manifest: () => request('/api/manifest'),
  manifestCapture: (scope) => request('/api/manifest/capture', { method: 'POST', body: JSON.stringify({ scope }) }),
  groups: () => request('/api/groups'),
  groupsSync: () => request('/api/groups/sync', { method: 'POST' }),
  groupsCreate: (groupIds) => request('/api/groups/create', { method: 'POST', body: JSON.stringify({ groupIds, confirm: true }) }),
  permissions: () => request('/api/permissions'),
  sharedMailboxes: () => request('/api/permissions/shared-mailboxes'),
  permissionsCapture: (mailboxes) => request('/api/permissions/capture', { method: 'POST', body: JSON.stringify({ mailboxes }) }),
  permissionsReapply: () => request('/api/permissions/reapply', { method: 'POST', body: JSON.stringify({ confirm: true }) }),

  // Phase 8 — reports
  report: (name) => request(`/api/reports/${name}`),
  reportExportUrl: (name, ext) => `/api/reports/export/${name}.${ext}`,

  // Phase 7 — monitoring
  monitor: () => request('/api/monitor'),
  monitorRefresh: () => request('/api/monitor/refresh', { method: 'POST' }),

  // Phase 6 — file moves (OneDrive + SharePoint)
  fileMoveJobs: () => request('/api/file-move/jobs'),
  fileMoveSourceSites: () => request('/api/file-move/sites/source'),
  fileMoveSiteMigrate: (body) => request('/api/file-move/site-migrate', { method: 'POST', body: JSON.stringify(body) }),
  fileMoveValidate: (type, source, target) => request('/api/file-move/validate', { method: 'POST', body: JSON.stringify({ type, source, target }) }),
  fileMoveStart: (body) => request('/api/file-move/start', { method: 'POST', body: JSON.stringify({ ...body, confirm: true }) }),
  fileMoveRefresh: (id) => request(`/api/file-move/jobs/${id}/refresh`, { method: 'POST' }),
  fileMoveStop: (id) => request(`/api/file-move/jobs/${id}/stop`, { method: 'POST' }),

  // Phase 5 — mailbox batches
  mailboxBatches: () => request('/api/mailbox/batches'),
  mailboxBatch: (id) => request(`/api/mailbox/batches/${id}`),
  mailboxBatchCreate: (name, items) => request('/api/mailbox/batches', { method: 'POST', body: JSON.stringify({ name, items, confirm: true }) }),
  mailboxBatchRefresh: (id) => request(`/api/mailbox/batches/${id}/refresh`, { method: 'POST' }),
  mailboxBatchForwarding: (id) => request(`/api/mailbox/batches/${id}/forwarding`, { method: 'POST', body: JSON.stringify({ confirm: true }) }),
  mailboxBatchComplete: (id, confirmToken) => request(`/api/mailbox/batches/${id}/complete`, { method: 'POST', body: JSON.stringify({ confirm: true, confirmToken }) }),

  // Phase 3 — preflight
  preflightRun: () => request('/api/preflight/run', { method: 'POST' }),
  preflightLatest: () => request('/api/preflight/latest'),
  preflightExportHtmlUrl: (runId) => `/api/preflight/export/${runId}.html`,
  preflightExportCsvUrl: (runId) => `/api/preflight/export/${runId}.csv`,
}
