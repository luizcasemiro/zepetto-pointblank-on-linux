#!/usr/bin/env bash
# desinstalar.sh - remove o que o instalar.sh criou.
#
# Não apaga a pasta do jogo sem confirmar. Uso: ./desinstalar.sh
set -u
LOCAL="$HOME/.local/share/pb"
PREFIX="${PB_PREFIX:-$HOME/.wine-pb}"
DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")"
APPS="$HOME/.local/share/applications"

ui_sim() { zenity --question --title="Desinstalar Point Blank" --width=520 --text="$1" 2>/dev/null; }
ui_info(){ zenity --info --title="Desinstalar Point Blank" --width=520 --text="$1" 2>/dev/null; }

SUDO_PASS=""
sudo_init() {
  SUDO_PASS=$(zenity --password --title="Desinstalar Point Blank" \
    --text="Senha do sudo para remover o serviço da ponte:" 2>/dev/null) || return 1
  printf '%s\n' "$SUDO_PASS" | sudo -S -k -p '' true 2>/dev/null
}
sudo_do() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@" 2>/dev/null; }

ui_sim "Remover a instalação do <b>Point Blank (Wine)</b>?

Isso remove:
  • atalhos (área de trabalho + menu)
  • serviço e regras da ponte
  • scripts em ~/.local/share/pb (inclui o Wine corrigido, ~1,4 GB)
  • o prefixo Wine (~2,4 GB)

<b>A pasta do jogo não é apagada</b> (perguntada no final)." || exit 0

# atalhos
rm -f "$DESKTOP_DIR/point-blank.desktop" "$APPS/point-blank.desktop"

# serviços
if systemctl list-unit-files 2>/dev/null | grep -q '^pb-bridge.service'; then
  if sudo_init; then
    sudo_do systemctl disable --now pb-bridge pb-iptables
    sudo_do rm -f /etc/systemd/system/pb-bridge.service /etc/systemd/system/pb-iptables.service
    sudo_do systemctl daemon-reload
    sudo_do iptables -t nat -D OUTPUT -p tcp --dport 443 -m owner --uid-owner 0 -j RETURN
    for ip in 103.88.232.101 201.77.235.23; do
      sudo_do iptables -t nat -D OUTPUT -p tcp -d "$ip" --dport 443 -j REDIRECT --to-ports 8443
    done
  else
    ui_info "Sem a senha do sudo, o serviço <b>pb-bridge</b> continua instalado.
Rode depois: sudo systemctl disable --now pb-bridge pb-iptables"
  fi
fi

# prefixo e wine
if [ -d "$PREFIX" ]; then
  ui_sim "Apagar o prefixo Wine em <b>$PREFIX</b> (~2,4 GB)?
(contém só o ambiente do jogo; a pasta do jogo fica intacta)" \
    && rm -rf "$PREFIX"
fi

if [ -d "$LOCAL/wine-tls" ]; then
  ui_sim "Apagar o Wine corrigido em <b>$LOCAL/wine-tls</b> (~1,4 GB)?" \
    && rm -rf "$LOCAL/wine-tls"
fi

# pasta do jogo
GAME=$(readlink -f "$PREFIX/drive_c/PointBlank" 2>/dev/null)
if [ -n "$GAME" ] && [ -d "$GAME" ]; then
  if ui_sim "Apagar também os arquivos do jogo em <b>$GAME</b> (~14 GB)?"; then
    rm -rf "$GAME"
  fi
fi

ui_info "Desinstalação concluída."
