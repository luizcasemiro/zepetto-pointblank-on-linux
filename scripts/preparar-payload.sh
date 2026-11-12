#!/usr/bin/env bash
# preparar-payload.sh - baixa/gera os binários que o instalar.sh precisa.
#
# O repositório não distribui binários grandes (Wine compilado, WebView2) nem
# arquivos do jogo. Este script monta o payload localmente.
set -uo pipefail
BASE="$(cd "$(dirname "$0")/.." && pwd)"
PAYLOAD="$BASE/payload"
mkdir -p "$PAYLOAD"

log() { printf '%s\n' "$*"; }

# ---------------------------------------------------------------- WebView2
wv="$PAYLOAD/MicrosoftEdgeWebView2RuntimeInstallerX64.exe"
if [ -f "$wv" ]; then
  log "WebView2: já presente"
else
  log "WebView2: baixando da Microsoft (~140 MB)"
  curl -L --retry 3 -o "$wv" 'https://go.microsoft.com/fwlink/p/?LinkId=2124703' \
    || { log "FALHOU. Baixe manualmente em https://developer.microsoft.com/microsoft-edge/webview2/"; exit 1; }
fi

# -------------------------------------------------------------------- DXVK
if [ -f "$PAYLOAD/dxvk-1.10.3-x32.tar.xz" ]; then
  log "DXVK: já presente"
else
  log "DXVK 1.10.3: baixando (v1.10.3 é a última que funciona com Vulkan 1.2 do Wine 9)"
  tmp=$(mktemp -d)
  curl -L --retry 3 -o "$tmp/dxvk.tar.gz" \
    https://github.com/doitsujin/dxvk/releases/download/v1.10.3/dxvk-1.10.3.tar.gz \
    || { log "FALHOU ao baixar o DXVK"; rm -rf "$tmp"; exit 1; }
  tar -xzf "$tmp/dxvk.tar.gz" -C "$tmp"
  tar -cJf "$PAYLOAD/dxvk-1.10.3-x32.tar.xz" -C "$tmp/dxvk-1.10.3/x32" .
  rm -rf "$tmp"
fi

# --------------------------------------------------------- Wine com patches
if [ -f "$PAYLOAD/wine-tls.tar.xz" ]; then
  log "Wine corrigido: já presente ($(du -h "$PAYLOAD/wine-tls.tar.xz" | cut -f1))"
else
  log "Wine corrigido: AUSENTE."
  log ""
  log "  O tarball tem ~250 MB e é específico para glibc/X11 da sua distro."
  log "  Gere com:  ./scripts/construir-wine.sh"
  log "  (precisa de toolchain: gcc-multilib, mingw i686/x86_64, bison, flex,"
  log "   libfreetype-dev, libx11-dev, libxext-dev, libxrender-dev...)"
fi

log ""
log "Payload pronto em $PAYLOAD"
ls -lh "$PAYLOAD" 2>/dev/null | grep -v '^total'
