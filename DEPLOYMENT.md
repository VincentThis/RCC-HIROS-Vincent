# RCC-HIROS — Deployment Architecture

**Live stack:** Next.js 16 (standalone) + MariaDB 11 in Docker, on the on-prem
server PC, exposed to the internet through a free Cloudflare Tunnel.
**CI/CD:** GitHub Actions — lint/build on every push, automatic container
rebuild + restart on merge to `main` via a self-hosted runner.
**Cost:** $0/month (local hardware + free-tier Cloudflare + free GitHub Actions).

```
                     Internet (any browser)
                              │
                              ▼
                   Cloudflare Tunnel (free)
                   cloudflared → :3000
                              │
        ┌─────────────────────┴──────────────────────────┐
        │            On-prem server PC (Windows)         │
        │                                                │
        │  docker compose                                │
        │  ┌──────────────────────┐   ┌───────────────┐  │
        │  │ app :3000            │──►│ mariadb:11    │  │
        │  │ Next.js 16 standalone│   │ volume: db    │  │
        │  │ volume: uploads/     │   └───────────────┘  │
        │  └──────────────────────┘                      │
        │                                                │
        │  kiosk-service (Python, native Windows)        │
        │  127.0.0.1:8765 ◄── ZK9500 USB scanner         │
        │                                                │
        │  GitHub Actions self-hosted runner (pulls      │
        │  jobs from GitHub — outbound only)             │
        └────────────────────────────────────────────────┘
```

---

## 1. Chosen Infrastructure — and why

| Decision | Choice | Reason |
| --- | --- | --- |
| Hosting | **On-premise server PC + Docker Compose** | The ZK9500 fingerprint scanner is physical USB hardware driven by Windows-only ZKFinger SDK DLLs (`libzkfp.dll`). It cannot run in any cloud serverless/container platform. The guidelines explicitly list *"strictly internal tools with privacy constraints → local/on-premise server setup"* as a valid strategy — RCC-HIROS stores employee PII, salaries, and biometric templates, so keeping data on premises is also the privacy-correct choice. |
| Containers | **Docker (multi-stage, `output: "standalone"`)** | `next.config.ts` already sets `output: "standalone"`, so the runtime image is small and self-contained. Docker also replaces XAMPP in production: MariaDB runs as a compose service with a named volume, healthchecks, and automatic migrations in the container entrypoint. |
| Public exposure | **Cloudflare Tunnel (`cloudflared`)** | Gives the app a public HTTPS URL **without opening any inbound port** on the campus network (no port-forwarding, no static public IP needed). Free tier is sufficient. The tunnel only exposes port 3000; MariaDB and the kiosk service (loopback `127.0.0.1:8765`) are never reachable from the internet. |
| Database | **MariaDB 11 (containerized)** | Prisma 7 with the `@prisma/adapter-mariadb` driver adapter speaks MySQL protocol directly — the schema (`provider = "mysql"`) and migrations transfer unchanged from the XAMPP dev setup. Named volume `db` persists data across redeploys. |
| CI/CD | **GitHub Actions** (hosted Ubuntu for CI, **self-hosted Windows runner** for CD) | CI runs lint + build on GitHub's free runners for every push/PR. CD runs on a self-hosted runner registered on the server PC: it polls GitHub over outbound HTTPS (works behind NAT, no inbound exposure), rebuilds the image, applies migrations, and restarts the stack. This satisfies the assignment rule *"manual uploads are not permitted."* |
| Biometrics in prod | **ZK9500 on the kiosk PC + WebAuthn everywhere** | The ZK flow works for browsers running on the machine with the scanner (loopback to `:8765`). Remote users still get hardware-backed biometrics through browser-native **WebAuthn** (`BiometricTemplate.engine = "webauthn"` is already in the schema). |

### Cost
Everything in this design is free: Cloudflare Tunnel (free tier), GitHub
Actions minutes (free for public repos, generous free tier for private),
Docker/MariaDB (open source), and the existing server PC. There is no
billable cloud resource to tear down after grading.

### Scaling
The stack scales vertically (more RAM/CPU on the server PC) and can scale
horizontally later by moving the compose file to any Linux host with Docker
(office server, small VPS) — the only component that must stay on the
kiosk PC is the Python `kiosk-service` + USB scanner. For RCC-HIROS's
actual load (one campus, tens of concurrent HR staff) a single node is
far more capacity than needed.

---

## 2. Trade-offs and limitations

* **Single point of failure.** The server PC must stay powered on for the
  app and the self-hosted runner to be available. Mitigation: the machine
  is already the campus HR workstation; `restart: unless-stopped` brings
  the stack back after reboots.
* **Quick-tunnel URL volatility.** `cloudflared tunnel --url` (quick
  tunnel) assigns a random `*.trycloudflare.com` hostname each time it
  starts. For a stable hostname, create a **named tunnel** with a domain
  on Cloudflare (see §8). The demo works fine with the quick tunnel as
  long as the tunnel process keeps running.
* **Vertical scaling ceiling.** On-prem hardware doesn't auto-scale. Not
  a real constraint for an HR system with a bounded user base.
* **Kiosk biometrics are location-bound.** Only browsers on the kiosk PC
  can drive the ZK9500 (the service binds to loopback by design).
  Remote staff use WebAuthn or manual attendance instead.
* **No managed backups.** DB backups are manual (`backup-database.bat`
  for XAMPP; for the container: `docker compose exec mariadb mysqldump ...`).
  A cron/scheduled task can automate this later.

## 3. Why the other options were rejected

| Option | Why rejected |
| --- | --- |
| **Vercel / Netlify (PaaS)** | Perfect for frontend-only or Next.js apps *without* stateful backends. RCC-HIROS fails that test three ways: (1) the ZK9500 kiosk service needs the physical scanner + Windows DLLs, impossible in serverless; (2) neither platform hosts MySQL — we'd pay for an external database and migrate off MariaDB; (3) employee photos/documents are written to a local `uploads/` directory, which serverless ephemeral filesystems don't persist. The deployed app would *look* live but biometrics and file uploads would break — failing the "fully functional" requirement. |
| **Cloudflare Pages/Workers** | Pages is for static sites/JAMstack; Workers run JS at the edge with no long-lived Node runtime, no MariaDB wire access from Workers without Hyperdrive, and again no USB hardware. Wrong tool for a full-stack Node server. |
| **Docker + AWS ECS (or similar)** | Technically capable, but requires an AWS account, VPC/subnet design, an RDS MySQL instance (billed hourly — the rubric even warns about unexpected DB costs), an ECR registry, and task-definition plumbing. All of that is overkill for a single-node campus HR system and would incur real monthly cost that must be torn down after grading. |
| **Plain on-prem without tunnel** | Only reachable on the campus LAN (no public URL to submit) and would require inbound port-forwarding on the router to expose it — a security non-starter for a system holding employee PII. The Cloudflare Tunnel solves both without opening inbound ports. |

## 4. CI/CD pipeline overview

Configuration file: [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml)

```
push / PR to main ──► CI (ubuntu-latest)
                        1. actions/checkout
                        2. actions/setup-node 22 (npm cache)
                        3. npm ci                    — install dependencies
                        4. npx prisma generate       — generate DB client
                        5. npm run lint              — ESLint
                        6. npm run build             — next build (type-check + compile)

push to main (merge) ──► CD (self-hosted Windows runner on the server PC)
                        1. actions/checkout
                        2. docker compose build      — rebuild image from Dockerfile
                        3. docker compose up -d      — entrypoint applies
                           `prisma migrate deploy`, then starts Next.js
                        4. health-check http://localhost:3000 (retry up to 3 min)
                        5. report commit SHA + tunnel reminder
```

* CI is **required** before CD (`needs: ci`) — a failing lint or build
  blocks deployment.
* CD triggers **only on push to `main`** (i.e., after a merge), never on
  PRs, so production only changes when code lands on the production branch.
* The self-hosted runner polls GitHub over outbound HTTPS, so the server
  PC needs **no inbound firewall rules**.
* The health check fetches `http://127.0.0.1:3000` from inside the
  container over plain HTTP. `src/middleware.ts` therefore skips its
  production HTTPS redirect for **loopback hosts** (`localhost`,
  `127.0.0.1`, `::1`); public traffic arriving via the tunnel still
  gets the HTTPS redirect + HSTS.

## 5. Files added for deployment

| File | Purpose |
| --- | --- |
| `Dockerfile` | 3-stage build: `npm ci` → `next build` (standalone) → minimal runtime + Prisma CLI |
| `docker-entrypoint.sh` | Waits for MariaDB → `prisma migrate deploy` → `node server.js` |
| `docker-compose.yml` | `app` + `mariadb:11` services, named volumes `db` and `uploads`, healthchecks |
| `.dockerignore` | Keeps secrets, local data, and dev-only files out of the image |
| `.github/workflows/deploy.yml` | CI (lint + build) and CD (self-hosted deploy) pipeline |
| `scripts/start-tunnel.bat` | Launches `cloudflared` quick tunnel → public HTTPS URL |
| `.env.example` | Documents `DB_PASSWORD` (compose) alongside existing dev vars |

## 6. Environment variables and secrets

| Variable | Where used | Notes |
| --- | --- | --- |
| `DATABASE_URL` | app container (runtime), Prisma CLI | Compose builds it from `DB_PASSWORD` and points at the `mariadb` service — never committed |
| `DB_PASSWORD` | compose interpolation (CD job) | Root password for containerized MariaDB; stored as a **GitHub Actions repo secret** |
| `JWT_SECRET` | app container (CD job) | Signs auth tokens; strong random value stored as a **GitHub Actions repo secret** — never committed, never baked into the image |
| `NEXT_PUBLIC_KIOSK_SERVICE_URL` | build arg + runtime | Loopback URL of the kiosk service; inlined into the client bundle at build time |

**How secrets reach production:** the CD job in
[`.github/workflows/deploy.yml`](.github/workflows/deploy.yml) declares
`JWT_SECRET` and `DB_PASSWORD` from the repository's encrypted
**Actions secrets** (Settings → Secrets and variables → Actions). They are
exported only into the deploy job's environment, where `docker-compose.yml`
interpolates them into the container configuration. They never exist in the
repository, the git history, or the runner workspace. CI uses throwaway
dummy values that are never exposed to the runtime stack.

For **manual** `docker compose` runs directly on the server PC (outside the
pipeline), place a `.env` file next to `docker-compose.yml` (copy
`.env.example`); compose reads it for the same two variables. `.env` is
git-ignored and excluded via `.dockerignore`.

## 7. One-time server setup (as actually performed)

Verified versions on the server PC: **WSL 3.0.3**, **Docker Desktop
4.96.1** (engine **29.9.2**, Compose **v5.6.0**, Buildx **v0.38.1**,
WSL2 backend, default distro `docker-desktop`), container runtime
**Node 22** (alpine), GitHub runner **Windows x64**.

1. **Virtual Machine Platform + WSL:** install WSL 3.0.3 (`wsl.msi`),
   enable the `Virtual Machine Platform` Windows feature
   (`DISM /Online /Enable-Feature /FeatureName:VirtualMachinePlatform /All`
   + reboot). Docker Desktop's WSL2 backend needs both.
2. **Docker Desktop:** install via `winget install Docker.Desktop`
   (WSL2 backend is the default). Onboarding accepted; Docker Desktop
   autostarts at logon (`HKCU\...\Run`).
3. **PowerShell execution policy:** GitHub Actions writes per-step
   `.ps1` scripts, which the Windows default `Restricted` policy blocks
   (`running scripts is disabled on this system` → CD job fails at its
   first step). Fix once per user:
   ```
   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
   ```
4. **GitHub self-hosted runner:** repo → *Settings → Actions → Runners →
   New self-hosted runner (Windows x64)* → `config.cmd`, registered for
   **this user interactively** (not the optional `--runasservice`), so it
   inherits the user's Docker Desktop access. Files live in
   `C:\deploy\runner`; runner name **`rcc-hiros-server`**
   (labels `self-hosted`/`Windows`/`X64`). Autostart at logon:
   `HKCU\...\Run` value **`RCC-HIROS-Runner`** →
   `wscript C:\deploy\run-hidden.vbs` (hides the console window).
5. **App secrets → GitHub Actions repo secrets:** *Settings → Secrets and
   variables → Actions* → set **`JWT_SECRET`** (strong random) and
   **`DB_PASSWORD`**. The CD job injects them into `docker compose` at
   deploy time (see §6); no `.env` file is required for pipeline deploys.
6. **cloudflared:** download `cloudflared.exe`, then start the quick
   tunnel (equivalent to `scripts\start-tunnel.bat`):
   ```
   cloudflared tunnel --url http://localhost:3000
   ```
   Copy the printed `*.trycloudflare.com` URL — that is the **Live URL**
   to submit. The URL is only valid while that process runs.
7. **Seed the fresh database** (no XAMPP/MySQL on this machine — the DB
   is the containerized MariaDB) with demo data + the admin account
   (see §8 for the command).
8. **(Optional) import existing dev data** from XAMPP:
   ```
   mysqldump -u root rcc_hiros > dump.sql
   docker compose exec -T mariadb mariadb -u root -p%DB_PASSWORD% rcc_hiros < dump.sql
   ```

## 8. Day-2 operations

| Task | Command |
| --- | --- |
| Start / stop the stack | `docker compose up -d` / `docker compose down` |
| View logs | `docker compose logs -f app` |
| Deploy a change | merge to `main` → Actions handles the rest |
| Seed / re-seed demo data | `docker compose -p rcc-hiros exec -w /app app npx tsx prisma/seed.ts` (idempotent upserts; admin login: `admin@rcc.edu.ph` / `RCC2026!`) |
| DB backup | `docker compose exec -T mariadb mysqldump -u root -p%DB_PASSWORD% rcc_hiros > backup.sql` |
| DB restore | `docker compose exec -T mariadb mariadb -u root -p%DB_PASSWORD% rcc_hiros < backup.sql` |
| Rollback | `git revert <bad-commit>` and push to `main` (pipeline redeploys) |
| Kiosk service | `python kiosk-service\main.py` on the PC with the ZK9500 (unchanged from dev) |
| Stable public URL (optional) | Buy/add a domain to Cloudflare, then `cloudflared tunnel create rcc-hiros` + route the hostname to `localhost:3000`; run it as a Windows service instead of the quick tunnel |

## 9. Grading deliverables

1. **Live URL** — the `*.trycloudflare.com` address printed by
   `scripts\start-tunnel.bat` (or your named-tunnel hostname).
2. **CI/CD configuration** —
   [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml)
3. **This document** — [`DEPLOYMENT.md`](DEPLOYMENT.md)
