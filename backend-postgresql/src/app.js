
import express from 'express'
import cors from 'cors'
import helmet from 'helmet'
import morgan from 'morgan'
import compression from 'compression'
import rateLimit from 'express-rate-limit'

import routes from './routes/index.js'
import prisma from './lib/prisma.js'
import { renderDbPreviewPage } from './devDbPreview.js'

const apiLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 200,
  standardHeaders: true,
  legacyHeaders: false,
})

const app = express()

app.use(
  helmet(
    process.env.NODE_ENV === 'production'
      ? {}
      : { contentSecurityPolicy: false },
  ),
)
app.use(
  cors({
    origin: process.env.CORS_ORIGIN || '*',
    credentials: true,
  }),
)
app.use(compression())
app.use(express.json({ limit: '1mb' }))
app.use(express.urlencoded({ extended: true }))
app.use(morgan(process.env.NODE_ENV === 'production' ? 'combined' : 'dev'))

app.use('/api', apiLimiter)
app.use('/api', routes)

if (process.env.NODE_ENV !== 'production') {
  app.get('/db-preview', async (req, res, next) => {
    try {
      const [todos, users] = await Promise.all([
        prisma.todo.findMany({ orderBy: { createdAt: 'desc' } }),
        prisma.user.findMany({ orderBy: { createdAt: 'desc' } }),
      ])
      res.type('html').send(renderDbPreviewPage({ todos, users }))
    } catch (e) {
      next(e)
    }
  })
}

app.use((req, res) => {
  res.status(404).json({ error: 'Not found' })
})

app.use((err, req, res, _next) => {
  console.error(err)
  const status = err.statusCode || 500
  res.status(status).json({
    error: process.env.NODE_ENV === 'production' ? 'Internal server error' : err.message,
  })
})

export default app
