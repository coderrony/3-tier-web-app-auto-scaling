import express from 'express'
import prisma from '../lib/prisma.js'

const router = express.Router()

router.get('/', async (req, res, next) => {
  try {
    const todos = await prisma.todo.findMany({
      orderBy: { createdAt: 'desc' },
    })
    res.json({ data: todos })
  } catch (e) {
    next(e)
  }
})

router.post('/', async (req, res, next) => {
  try {
    const title = typeof req.body?.title === 'string' ? req.body.title.trim() : ''
    if (!title) {
      res.status(400).json({ error: 'Title is required' })
      return
    }
    if (title.length > 500) {
      res.status(400).json({ error: 'Title must be 500 characters or less' })
      return
    }
    const completed = Boolean(req.body?.completed)
    const todo = await prisma.todo.create({
      data: { title, completed },
    })
    res.status(201).json({ data: todo })
  } catch (e) {
    next(e)
  }
})

router.patch('/:id', async (req, res, next) => {
  try {
    const { id } = req.params
    const existing = await prisma.todo.findUnique({ where: { id } })
    if (!existing) {
      res.status(404).json({ error: 'Todo not found' })
      return
    }

    const data = {}
    if (req.body?.title !== undefined) {
      const title =
        typeof req.body.title === 'string' ? req.body.title.trim() : ''
      if (!title) {
        res.status(400).json({ error: 'Title cannot be empty' })
        return
      }
      if (title.length > 500) {
        res.status(400).json({ error: 'Title must be 500 characters or less' })
        return
      }
      data.title = title
    }
    if (req.body?.completed !== undefined) {
      data.completed = Boolean(req.body.completed)
    }
    if (Object.keys(data).length === 0) {
      res.status(400).json({ error: 'No valid fields to update' })
      return
    }

    const todo = await prisma.todo.update({
      where: { id },
      data,
    })
    res.json({ data: todo })
  } catch (e) {
    next(e)
  }
})

router.delete('/:id', async (req, res, next) => {
  try {
    const { id } = req.params
    const existing = await prisma.todo.findUnique({ where: { id } })
    if (!existing) {
      res.status(404).json({ error: 'Todo not found' })
      return
    }
    await prisma.todo.delete({ where: { id } })
    res.status(204).send()
  } catch (e) {
    next(e)
  }
})

export default router
