import 'dotenv/config'
import app from './app.js'
import prisma from './lib/prisma.js'

const port = Number(process.env.PORT) || 4000

async function main() {
  await prisma.$connect()
  app.listen(port, () => {
    console.log(`backend-postgresql listening on http://localhost:${port}`)
    console.log(`Health: http://localhost:${port}/api/health`)
    console.log(`Todos:  http://localhost:${port}/api/todos`)
    if (process.env.NODE_ENV !== 'production') {
      console.log(`DB preview (HTML): http://localhost:${port}/db-preview`)
    }
  })
}

async function shutdown() {
  await prisma.$disconnect()
  process.exit(0)
}

process.once('SIGINT', () => {
  shutdown().catch(() => process.exit(1))
})
process.once('SIGTERM', () => {
  shutdown().catch(() => process.exit(1))
})

main().catch((err) => {
  console.error('Failed to start server:', err)
  process.exit(1)
})
