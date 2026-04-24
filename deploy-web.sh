#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# Deploy Web Lumera — R2 (PCK) + Vercel (HTML/JS/WASM)
#
# Uso:
#   ./deploy-web.sh                # deploy completo (pausa no final pra ver logs)
#   ./deploy-web.sh --skip-upload  # pula rclone (PCK ja tá no R2)
#   ./deploy-web.sh --skip-vercel  # só atualiza HTML local + R2
#   ./deploy-web.sh --no-pause     # nao pausa no final (util pra CI/encadear)
#
# Faz:
#   1. Upload index.pck pro R2 via rclone (idempotente)
#   2. Reaplica GODOT_PCK_URL + mainPack no index.html com ETag atual
#   3. Deploy no Vercel (--prod)
#
# Requisitos:
#   - Git Bash (NAO PowerShell — precisa de sed/curl/bash)
#   - rclone em ../rclone-*/rclone ou no PATH (configurado com remote 'r2')
#   - vercel CLI no PATH (npm i -g vercel)
#   - Rodar de dentro de lumera-web-export-v2/
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

PCK_URL="https://pub-932401cb337444cf95fc203c447835ce.r2.dev/index.pck"
VERCEL_URL="https://lumera-rpg-online-v02.vercel.app"

SKIP_UPLOAD=0
SKIP_VERCEL=0
NO_PAUSE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-upload) SKIP_UPLOAD=1 ;;
        --skip-vercel) SKIP_VERCEL=1 ;;
        --no-pause)    NO_PAUSE=1 ;;
        -h|--help)     sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "flag desconhecida: $1" >&2; exit 1 ;;
    esac
    shift
done

log()    { printf '\033[36m[%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$1"; }
ok()     { printf '\033[32m[%s] ✓ %s\033[0m\n' "$(date +%H:%M:%S)" "$1"; }
info()   { printf '\033[90m         %s\033[0m\n' "$1"; }
warn()   { printf '\033[33m[%s] ! %s\033[0m\n' "$(date +%H:%M:%S)" "$1"; }
err()    { printf '\033[31m[%s] ✗ %s\033[0m\n' "$(date +%H:%M:%S)" "$1" >&2; }
banner() { printf '\033[36m═══════════════════════════════════════════════════════════════\033[0m\n'; }

# ── Etapa atual (usada pelo trap ERR pra dar dica contextual) ──
CURRENT_STAGE="init"
error_hint() {
    printf '\n'
    err "Falhou na etapa: $CURRENT_STAGE"
    case "$CURRENT_STAGE" in
        preflight)
            info "Alguma dependencia faltando. Veja mensagem acima."
            info "Rclone: baixar de rclone.org e configurar remote 'r2' (rclone config)"
            info "Vercel: npm i -g vercel && vercel login"
            ;;
        rclone)
            info "Upload pro R2 falhou. Possiveis causas:"
            info "  - Remote 'r2' nao configurado:  rclone config show r2"
            info "  - Credenciais expiradas:         rclone config reconnect r2:"
            info "  - Bucket 'lumera-assets' inexistente no Cloudflare dashboard"
            info "  - Sem internet / firewall bloqueando api.cloudflare.com"
            info "Alternativa manual: wrangler r2 object put lumera-assets/index.pck --file=./index.pck --remote"
            ;;
        apply-custom)
            info "Injecao de GODOT_PCK_URL/mainPack no index.html falhou."
            info "Checar manualmente:  grep 'GODOT_PCK_URL\\|mainPack' index.html"
            info "Se estiver cru, rode:  ./apply-customizations.sh"
            info "Se update-pck-version.sh falhou, ETag nao foi lido do R2 —"
            info "  confirme que PCK subiu:  curl -sI $PCK_URL | head"
            ;;
        vercel)
            info "Deploy no Vercel falhou. Checar:"
            info "  - vercel whoami  (esta logado?)"
            info "  - .vercel/project.json existe? (vercel link se nao)"
            info "  - vercel --prod --debug  (log detalhado)"
            info "HTML local ja foi customizado — pode tentar:  vercel --prod"
            ;;
    esac
}

pause_on_exit() {
    local code=$?
    if [ $code -ne 0 ]; then error_hint; fi
    if [ $NO_PAUSE -eq 0 ]; then
        printf '\n'
        read -r -p "Pressione ENTER pra fechar... " _ || true
    fi
    exit $code
}
trap pause_on_exit EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ═══════════════════════════════════════════════════════════════
# Preflight: valida dependencias
# ═══════════════════════════════════════════════════════════════
CURRENT_STAGE="preflight"
banner
log "Preflight — validando dependencias"
banner

# Localiza rclone (binario local primeiro, depois PATH)
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
ok "rclone encontrado"
info "binario: ${RCLONE_BIN:-N/A (--skip-upload)}"

# Checa vercel CLI
if [ $SKIP_VERCEL -eq 0 ]; then
    if ! command -v vercel >/dev/null 2>&1; then
        err "vercel CLI nao encontrado. Rode: npm i -g vercel"; exit 1
    fi
    ok "vercel CLI encontrado"
    info "versao: $(vercel --version 2>/dev/null || echo desconhecida)"
fi

# Valida que PCK existe e tem tamanho razoavel
if [ ! -f index.pck ]; then
    err "index.pck nao encontrado. Re-exporte do Godot primeiro."
    info "Godot: Project → Export → Web → Export Project → salvar nesta pasta"
    exit 1
fi
PCK_SIZE=$(du -h index.pck | awk '{print $1}')
PCK_BYTES=$(wc -c < index.pck | tr -d ' ')
ok "index.pck presente"
info "tamanho: $PCK_SIZE ($PCK_BYTES bytes)"

if [ "$PCK_BYTES" -lt 1000000 ]; then
    warn "PCK suspeito — menor que 1MB. Export do Godot pode estar incompleto."
fi

# ═══════════════════════════════════════════════════════════════
# 1/3 — rclone → R2
# ═══════════════════════════════════════════════════════════════
banner
if [ $SKIP_UPLOAD -eq 0 ]; then
    CURRENT_STAGE="rclone"
    log "[1/3] Upload index.pck → Cloudflare R2"
    info "destino: r2:lumera-assets/index.pck"
    info "rclone e idempotente — se o PCK ja for identico no R2, reporta 0 B"
    banner
    "$RCLONE_BIN" copy index.pck r2:lumera-assets -P
    ok "R2 sincronizado"
    info "URL publica: $PCK_URL"
else
    log "[1/3] --skip-upload: pulando rclone"
fi

# ═══════════════════════════════════════════════════════════════
# 2/3 — apply-customizations.sh
# ═══════════════════════════════════════════════════════════════
banner
CURRENT_STAGE="apply-custom"
log "[2/3] Customizando index.html (GODOT_PCK_URL + mainPack)"
info "Godot sobrescreve o HTML a cada export — este script reinjeta."
info "Roda update-pck-version.sh no final pra cache-bust via ETag atual do R2."
banner
./apply-customizations.sh

# Verificacao pos-execucao: mostra o ETag injetado
ETAG_INJECTED=$(grep -oE 'GODOT_PCK_URL = "[^"]*"' index.html | grep -oE 'v=[^"]*' | head -1 || true)
if [ -z "$ETAG_INJECTED" ]; then
    err "Customizacao falhou — GODOT_PCK_URL nao encontrado no index.html"
    exit 1
fi
if ! grep -q '"mainPack":GODOT_PCK_URL' index.html; then
    err "Customizacao parcial — mainPack nao foi injetado no GODOT_CONFIG"
    exit 1
fi
ok "HTML customizado"
info "cache-bust: $ETAG_INJECTED"
info "mainPack injetado no GODOT_CONFIG: sim"

# ═══════════════════════════════════════════════════════════════
# 3/3 — vercel --prod
# ═══════════════════════════════════════════════════════════════
banner
if [ $SKIP_VERCEL -eq 0 ]; then
    CURRENT_STAGE="vercel"
    log "[3/3] Deploy Vercel (--prod)"
    info "PCK NAO vai junto (.vercelignore exclui) — browser busca no R2."
    info "Output do Vercel abaixo:"
    banner
    vercel --prod
    ok "Vercel publicado"
else
    log "[3/3] --skip-vercel: pulando deploy"
fi

# ═══════════════════════════════════════════════════════════════
# Sucesso — orientacoes pos-deploy
# ═══════════════════════════════════════════════════════════════
CURRENT_STAGE="done"
printf '\n'
banner
ok "Deploy web completo!"
banner
printf '\n'
info "URLs:"
info "  Jogo:   $VERCEL_URL"
info "  PCK:    $PCK_URL?$ETAG_INJECTED"
printf '\n'
info "Validacao manual (recomendado):"
info "  1. Abrir $VERCEL_URL em aba anonima (evita cache local)"
info "  2. DevTools → Network → filtrar 'index.pck'"
info "     - Status: 200 (vindo do R2, nao do Vercel)"
info "     - Size:   ~$PCK_SIZE"
info "  3. Jogo deve carregar ate a tela de login"
printf '\n'
info "Se jogador reportar versao antiga apos deploy:"
info "  - Ctrl+Shift+R forca reload sem cache"
info "  - Se persistir, o ETag nao mudou — rodou rclone? PCK era identico?"
printf '\n'
