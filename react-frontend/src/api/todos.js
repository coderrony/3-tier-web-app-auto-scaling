const base = import.meta.env.VITE_API_URL?.replace(/\/$/, '') || ''

function apiUrl(path) {
  const p = path.startsWith('/') ? path : `/${path}`
  return base ? `${base}${p}` : p
}

async function apiFetch(path, options = {}) {
  try {
    return await fetch(apiUrl(path), options)
  } catch (e) {
    if (e instanceof TypeError) {
      throw new Error(
        'Cannot connect to the API. Start the backend on port 4000 (cd backend-postgresql && npm run dev), or from the project folder run npm run dev to start both servers.',
      )
    }
    throw e
  }
}

const BACKEND_DOWN_MSG =
  'Cannot connect to the API. Start the backend on port 4000 (cd backend-postgresql && npm run dev), or from the project folder run npm run dev to start both servers.'

function assertBackendReachable(res) {
  if (res.status === 502 || res.status === 503 || res.status === 504) {
    throw new Error(BACKEND_DOWN_MSG)
  }
}

async function handleJson(res) {
  const text = await res.text()
  if (!text) {
    return res.ok ? {} : { error: res.statusText }
  }
  try {
    return JSON.parse(text)
  } catch {
    return { error: text || res.statusText }
  }
}

export async function fetchTodos() {
  const res = await apiFetch('/api/todos')
  assertBackendReachable(res)
  const body = await handleJson(res)
  if (!res.ok) {
    throw new Error(body.error || 'Failed to load todos')
  }
  return body.data
}

export async function createTodo({ title, completed = false }) {
  const res = await apiFetch('/api/todos', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ title, completed }),
  })
  assertBackendReachable(res)
  const body = await handleJson(res)
  if (!res.ok) {
    throw new Error(body.error || 'Failed to create todo')
  }
  return body.data
}

export async function updateTodo(id, patch) {
  const res = await apiFetch(`/api/todos/${id}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(patch),
  })
  assertBackendReachable(res)
  const body = await handleJson(res)
  if (!res.ok) {
    throw new Error(body.error || 'Failed to update todo')
  }
  return body.data
}

export async function deleteTodo(id) {
  const res = await apiFetch(`/api/todos/${id}`, {
    method: 'DELETE',
  })
  assertBackendReachable(res)
  if (res.status === 204) return
  const body = await handleJson(res)
  if (!res.ok) {
    throw new Error(body.error || 'Failed to delete todo')
  }
}
