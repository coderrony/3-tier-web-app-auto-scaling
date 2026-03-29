/**
 * PM2 config (same idea as resources/deploy-backend.sh).
 * Env comes from SSM-written file — pass absolute path when starting:
 *   BACKEND_ENV_FILE=/etc/todo-backend/environment pm2 start ecosystem.config.cjs
 */
const envFile =
  process.env.BACKEND_ENV_FILE || '/etc/todo-backend/environment'

module.exports = {
  apps: [
    {
      name: process.env.PM2_APP_NAME || 'todo-backend',
      cwd: __dirname,
      script: 'src/server.js',
      node_args: `--env-file=${envFile}`,
      instances: 1,
      exec_mode: 'fork',
      autorestart: true,
      max_restarts: 30,
      min_uptime: '3s',
    },
  ],
}
