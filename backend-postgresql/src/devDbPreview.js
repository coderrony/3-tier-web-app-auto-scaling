function escapeHtml(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/"/g, '&quot;')
}

export function renderDbPreviewPage({ todos, users }) {
  const todoRows =
    todos.length === 0
      ? '<tr><td colspan="5" style="padding:12px;color:#64748b">No rows</td></tr>'
      : todos
          .map(
            (t) => `<tr>
  <td style="padding:8px;border-bottom:1px solid #e2e8f0;font-family:monospace;font-size:12px">${escapeHtml(t.id)}</td>
  <td style="padding:8px;border-bottom:1px solid #e2e8f0">${escapeHtml(t.title)}</td>
  <td style="padding:8px;border-bottom:1px solid #e2e8f0">${t.completed ? 'Yes' : 'No'}</td>
  <td style="padding:8px;border-bottom:1px solid #e2e8f0;font-size:12px">${escapeHtml(String(t.createdAt))}</td>
  <td style="padding:8px;border-bottom:1px solid #e2e8f0;font-size:12px">${escapeHtml(String(t.updatedAt))}</td>
</tr>`,
          )
          .join('')

  const userRows =
    users.length === 0
      ? '<tr><td colspan="4" style="padding:12px;color:#64748b">No rows</td></tr>'
      : users
          .map(
            (u) => `<tr>
  <td style="padding:8px;border-bottom:1px solid #e2e8f0;font-family:monospace;font-size:12px">${escapeHtml(u.id)}</td>
  <td style="padding:8px;border-bottom:1px solid #e2e8f0">${escapeHtml(u.email)}</td>
  <td style="padding:8px;border-bottom:1px solid #e2e8f0">${u.name ? escapeHtml(u.name) : '—'}</td>
  <td style="padding:8px;border-bottom:1px solid #e2e8f0;font-size:12px">${escapeHtml(String(u.createdAt))}</td>
</tr>`,
          )
          .join('')

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Local database preview</title>
  <style>
    body { font-family: system-ui, sans-serif; margin: 24px; background: #f8fafc; color: #0f172a; }
    h1 { font-size: 1.25rem; margin-bottom: 8px; }
    p { color: #64748b; font-size: 14px; max-width: 52rem; line-height: 1.5; }
    table { border-collapse: collapse; width: 100%; max-width: 56rem; background: #fff; border-radius: 8px; overflow: hidden; box-shadow: 0 1px 3px rgb(0 0 0 / 0.08); margin-bottom: 32px; }
    th { text-align: left; padding: 10px 8px; background: #f1f5f9; font-size: 12px; text-transform: uppercase; letter-spacing: 0.04em; color: #475569; }
    h2 { font-size: 1rem; margin: 24px 0 12px; }
    code { background: #e2e8f0; padding: 2px 6px; border-radius: 4px; font-size: 12px; }
  </style>
</head>
<body>
  <h1>Local database preview</h1>
  <p>
    This page is served only when <code>NODE_ENV</code> is not <code>production</code>.
    It reads directly from PostgreSQL via Prisma — no Prisma Studio required.
    Refresh the page after changing data from your app.
  </p>
  <p style="margin-top:8px">
    <strong>Prisma Studio</strong> (<code>npx prisma studio</code>) is still the full GUI for editing rows;
    use this page if Studio shows errors but your API and DB are working.
  </p>

  <h2>Todo</h2>
  <table>
    <thead><tr>
      <th>id</th><th>title</th><th>completed</th><th>createdAt</th><th>updatedAt</th>
    </tr></thead>
    <tbody>${todoRows}</tbody>
  </table>

  <h2>User</h2>
  <table>
    <thead><tr>
      <th>id</th><th>email</th><th>name</th><th>createdAt</th>
    </tr></thead>
    <tbody>${userRows}</tbody>
  </table>
</body>
</html>`
}
