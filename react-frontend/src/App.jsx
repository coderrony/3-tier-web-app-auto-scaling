import { useCallback, useEffect, useState } from 'react'
import {
  createTodo,
  deleteTodo,
  fetchTodos,
  updateTodo,
} from './api/todos.js'

function App() {
  const [todos, setTodos] = useState([])
  const [newTitle, setNewTitle] = useState('')
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [savingId, setSavingId] = useState(null)
  const [editingId, setEditingId] = useState(null)
  const [editDraft, setEditDraft] = useState('')

  const load = useCallback(async () => {
    setError(null)
    setLoading(true)
    try {
      const data = await fetchTodos()
      setTodos(data)
    } catch (e) {
      setError(e.message || 'Something went wrong')
      setTodos([])
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    load()
  }, [load])

  async function handleAdd(e) {
    e.preventDefault()
    const title = newTitle.trim()
    if (!title) return
    setError(null)
    try {
      const todo = await createTodo({ title })
      setTodos((prev) => [todo, ...prev])
      setNewTitle('')
    } catch (e) {
      setError(e.message || 'Could not add todo')
    }
  }

  async function handleToggle(todo) {
    setSavingId(todo.id)
    setError(null)
    try {
      const updated = await updateTodo(todo.id, {
        completed: !todo.completed,
      })
      setTodos((prev) =>
        prev.map((t) => (t.id === updated.id ? updated : t)),
      )
    } catch (e) {
      setError(e.message || 'Could not update todo')
    } finally {
      setSavingId(null)
    }
  }

  async function handleDelete(id) {
    setSavingId(id)
    setError(null)
    try {
      await deleteTodo(id)
      setTodos((prev) => prev.filter((t) => t.id !== id))
      if (editingId === id) {
        setEditingId(null)
        setEditDraft('')
      }
    } catch (e) {
      setError(e.message || 'Could not delete todo')
    } finally {
      setSavingId(null)
    }
  }

  function startEdit(todo) {
    setEditingId(todo.id)
    setEditDraft(todo.title)
  }

  function cancelEdit() {
    setEditingId(null)
    setEditDraft('')
  }

  async function saveEdit(id) {
    const title = editDraft.trim()
    if (!title) return
    setSavingId(id)
    setError(null)
    try {
      const updated = await updateTodo(id, { title })
      setTodos((prev) =>
        prev.map((t) => (t.id === updated.id ? updated : t)),
      )
      cancelEdit()
    } catch (e) {
      setError(e.message || 'Could not save changes')
    } finally {
      setSavingId(null)
    }
  }

  return (
    <div className="min-h-dvh bg-slate-950 text-slate-100 antialiased">
      <div className="pointer-events-none fixed inset-0 bg-[radial-gradient(ellipse_80%_50%_at_50%_-20%,rgba(56,189,248,0.12),transparent)]" />

      <header className="relative border-b border-slate-800/80 bg-slate-950/80 backdrop-blur-sm">
        <div className="mx-auto flex max-w-xl items-center justify-between px-4 py-4 sm:px-6">
          <h1 className="text-lg font-semibold tracking-tight text-white">
            Todo
          </h1>
          <span className="text-xs text-slate-500">react-frontend</span>
        </div>
      </header>

      <main className="relative mx-auto max-w-2xl px-4 py-8 sm:px-6">
        <section
          className="mb-8 space-y-3 rounded-xl border border-slate-800 bg-slate-900/50 p-4 text-sm leading-relaxed text-slate-300"
          aria-label="Stack and local run instructions"
        >
          <h2 className="text-xs font-semibold uppercase tracking-wide text-slate-500">
            Backend API &amp; database
          </h2>
          <p>
            This UI talks to the{' '}
            <strong className="font-medium text-slate-200">Express</strong>{' '}
            backend (<span className="text-slate-400">backend-postgresql</span>
            ). It exposes REST routes under{' '}
            <code className="rounded bg-slate-800 px-1.5 py-0.5 font-mono text-xs text-sky-300">
              /api/todos
            </code>{' '}
            and uses{' '}
            <strong className="font-medium text-slate-200">Prisma</strong> as
            the ORM.
          </p>
          <p>
            <strong className="font-medium text-slate-200">PostgreSQL</strong>{' '}
            is supported for production-style setups: configure{' '}
            <code className="rounded bg-slate-800 px-1.5 py-0.5 font-mono text-xs text-sky-300">
              DATABASE_URL
            </code>{' '}
            and the datasource in{' '}
            <code className="rounded bg-slate-800 px-1.5 py-0.5 font-mono text-xs text-sky-300">
              prisma/schema.prisma
            </code>
            , or use the included{' '}
            <code className="rounded bg-slate-800 px-1.5 py-0.5 font-mono text-xs text-sky-300">
              docker-compose.yml
            </code>{' '}
            to run Postgres locally. For quick local dev, the backend defaults to{' '}
            <strong className="font-medium text-slate-200">SQLite</strong> (
            <code className="rounded bg-slate-800 px-1.5 py-0.5 font-mono text-xs text-sky-300">
              prisma/dev.db
            </code>
            ) so you do not need a running Postgres server on your machine.
          </p>
          <h2 className="pt-1 text-xs font-semibold uppercase tracking-wide text-slate-500">
            Run locally
          </h2>
          <ol className="list-decimal space-y-1.5 pl-5 text-slate-300">
            <li>
              From the <strong className="text-slate-200">project root</strong>{' '}
              (
              <code className="rounded bg-slate-800 px-1 py-0.5 font-mono text-[11px] text-sky-300">
                09-Automation-AutoScaling-CICD-3-Tier
              </code>
              ), install once:{' '}
              <code className="rounded bg-slate-800 px-1.5 py-0.5 font-mono text-xs text-sky-300">
                npm install
              </code>
            </li>
            <li>
              Start API + UI together:{' '}
              <code className="rounded bg-slate-800 px-1.5 py-0.5 font-mono text-xs text-sky-300">
                npm run dev
              </code>{' '}
              — backend on{' '}
              <code className="rounded bg-slate-800 px-1 py-0.5 font-mono text-[11px] text-sky-300">
                http://localhost:4000
              </code>
              , this app on{' '}
              <code className="rounded bg-slate-800 px-1 py-0.5 font-mono text-[11px] text-sky-300">
                http://localhost:5173
              </code>
              .
            </li>
            <li>
              Or use two terminals:{' '}
              <code className="rounded bg-slate-800 px-1.5 py-0.5 font-mono text-xs text-sky-300">
                npm run dev
              </code>{' '}
              inside{' '}
              <code className="rounded bg-slate-800 px-1.5 py-0.5 font-mono text-xs text-sky-300">
                backend-postgresql
              </code>
              , then{' '}
              <code className="rounded bg-slate-800 px-1.5 py-0.5 font-mono text-xs text-sky-300">
                npm run dev
              </code>{' '}
              inside{' '}
              <code className="rounded bg-slate-800 px-1.5 py-0.5 font-mono text-xs text-sky-300">
                react-frontend
              </code>
              .
            </li>
          </ol>
        </section>

        <p className="mb-6 text-sm text-slate-400">
          Add, edit, complete, or delete tasks below. The list is loaded from the
          backend API.
        </p>

        <form
          onSubmit={handleAdd}
          className="mb-8 flex flex-col gap-3 sm:flex-row sm:items-stretch"
        >
          <input
            type="text"
            value={newTitle}
            onChange={(e) => setNewTitle(e.target.value)}
            placeholder="What needs to be done?"
            maxLength={500}
            className="min-w-0 flex-1 rounded-xl border border-slate-700 bg-slate-900/80 px-4 py-3 text-sm text-white placeholder:text-slate-500 focus:border-sky-500/60 focus:outline-none focus:ring-2 focus:ring-sky-500/30"
            aria-label="New task title"
          />
          <button
            type="submit"
            className="rounded-xl bg-sky-600 px-5 py-3 text-sm font-medium text-white transition hover:bg-sky-500 focus:outline-none focus-visible:ring-2 focus-visible:ring-sky-400 focus-visible:ring-offset-2 focus-visible:ring-offset-slate-950 disabled:opacity-50"
            disabled={!newTitle.trim()}
          >
            Add
          </button>
        </form>

        {error && (
          <div
            className="mb-4 rounded-xl border border-red-500/40 bg-red-950/40 px-4 py-3 text-sm text-red-200"
            role="alert"
          >
            {error}
          </div>
        )}

        {loading ? (
          <p className="text-center text-sm text-slate-500">Loading…</p>
        ) : todos.length === 0 ? (
          <p className="text-center text-sm text-slate-500">
            No tasks yet. Add one above.
          </p>
        ) : (
          <ul className="space-y-2">
            {todos.map((todo) => (
              <li
                key={todo.id}
                className="flex flex-col gap-3 rounded-xl border border-slate-800 bg-slate-900/50 p-4 sm:flex-row sm:items-center sm:justify-between"
              >
                <div className="flex min-w-0 flex-1 items-start gap-3">
                  <input
                    type="checkbox"
                    checked={todo.completed}
                    onChange={() => handleToggle(todo)}
                    disabled={savingId === todo.id}
                    className="mt-1 size-4 shrink-0 rounded border-slate-600 text-sky-600 focus:ring-sky-500/40"
                    aria-label={
                      todo.completed ? 'Mark as incomplete' : 'Mark as complete'
                    }
                  />
                  {editingId === todo.id ? (
                    <div className="flex min-w-0 flex-1 flex-col gap-2 sm:flex-row sm:items-center">
                      <input
                        type="text"
                        value={editDraft}
                        onChange={(e) => setEditDraft(e.target.value)}
                        maxLength={500}
                        className="min-w-0 flex-1 rounded-lg border border-slate-600 bg-slate-950 px-3 py-2 text-sm text-white focus:border-sky-500/60 focus:outline-none focus:ring-1 focus:ring-sky-500/40"
                        aria-label="Edit task title"
                      />
                      <div className="flex shrink-0 gap-2">
                        <button
                          type="button"
                          onClick={() => saveEdit(todo.id)}
                          disabled={
                            savingId === todo.id || !editDraft.trim()
                          }
                          className="rounded-lg bg-emerald-700 px-3 py-2 text-xs font-medium text-white hover:bg-emerald-600 disabled:opacity-50"
                        >
                          Save
                        </button>
                        <button
                          type="button"
                          onClick={cancelEdit}
                          className="rounded-lg border border-slate-600 px-3 py-2 text-xs text-slate-300 hover:bg-slate-800"
                        >
                          Cancel
                        </button>
                      </div>
                    </div>
                  ) : (
                    <span
                      className={`min-w-0 flex-1 text-sm ${
                        todo.completed
                          ? 'text-slate-500 line-through'
                          : 'text-slate-100'
                      }`}
                    >
                      {todo.title}
                    </span>
                  )}
                </div>

                {editingId !== todo.id && (
                  <div className="flex shrink-0 gap-2 sm:ml-2">
                    <button
                      type="button"
                      onClick={() => startEdit(todo)}
                      disabled={savingId === todo.id}
                      className="rounded-lg border border-slate-600 px-3 py-2 text-xs text-slate-300 hover:bg-slate-800 disabled:opacity-50"
                    >
                      Edit
                    </button>
                    <button
                      type="button"
                      onClick={() => handleDelete(todo.id)}
                      disabled={savingId === todo.id}
                      className="rounded-lg border border-red-500/40 bg-red-950/30 px-3 py-2 text-xs text-red-300 hover:bg-red-950/50 disabled:opacity-50"
                    >
                      Delete
                    </button>
                  </div>
                )}
              </li>
            ))}
          </ul>
        )}
      </main>
    </div>
  )
}

export default App
