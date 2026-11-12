#!/usr/bin/env bash
# pb-run.sh - inicia o Point Blank (Zepetto BR) sob Wine.
#
# Instalado por instalar.sh em ~/.local/share/pb/pb-run.sh.
# Pode ser chamado pelo atalho da area de trabalho ou direto.
#
# Variaveis:
#   PB_GAME_DIR     pasta do jogo (default: ~/.wine-pb/drive_c/PointBlank)
#   PB_BACKEND      dxvk (default) | wined3d
set -u

LOCAL="$HOME/.local/share/pb"
PREFIX="$HOME/.wine-pb"
WINE="$LOCAL/wine-tls/bin/wine"
LOG="$LOCAL/ultima-execucao.log"
BRIDGE_PORT=8443

fatal() {
  command -v zenity >/dev/null && zenity --error --title="Point Blank" --text="$1" --width=460 2>/dev/null
  echo "ERRO: $1" >&2
  exit 1
}

[ -x "$WINE" ] || fatal "Wine corrigido nao encontrado em $WINE.
Rode o instalador novamente."
[ -d "$PREFIX" ] || fatal "Prefixo Wine nao encontrado em $PREFIX.
Rode o instalador novamente."

GAME="${PB_GAME_DIR:-}"
if [ -z "$GAME" ]; then
  GAME=$(readlink -f "$PREFIX/drive_c/PointBlank" 2>/dev/null)
fi
[ -n "$GAME" ] && [ -f "$GAME/PBLauncher.exe" ] || fatal \
  "Jogo nao encontrado. Ajuste PB_GAME_DIR ou rode o instalador."

export WINEPREFIX="$PREFIX"
export WINEDEBUG=-all
export PULSE_LATENCY_MSEC=60

if [ "${PB_BACKEND:-dxvk}" = "wined3d" ]; then
  unset WINEDLLOVERRIDES
else
  export WINEDLLOVERRIDES="d3d11,dxgi,d3d10core=n,b"
fi

# ---- ponte HTTP->HTTPS (patch server) -------------------------------------
bridge_up() { ss -ltn 2>/dev/null | grep -q ":$BRIDGE_PORT "; }

if ! bridge_up; then
  if systemctl is-enabled --quiet pb-bridge 2>/dev/null; then
    # tenta subir sem senha; se precisar, pede pelo PolicyKit (janela grafica)
    systemctl start pb-iptables pb-bridge 2>/dev/null || \
      pkexec bash -c 'systemctl start pb-iptables pb-bridge' 2>/dev/null || true
  else
    # instalacao sem systemd: sobe ponte + regras na hora, com sudo
    if sudo -n true 2>/dev/null; then
      sudo "$LOCAL/iptables-pb.sh" >>"$LOG" 2>&1 || true
      sudo -b python3 "$LOCAL/pb-bridge.py" >>"$LOG" 2>&1 || true
    else
      zenity --question --title="Point Blank" --width=420 \
        --text="A ponte do patch server precisa de permissao de administrador.<br>Autorizar agora?" \
        2>/dev/null || fatal "Sem a ponte o launcher nao consegue baixar o patch."
      pkexec bash -c "\"$LOCAL/iptables-pb.sh\" && (setsid python3 \"$LOCAL/pb-bridge.py\" >/dev/null 2>&1 &)" 2>/dev/null || true
    fi
  fi
  sleep 2
  bridge_up || fatal "A ponte HTTP->HTTPS nao subiu (porta $BRIDGE_PORT).
Veja: journalctl -u pb-bridge -n 50"
fi

cd "$GAME" || fatal "Nao consegui entrar em $GAME"
: > "$LOG"
{
  echo "== $(date '+%F %T') backend=${PB_BACKEND:-dxvk} wine=$("$WINE" --version 2>/dev/null)"
} >>"$LOG"

exec "$WINE" 'C:\PointBlank\PBLauncher.exe' >>"$LOG" 2>&1
