import { PrismaClient } from "../generated/prisma/client";
import { PrismaMariaDb } from "@prisma/adapter-mariadb";

// Connection config comes from DATABASE_URL (compose sets it to the
// `mariadb` service; dev .env points at local XAMPP). Fallbacks preserve
// the historical XAMPP defaults: root with no password on localhost.
function dbConfig() {
  const url = process.env.DATABASE_URL;
  if (!url) {
    return {
      host: "localhost",
      port: 3306,
      user: "root",
      password: "",
      database: "rcc_hiros",
      connectionLimit: 10,
    };
  }
  const u = new URL(url);
  return {
    host: u.hostname,
    port: Number(u.port || 3306),
    user: decodeURIComponent(u.username || "root"),
    password: decodeURIComponent(u.password || ""),
    database: u.pathname.replace(/^\//, "") || "rcc_hiros",
    connectionLimit: 10,
  };
}

const adapter = new PrismaMariaDb(dbConfig());

// ═══════════════════════════════════════════════════════════════
// RCC-HIROS — Prisma client singleton
// ═══════════════════════════════════════════════════════════════

const globalForPrisma = globalThis as unknown as {
  prisma: PrismaClient | undefined;
};

export const db =
  globalForPrisma.prisma ??
  new PrismaClient({
    adapter,
    log: process.env.NODE_ENV === "development" ? ["error", "warn"] : ["error"],
  });

if (process.env.NODE_ENV !== "production") globalForPrisma.prisma = db;
