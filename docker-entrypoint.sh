#!/bin/sh
# RCC-HIROS container entrypoint:
#   1. wait for MariaDB to accept connections
#   2. apply pending Prisma migrations (prisma migrate deploy)
#   3. start the Next.js standalone server
set -e

DB_HOST="${DB_HOST:-mariadb}"
DB_PORT="${DB_PORT:-3306}"

echo "[entrypoint] Waiting for MariaDB at ${DB_HOST}:${DB_PORT}..."
node <<'WAITFOR'
const net = require("net");
const host = process.env.DB_HOST || "mariadb";
const port = Number(process.env.DB_PORT || 3306);
const deadline = Date.now() + 90_000;

(function probe() {
  const socket = net.connect({ host, port }, () => {
    socket.end();
    console.log("[entrypoint] Database is reachable.");
    process.exit(0);
  });
  socket.on("error", () => {
    socket.destroy();
    if (Date.now() > deadline) {
      console.error("[entrypoint] Database not reachable after 90s — aborting.");
      process.exit(1);
    }
    setTimeout(probe, 2000);
  });
})();
WAITFOR

echo "[entrypoint] Applying database migrations..."
npx prisma migrate deploy

echo "[entrypoint] Starting Next.js (production)..."
exec node server.js
