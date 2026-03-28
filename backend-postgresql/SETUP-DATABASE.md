# Database setup

**Default (no install):** the project uses **SQLite** (`prisma/dev.db`) via `DATABASE_URL="file:./dev.db"`. Run `npm run db:push` once, then `npm run dev` — no PostgreSQL server is required.

For **PostgreSQL** (Docker or native install), change `provider` in `prisma/schema.prisma` to `postgresql`, set `DATABASE_URL` to your Postgres URL, then `npx prisma db push` or `migrate`.

---

# Local PostgreSQL setup (fix `P1001: Can't reach database server`)

## Docker vs Prisma Studio (important)

- **Docker is optional.** It is only one way to run a PostgreSQL **server** on your PC. You do **not** need Docker to use **`npx prisma studio`**.
- **Prisma Studio** is a separate tool: it opens in the browser and talks to whatever database your `DATABASE_URL` points to. For it to work you still need **PostgreSQL running somewhere** (Windows install, cloud, or Docker) and a **successful** `npm run db:push` (or migrations).

If Prisma Studio shows **“Prisma Client Error” / “Unable to run script”** with garbled text mentioning `STUDIO_EMBED_BUILD`, that often means the **database is not reachable** or the client is out of sync. Try in order:

1. Confirm PostgreSQL is running (`db:push` / `npm run dev` should work without `P1001`).
2. From `backend-postgresql`: `npx prisma generate` then `npx prisma studio` again.
3. **Incognito/private window** or another browser (extensions sometimes break Studio).
4. In the project folder, delete `node_modules` and run `npm install` again.

**Alternative without Studio:** run the API (`npm run dev`) and open **`http://localhost:4000/db-preview`** (development only). It shows **Todo** and **User** tables as HTML — no Prisma Studio required.

---

Error **P1001** means nothing is listening on the host/port in your `DATABASE_URL` (usually `localhost:5432`). You must **install and start PostgreSQL**, or run it with **Docker**.

Your `.env` is already aligned with the Docker Compose file:

`postgresql://postgres:postgres@localhost:5432/backend_postgresql?schema=public`

---

## Option A — Docker (recommended after installing Docker Desktop)

1. Install [Docker Desktop for Windows](https://docs.docker.com/desktop/install/windows-install/).
2. Start Docker Desktop and wait until it is running.
3. From the `backend-postgresql` folder:

```powershell
docker compose up -d
```

4. Wait a few seconds, then apply the schema:

```powershell
npm run db:push
```

5. Start the API:

```powershell
npm run dev
```

Stop the database (data stays in the volume):

```powershell
docker compose down
```

---

## Option B — PostgreSQL installed on Windows (no Docker)

1. Download and install PostgreSQL from [postgresql.org/download/windows](https://www.postgresql.org/download/windows/) (remember the password you set for user `postgres`).
2. Open **Services** (`Win + R` → `services.msc`) and ensure the **postgresql** service is **Running**. If not, right‑click → **Start**.
3. Create the database (e.g. with **pgAdmin** or **SQL Shell (psql)**):

```sql
CREATE DATABASE backend_postgresql;
```

4. Edit `backend-postgresql/.env` and set `DATABASE_URL` to match your user, password, host, port, and database name, for example:

```env
DATABASE_URL="postgresql://postgres:YOUR_PASSWORD@localhost:5432/backend_postgresql?schema=public"
```

5. Run:

```powershell
npm run db:push
npm run dev
```

---

## Inspect data locally

- **In-browser HTML (no Prisma Studio)** — after `npm run dev`, open:

`http://localhost:4000/db-preview`

(Read-only table view; `NODE_ENV` must not be `production`.)

- **Prisma Studio** (GUI for tables and rows):

```powershell
cd backend-postgresql
npx prisma studio
```

or `npm run db:studio`. Always run this from the folder that contains `prisma/schema.prisma`.

- **JSON API** in the browser: `http://localhost:4000/api/todos`

- **pgAdmin** (if you installed PostgreSQL): connect to `localhost`, open `backend_postgresql` → **Schemas** → **public** → **Tables**.

---

## Checklist

| Check | Action |
|--------|--------|
| Port 5432 in use by another app | Change Docker mapping to `"5433:5432"` and use `@localhost:5433` in `DATABASE_URL` |
| Firewall | Allow PostgreSQL or Docker on local connections |
| Wrong password | Update `DATABASE_URL` to match the real password |
