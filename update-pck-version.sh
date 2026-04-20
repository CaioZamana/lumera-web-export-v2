#!/usr/bin/env bash
# Atualiza o GODOT_PCK_URL no index.html com o ETag atual do pck no R2.
# Força cache-busting no browser: cada pck novo vira uma URL nova (?v=<etag>).
# Rodar APÓS subir o pck pro R2 e ANTES do commit+deploy.
set -euo pipefail

PCK_URL="https://pub-932401cb337444cf95fc203c447835ce.r2.dev/index.pck"
HTML="index.html"

ETAG=$(curl -sI "$PCK_URL" | tr -d '\r' | awk -F'"' 'tolower($1) ~ /^etag:/ {print $2}')

if [ -z "$ETAG" ]; then
  echo "ERRO: não consegui ler o ETag de $PCK_URL" >&2
  exit 1
fi

sed -i "s|const GODOT_PCK_URL = \".*\"|const GODOT_PCK_URL = \"${PCK_URL}?v=${ETAG}\"|" "$HTML"

echo "OK — GODOT_PCK_URL atualizado com ?v=$ETAG"
