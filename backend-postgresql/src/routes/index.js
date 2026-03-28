import express from 'express'
import todosRouter from './todos.js'

const router = express.Router()

router.get('/health', (req, res) => {
  res.json({
    status: 'ok',
    service: 'backend-postgresql',
    timestamp: new Date().toISOString(),
  })
})

router.use('/todos', todosRouter)

export default router
