#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# Deploy Web Lumera — R2 (PCK) + Vercel (HTML/JS/WASM)
#
# Uso:
#   ./deploy-web.sh                # deploy completo
#   ./deploy-web.sh --skip-upload  # pula rclone (PCK ja tá no R2)
#   ./deploy-web.sh --skip-vercel  # só atualiza HTML local + R2
#
# Faz:
#   1. Upload index.pck pro R2 via rclone (idempotente)
#   2. Reaplica GODOT_PCK_URL + mainPack no index.html com ETag atual
#   3. Deploy no Vercel (--prod)
#
# Requisitos:
#   - Git Bash (NAO PowerShell — precisa de sed/curl/bash)
#   - rclone em ../rclone-*/rclone ou no PATH
#   - vercel CLI no PATH (npm i -g vercel)
#   - Rodar de dentro de lumera-web-export-v2/
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

SKIP_UPLOAD=0
SKIP_VERCEL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-upload) SKIP_UPLOAD=1 ;;
        --skip-vercel) SKIP_VERCEL=1 ;;
        -h|--help)     sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "flag desconhecida: $1" >&2; exit 1 ;;
    esac
    shift
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

log()  { printf '\033[36m[%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$1"; }
ok()   { printf '\033[32m[%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$1"; }
err()  { printf '\033[31m[%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$1" >&2; }

# ── Localiza rclone (binário local primeiro, depois PATH) ──────
RCLONE_BIN=""
for candidate in ../rclone-*/rclone.exe ../rclone-*/rclone; do
    if [ -x "$candidate" ]; then RCLONE_BIN="$candidate"; break; fi
done
if [ -z "$RCLONE_BIN" ] && command -v rclone >/dev/null 2>&1; then
    RCLONE_BIN="rclone"
fi
if [ -z "$RCLONE_BIN" ] && [ $SKIP_UPLOAD -eq 0 ]; then
    err "rclone nao encontrado. Baixe em rclone.org ou use --skip-upload"; exit 1
fi

# ── Checa vercel CLI ───────────────────────────────────────────
if [ $SKIP_VERCEL -eq 0 ] && ! command -v vercel >/dev/null 2>&1; then
    err "vercel CLI nao encontrado. Rode: npm i -g vercel"; exit 1
fi

# ── Valida que PCK existe ──────────────────────────────────────
if [ ! -f index.pck ]; then
    err "index.pck nao encontrado. Re-exporte do Godot primeiro."; exit 1
fi

PCK_SIZE=$(du -h index.pck | awk '{print $1}')
log "═══════════════════════════════════════════════════════════════"
log "Deploy Web Lumera — PCK: $PCK_SIZE"
log "═══════════════════════════════════════════════════════════════"

# ── 1. rclone → R2 ─────────────────────────────────────────────
if [ $SKIP_UPLOAD -eq 0 ]; then
    log "[1/3] Subindo index.pck pro R2..."
    "$RCLONE_BIN" copy index.pck r2:lumera-assets -P
    ok "    R2 sincronizado"
else
    log "[1/3] --skip-upload: pulando rclone"
fi

# ── 2. apply-customizations.sh ─────────────────────────────────
log "[2/3] Reaplicando customizacoes no index.html..."
./apply-customizations.sh
ok "    HTML customizado (GODOT_PCK_URL + mainPack injetados)"

# ── 3. vercel --prod ───────────────────────────────────────────
if [ $SKIP_VERCEL -eq 0 ]; then
    log "[3/3] Deploy Vercel (--prod)..."
    vercel --prod
    ok "    Vercel publicado"
else
    log "[3/3] --skip-vercel: pulando deploy"
fi

ok "═══════════════════════════════════════════════════════════════"
ok "Deploy web completo!"
ok "═══════════════════════════════════════════════════════════════"
