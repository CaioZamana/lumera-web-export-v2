#!/usr/bin/env bash
# Reaplica customizacoes no index.html apos re-export do Godot.
# Godot sobrescreve index.html com template default, apagando:
#   1. const GODOT_PCK_URL = "..."
#   2. "mainPack": GODOT_PCK_URL no GODOT_CONFIG
# Este script detecta se o arquivo esta cru e reinjeta as linhas.
# Depois chama update-pck-version.sh pra preencher o ETag atual do R2.
# Idempotente: seguro rodar varias vezes.
set -euo pipefail

HTML="index.html"
PCK_URL="https://pub-932401cb337444cf95fc203c447835ce.r2.dev/index.pck"

if [ ! -f "$HTML" ]; then
  echo "ERRO: $HTML nao encontrado. Rode este script na pasta lumera-web-export-v2/." >&2
  exit 1
fi

if grep -q "const GODOT_PCK_URL" "$HTML"; then
  echo "index.html ja customizado — pulando injecao."
else
  echo "index.html cru detectado — reaplicando customizacao..."

  # 1. Injeta linha GODOT_PCK_URL antes do GODOT_CONFIG
  sed -i "s|^const GODOT_CONFIG = |const GODOT_PCK_URL = \"${PCK_URL}?v=PLACEHOLDER\";\nconst GODOT_CONFIG = |" "$HTML"

  # 2. Adiciona "mainPack":GODOT_PCK_URL no final do objeto GODOT_CONFIG (antes do };)
  #    Godot gera GODOT_CONFIG numa linha so, terminando com '};'
  sed -i 's|^\(const GODOT_CONFIG = {.*\)};$|\1,"mainPack":GODOT_PCK_URL};|' "$HTML"

  # Valida que ambas as alteracoes foram aplicadas
  if ! grep -q "const GODOT_PCK_URL" "$HTML"; then
    echo "ERRO: falha ao injetar GODOT_PCK_URL" >&2
    exit 1
  fi
  if ! grep -q '"mainPack":GODOT_PCK_URL' "$HTML"; then
    echo "ERRO: falha ao injetar mainPack no GODOT_CONFIG" >&2
    exit 1
  fi

  echo "OK — customizacao reaplicada."
fi

# Preenche o ETag atual do R2
./update-pck-version.sh
