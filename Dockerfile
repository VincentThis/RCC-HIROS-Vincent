# ─────────────────────────────────────────────────────────────
# RCC-HIROS — multi-stage production image (Next.js standalone)
# Stage 1: dependencies   Stage 2: build   Stage 3: runtime
# ─────────────────────────────────────────────────────────────

# ── Stage 1: dependencies ────────────────────────────────────
FROM node:22-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
# sharp (native) + prisma CLI need their postinstall scripts
RUN npm ci

# ── Stage 2: build ───────────────────────────────────────────
FROM node:22-alpine AS build
WORKDIR /app
ENV NEXT_TELEMETRY_DISABLED=1
# NEXT_PUBLIC_* vars are inlined into the client bundle at build time.
# The kiosk URL is the loopback constant used by browsers on the kiosk PC.
ARG NEXT_PUBLIC_KIOSK_SERVICE_URL=http://127.0.0.1:8765
ENV NEXT_PUBLIC_KIOSK_SERVICE_URL=$NEXT_PUBLIC_KIOSK_SERVICE_URL
# prisma.config.ts reads DATABASE_URL via env("DATABASE_URL") even for
# `prisma generate` — no real DB connection is made at build time.
ENV DATABASE_URL=mysql://root:build-only@127.0.0.1:3306/rcc_hiros
ENV JWT_SECRET=build-only-not-used-at-runtime
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN npm run build

# ── Stage 3: runtime ─────────────────────────────────────────
FROM node:22-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
ENV PORT=3000
ENV HOSTNAME=0.0.0.0

# Next.js standalone output (self-contained server + traced deps)
COPY --from=build /app/.next/standalone ./
COPY --from=build /app/.next/static ./.next/static
COPY --from=build /app/public ./public

# Extra files the container needs at runtime:
# - full node_modules: provides the Prisma CLI (migrate deploy) and
#   sharp (serverExternalPackages) on top of the standalone bundle
# - prisma/ + prisma.config.ts + package.json: schema, migrations, seeds
# - src/: seed.ts imports ../src/lib/db and the generated Prisma client
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/prisma ./prisma
COPY --from=build /app/src ./src
COPY --from=build /app/prisma.config.ts ./prisma.config.ts
COPY --from=build /app/package.json ./package.json
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
# Normalize line endings in case the build context came from a Windows checkout
RUN sed -i 's/\r$//' /usr/local/bin/docker-entrypoint.sh \
  && chmod +x /usr/local/bin/docker-entrypoint.sh \
  && addgroup -S nodejs && adduser -S nextjs -G nodejs \
  && mkdir -p /app/uploads && chown -R nextjs:nodejs /app

USER nextjs
EXPOSE 3000

# Entrypoint waits for MariaDB, applies migrations, then starts Next.js
ENTRYPOINT ["docker-entrypoint.sh"]
