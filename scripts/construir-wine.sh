#!/usr/bin/env bash
# construir-wine.sh - compila o Wine 9.0 com os dois patches do projeto e
# empacota o resultado em payload/wine-tls.tar.xz.
#
# Por que compilar: o Wine 9.0 entrega o bloco TLS alinhado a 8 bytes no 32-bit
# (o Windows garante 16) e o ScriptTextOut não inicializa um SCRIPT_CACHE vazio.
# Os dois patches estão em payload/patches/.
#
# Requisitos (Debian/Mint):
#   sudo apt install build-essential gcc-multilib g++-multilib bison flex \
#        libfreetype-dev libx11-dev libxext-dev libxrender-dev libxrandr-dev \
#        libxfixes-dev libxi-dev libxcursor-dev libxinerama-dev libxcomposite-dev \
#        libfontconfig-dev libglu1-mesa-dev libosmesa6-dev libpcap-dev \
#        libdbus-1-dev libgnutls28-dev libkrb5-dev libcups2-dev libvulkan-dev \
#        libsdl2-dev libudev-dev libxml2-dev libxslt1-dev libpng-dev \
#        mingw-w64 gcc-mingw-w64-i686 gcc-mingw-w64-x86-64
#
# Uso:  ./scripts/construir-wine.sh [versao]
set -euo pipefail
BASE="$(cd "$(dirname "$0")/.." && pwd)"
PATCHES="$BASE/payload/patches"
OUT="$BASE/payload/wine-tls.tar.xz"
VER="${1:-9.0}"
WORK="${WORK:-/tmp/wine-build-${VER}}"
SRC="$WORK/wine-${VER}"
JOBS="$(nproc)"

echo "== Wine $VER em $WORK"
mkdir -p "$WORK"
if [ ! -d "$SRC" ]; then
  if [ ! -f "$WORK/wine-${VER}.tar.xz" ]; then
    echo "== baixando fonte do Wine $VER"
    curl -L --retry 3 -o "$WORK/wine-${VER}.tar.xz" \
      "https://dl.winehq.org/wine/source/${VER%%.*}.0/wine-${VER}.tar.xz"
  fi
  tar -xJf "$WORK/wine-${VER}.tar.xz" -C "$WORK"
fi

cd "$SRC"
echo "== aplicando patches"
for p in "$PATCHES"/0*.patch; do
  echo "   $(basename "$p")"
  patch -p1 --forward < "$p"
done

echo "== configurando (wow64 novo: i386 + x86_64)"
if [ ! -f config.status ]; then
  ./configure --enable-archs=i386,x86_64 --prefix=/opt/wine16
fi

echo "== compilando com $JOBS jobs (1ª vez: ~30-60 min)"
make -j"$JOBS" >/tmp/wine-build.log 2>&1 || {
  echo "FALHOU — veja /tmp/wine-build.log"; tail -20 /tmp/wine-build.log; exit 1;
}

echo "== instalando em staging"
rm -rf "$WORK/stage"
make install DESTDIR="$WORK/stage" >/tmp/wine-install.log 2>&1

echo "== empacotando $OUT"
rm -rf "$WORK/pack"
mkdir -p "$WORK/pack"
cp -a "$WORK/stage/opt/wine16" "$WORK/pack/wine-tls"
tar -C "$WORK/pack" -I 'xz -T0 -6' -cf "$OUT" wine-tls
ls -lh "$OUT"
echo "== pronto. Rode ./instalar.sh"
