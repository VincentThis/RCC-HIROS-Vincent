@echo off
title RCC-HIROS - Cloudflare Tunnel
echo ============================================
echo   RCC-HIROS - Starting Cloudflare Tunnel
echo ============================================
echo.
echo Public URL will appear below (....trycloudflare.com).
echo Keep this window OPEN while the app is live.
echo To stop: close this window (or press Ctrl+C).
echo.
where cloudflared >nul 2>nul
if errorlevel 1 (
  echo ERROR: cloudflared not found.
  echo Install it first: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/
  pause
  exit /b 1
)
cloudflared tunnel --url http://localhost:3000
pause
