#!/usr/bin/env bash
# instalar.sh - Instalador do Point Blank (Zepetto BR) para Linux/Wine.
#
# Faz tudo: instala o Wine corrigido (TLS + texto), cria o prefixo, instala o
# WebView2, roda o instalador oficial do jogo numa pasta escolhida, aplica DXVK
# + patch, configura a ponte HTTP->HTTPS do patch server, fontes, configuracao
# grafica e cria o atalho na area de trabalho.
#
# Uso:  ./instalar.sh
#
# Requisitos: zenity, python3, xz, iptables, systemd (opcional), sudo.
set -uo pipefail

BASE="$(cd "$(dirname "$0")" && pwd)"
PAYLOAD="$BASE/payload"
RUNTIME="$BASE/runtime"
TEMPLATES="$BASE/templates"

LOCAL="$HOME/.local/share/pb"
PREFIX="${PB_PREFIX:-$HOME/.wine-pb}"
WINE="$LOCAL/wine-tls/bin/wine"
APPS="$HOME/.local/share/applications"
DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")"

LOG="$LOCAL/instalacao.log"
mkdir -p "$LOCAL"
: > "$LOG"

# ---------------------------------------------------------------- utilidades
titulo="Instalador Point Blank"

log()  { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG" >&2; }
passo(){ log "== $*"; }

ui_info()  { zenity --info  --title="$titulo" --width=520 --text="$1" 2>/dev/null; }
ui_erro()  { zenity --error --title="$titulo" --width=560 --text="$1" 2>/dev/null; }
ui_aviso() { zenity --warning --title="$titulo" --width=560 --text="$1" 2>/dev/null; }
ui_sim()   { zenity --question --title="$titulo" --width=480 --text="$1" 2>/dev/null; }
ui_texto() { zenity --text-info --title="$titulo" --width=760 --height=460 --filename="$1" 2>/dev/null; }

ui_arquivo_exe() {
  zenity --file-selection --title="Selecione o instalador do Point Blank (.exe)" \
         --file-filter="Instalador do Point Blank (*.exe)|*.exe" \
         --file-filter="Todos os arquivos|*" 2>/dev/null
}

ui_pasta() {
  zenity --file-selection --directory --title="Escolha a pasta de destino do jogo" \
         --filename="${1:-$HOME/}" 2>/dev/null
}

# modo silencioso (PB_SILENCIOSO=1) para automacao/teste: sem Zenity,
# usando PB_EXE / PB_DEST / PB_SENHA
if [ "${PB_SILENCIOSO:-0}" = "1" ]; then
  ui_info()  { log "INFO: $(printf '%s' "$1" | sed 's/<[^>]*>//g; s|\\n| |g')"; }
  ui_erro()  { log "ERRO: $(printf '%s' "$1" | sed 's/<[^>]*>//g; s|\\n| |g')"; }
  ui_aviso() { log "AVISO: $(printf '%s' "$1" | sed 's/<[^>]*>//g; s|\\n| |g')"; }
  ui_sim()   { return 0; }
  ui_texto() { cat "$1" >&2 2>/dev/null; }
  ui_arquivo_exe() { echo "${PB_EXE:-}"; }
  ui_pasta()       { echo "${PB_DEST:-}"; }
  ui_ocupado() { local t="$1"; shift; log "$t"; "$@" >>"$LOG" 2>&1; }
fi

# roda um comando mostrando um dialogo "ocupado" (pulsate) que fecha ao terminar
ui_ocupado() {
  local texto="$1"; shift
  local saida="$LOCAL/saida-$(date +%s%N).log"
  "$@" >>"$saida" 2>&1 &
  local pid=$!
  ( while kill -0 "$pid" 2>/dev/null; do sleep 0.5; done ) |
    zenity --progress --pulsate --title="$titulo" --text="$texto" \
           --no-cancel --auto-close 2>/dev/null
  wait "$pid"; local rc=$?
  cat "$saida" >>"$LOG" 2>/dev/null
  rm -f "$saida"
  return $rc
}

erro_fatal() {
  log "ERRO: $*"
  ui_erro "<b>Falhou:</b> $1\n\nDetalhes no log:\n$LOG"
  exit 1
}

# ------------------------------------------------------------------- sudo
SUDO_PASS=""
sudo_init() {
  if [ -n "${PB_SENHA:-}" ]; then
    if printf '%s\n' "$PB_SENHA" | sudo -S -k -p '' true 2>/dev/null; then
      SUDO_PASS="$PB_SENHA"
      printf '%s\n' "$SUDO_PASS" | sudo -S -p '' -v 2>/dev/null
      return 0
    fi
    log "senha de sudo invalida"
    return 1
  fi
  local tentativas=0
  while [ $tentativas -lt 3 ]; do
    SUDO_PASS=$(zenity --password --title="$titulo" \
      --text="O instalador precisa de administrador para:\n\n• redirecionar a porta 443 do patch server (iptables)\n• instalar o servico da ponte\n\nSenha do sudo:" 2>/dev/null) || return 1
    if printf '%s\n' "$SUDO_PASS" | sudo -S -k -p '' true 2>/dev/null; then
      printf '%s\n' "$SUDO_PASS" | sudo -S -p '' -v 2>/dev/null
      return 0
    fi
    tentativas=$((tentativas+1))
    ui_aviso "Senha incorreta (tentativa $tentativas de 3)."
  done
  return 1
}
sudo_do() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@" 2>>"$LOG"; }

# --------------------------------------------------------- checagens iniciais
checar_dependencias() {
  local falta=()
  for c in zenity python3 tar xz getent; do
    command -v "$c" >/dev/null || falta+=("$c")
  done
  [ ${#falta[@]} -eq 0 ] || erro_fatal "Faltam programas: ${falta[*]}.
No Linux Mint: sudo apt install ${falta[*]}"
  if [ ! -f "$PAYLOAD/wine-tls.tar.xz" ] && [ ! -x "$WINE" ]; then
    erro_fatal "Falta o Wine corrigido (payload/wine-tls.tar.xz).

Duas opções:
  • rode ./scripts/preparar-payload.sh  (baixa o necessário)
  • ou ./scripts/construir-wine.sh      (compila do fonte com os patches)
Veja o README."
  fi
}

# --------------------------------------------------------------- 1. payload
instalar_wine() {
  if [ -x "$WINE" ] && "$WINE" --version >/dev/null 2>&1; then
    passo "Wine corrigido já instalado em $LOCAL/wine-tls"
    return 0
  fi
  passo "Extraindo Wine 9.0 corrigido (TLS 16-alinhado + ScriptTextOut)"
  mkdir -p "$LOCAL"
  ui_ocupado "Instalando o Wine corrigido (~1,4 GB)..." \
    tar -xJf "$PAYLOAD/wine-tls.tar.xz" -C "$LOCAL" \
    || erro_fatal "Não consegui extrair o Wine."
  [ -x "$WINE" ] || erro_fatal "Wine extraído, mas $WINE não existe."
}

# ---------------------------------------------------------------- 2. prefixo
criar_prefixo() {
  export WINEPREFIX="$PREFIX"
  if [ -d "$PREFIX" ]; then
    if ui_sim "Já existe um prefixo Wine em:\n<b>$PREFIX</b>\n\nReutilizar? (recomendado)\n\nEscolha <i>No</i> para recriar do zero (o antigo é preservado como .bak)."; then
      passo "Reutilizando prefixo existente"
    else
      local bak="$PREFIX.bak-$(date +%Y%m%d-%H%M%S)"
      passo "Movendo prefixo antigo para $bak"
      mv "$PREFIX" "$bak" || erro_fatal "Não consegui mover o prefixo antigo."
    fi
  fi
  if [ ! -d "$PREFIX" ]; then
    passo "Criando prefixo Wine"
    ui_ocupado "Criando o prefixo Wine..." "$WINE" wineboot -u \
      || erro_fatal "wineboot falhou."
    "$WINE" reg add 'HKCU\Software\Wine' /v Version /d win10 /f >>"$LOG" 2>&1
  fi
}

# ---------------------------------------------------------------- 3. webview2
instalar_webview2() {
  local appdir="$PREFIX/drive_c/Program Files (x86)/Microsoft/EdgeWebView/Application"
  if [ -d "$appdir" ]; then
    passo "WebView2 já presente em $appdir"
    return 0
  fi
  passo "Instalando WebView2 (necessário para o launcher)"
  local wv="$PAYLOAD/MicrosoftEdgeWebView2RuntimeInstallerX64.exe"
  if [ ! -f "$wv" ]; then
    wv="$LOCAL/MicrosoftEdgeWebView2RuntimeInstallerX64.exe"
    if [ ! -f "$wv" ]; then
      passo "WebView2 não está no payload; baixando da Microsoft"
      ui_ocupado "Baixando o WebView2 Runtime (~140 MB)..." \
        curl -L --retry 3 -o "$wv" 'https://go.microsoft.com/fwlink/p/?LinkId=2124703' \
        || erro_fatal "Não consegui baixar o WebView2. Baixe manualmente em
https://developer.microsoft.com/microsoft-edge/webview2/ e salve como
$PAYLOAD/MicrosoftEdgeWebView2RuntimeInstallerX64.exe"
    fi
  fi
  ui_ocupado "Instalando o WebView2 (pode levar alguns minutos)..." \
    "$WINE" "$wv" /silent /install \
    || true   # o instalador às vezes retorna != 0 mesmo funcionando
  for _ in $(seq 1 60); do
    [ -d "$appdir" ] && break
    sleep 5
  done
  [ -d "$appdir" ] || erro_fatal "WebView2 não instalou (o launcher não abre sem ele)."
}

# --------------------------------------------------------------- 4. o jogo
winepath_de() { printf 'Z:%s' "$(printf '%s' "$1" | sed 's|/|\\|g')"; }

instalar_jogo() {
  local exe="$1" dest="$2"
  export WINEPREFIX="$PREFIX"
  local link="$PREFIX/drive_c/PointBlank"

  if [ -f "$dest/PBLauncher.exe" ]; then
    passo "Jogo já instalado em $dest"
  else
    passo "Rodando o instalador oficial em $dest"
    local win_dest; win_dest="$(winepath_de "$dest")"
    ui_ocupado "Instalando o Point Blank em $dest...

Isso copia ~14 GB e pode demorar 10–30 minutos.
Não feche esta janela." \
      "$WINE" "$exe" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART \
              /DIR="$win_dest" /LOG='Z:\tmp\pb-setup.log' \
      || erro_fatal "O instalador do jogo retornou erro. Veja $LOG e Z:\\tmp\\pb-setup.log"
    [ -f "$dest/PBLauncher.exe" ] || erro_fatal \
      "O instalador terminou mas PBLauncher.exe não está em $dest.
Verifique se os 16 arquivos .bin estão na mesma pasta do .exe."
  fi

  passo "Ligando C:\\PointBlank -> $dest"
  ln -sfn "$dest" "$link"
}

# ------------------------------------------------------------------ 5. fontes
instalar_fontes() {
  local dest="$1"
  passo "Instalando fontes do jogo + alias de fontconfig"
  mkdir -p "$HOME/.local/share/fonts/pb"
  # as fontes vêm do próprio jogo instalado (não são redistribuídas)
  if [ -d "$dest/Font" ]; then
    find "$dest/Font" -maxdepth 1 -type f \( -iname '*.ttf' -o -iname '*.ttc' -o -iname '*.otf' \) \
      -exec cp -f {} "$HOME/.local/share/fonts/pb/" \; 2>>"$LOG"
    log "fontes copiadas de $dest/Font"
  else
    log "aviso: $dest/Font não existe; seguindo sem as fontes do jogo"
  fi
  local fc="$HOME/.config/fontconfig/fonts.conf"
  mkdir -p "$(dirname "$fc")"
  if [ -f "$fc" ] && grep -q "Point Blank" "$fc" 2>/dev/null; then
    log "fontconfig já configurado"
  else
    if [ -f "$fc" ]; then
      cp "$fc" "$fc.bak-$(date +%s)"
      # injeta o bloco antes do </fontconfig>
      python3 - "$fc" "$TEMPLATES/fonts.conf" <<'PY'
import sys, re
alvo, novo = sys.argv[1], sys.argv[2]
corpo = open(novo).read()
bloco = re.search(r'<fontconfig>(.*)</fontconfig>', corpo, re.S)
conteudo = bloco.group(1) if bloco else corpo
s = open(alvo).read()
s = s.replace('</fontconfig>', '<!-- Point Blank -->' + conteudo + '</fontconfig>')
open(alvo, 'w').write(s)
PY
    else
      cp "$TEMPLATES/fonts.conf" "$fc"
    fi
  fi
  fc-cache -f >>"$LOG" 2>&1 || true
}

# ------------------------------------------------------------------- 6. dxvk
instalar_dxvk() {
  local syswow="$PREFIX/drive_c/windows/syswow64"
  passo "Instalando DXVK 1.10.3 (32-bit) e aplicando o patch do command list nulo"
  tar -xJf "$PAYLOAD/dxvk-1.10.3-x32.tar.xz" -C "$syswow" >>"$LOG" 2>&1 \
    || erro_fatal "Não consegui extrair o DXVK."

  export WINEPREFIX="$PREFIX"
  for dll in d3d11 dxgi d3d10core; do
    "$WINE" reg add 'HKCU\Software\Wine\DllOverrides' /v "$dll" /d 'native,builtin' /f >>"$LOG" 2>&1
  done

  python3 "$PAYLOAD/patches/patch-dxvk-null-cmdlist.py" "$syswow/d3d11.dll" >>"$LOG" 2>&1 \
    || erro_fatal "Falha ao aplicar o patch do DXVK."
  # confere a assinatura do patch (call para a cave)
  local sig; sig=$(dd if="$syswow/d3d11.dll" bs=1 skip=$((0x2cae1)) count=5 2>/dev/null | od -An -tx1 | tr -d ' \n')
  [ "$sig" = "e8fb7a2200" ] || erro_fatal "Patch do DXVK não ficou aplicado (assinatura $sig)."
}

# ----------------------------------------------------- 7. ponte + servicos
instalar_runtime() {
  passo "Instalando scripts de execução em $LOCAL"
  install -m 0755 "$RUNTIME/pb-bridge.py"   "$LOCAL/pb-bridge.py"
  install -m 0755 "$RUNTIME/iptables-pb.sh" "$LOCAL/iptables-pb.sh"
  install -m 0755 "$RUNTIME/pb-run.sh"      "$LOCAL/pb-run.sh"
}

instalar_servicos() {
  passo "Instalando serviço da ponte HTTP->HTTPS"
  if ! command -v systemctl >/dev/null || [ ! -d /run/systemd/system ]; then
    log "systemd ausente — a ponte sobe sob demanda pelo pb-run.sh"
    return 0
  fi

  local py; py=$(command -v python3)
  sed -e "s|@@LOCAL@@|$LOCAL|g" -e "s|@@PYTHON@@|$py|g" \
      "$RUNTIME/systemd/pb-bridge.service.in" > /tmp/pb-bridge.service
  sed -e "s|@@LOCAL@@|$LOCAL|g" \
      "$RUNTIME/systemd/pb-iptables.service.in" > /tmp/pb-iptables.service

  sudo_do install -m 0644 /tmp/pb-bridge.service /etc/systemd/system/pb-bridge.service
  sudo_do install -m 0644 /tmp/pb-iptables.service /etc/systemd/system/pb-iptables.service
  rm -f /tmp/pb-bridge.service /tmp/pb-iptables.service
  sudo_do systemctl daemon-reload
  sudo_do systemctl enable pb-bridge pb-iptables >>"$LOG" 2>&1
  sudo_do systemctl restart pb-bridge >>"$LOG" 2>&1
  sudo_do systemctl restart pb-iptables >>"$LOG" 2>&1

  sleep 2
  if ss -ltn 2>/dev/null | grep -q ':8443 '; then
    passo "Ponte ativa em 127.0.0.1:8443"
  else
    log "aviso: ponte nao respondeu ainda; veja journalctl -u pb-bridge"
  fi
}

# ------------------------------------------------------------ 8. config .ini
tela_primaria() {
  local prim linha
  prim=$(xrandr 2>/dev/null | awk '/ connected primary/{print $1; exit}')
  [ -n "$prim" ] || { echo "1920 1080 60"; return; }
  linha=$(xrandr 2>/dev/null | awk -v o="$prim" '$1==o{f=1;next} f&&/\*/{print;exit}')
  [ -n "$linha" ] || { echo "1920 1080 60"; return; }
  local res hz
  res=$(echo "$linha" | awk '{print $1}')
  hz=$(echo "$linha" | awk '{for(i=2;i<=NF;i++) if($i ~ /\*/){gsub(/\*/,"",$i); print $i; exit}}')
  printf '%s %s %s\n' "${res%x*}" "${res#*x}" "${hz%.*}"
}

escrever_config() {
  local ini="$1/EnvSet/env_settings.ini"
  if [ -f "$ini" ]; then
    passo "Preservando configuração existente ($ini)"
    return 0
  fi
  passo "Escrevendo configuração gráfica inicial"
  read -r w h hz <<<"$(tela_primaria)"
  [ -n "${w:-}" ] || w=1920; [ -n "${h:-}" ] || h=1080; [ -n "${hz:-}" ] || hz=60
  sed -e "s|@@WIDTH@@|$w|g" -e "s|@@HEIGHT@@|$h|g" \
      -e "s|@@REFRESH@@|$hz|g" -e "s|@@FPS@@|120|g" \
      "$TEMPLATES/env_settings.ini" > "$ini" \
    || log "aviso: não consegui escrever $ini"
}

# ------------------------------------------------------------ 9. atalho
criar_atalho() {
  passo "Criando atalho na área de trabalho"
  local icon="$LOCAL/pb.png"
  if [ -f "$RUNTIME/pb.png" ]; then
    install -m 0644 "$RUNTIME/pb.png" "$icon"
  else
    icon="applications-games"
  fi

  local dt="$APPS/point-blank.desktop"
  mkdir -p "$APPS"
  sed -e "s|@@EXEC@@|$LOCAL/pb-run.sh|g" -e "s|@@ICON@@|$icon|g" \
      "$RUNTIME/pb.desktop.in" > "$dt"
  chmod 0755 "$dt"

  mkdir -p "$DESKTOP_DIR"
  install -m 0755 "$dt" "$DESKTOP_DIR/point-blank.desktop"
  # Nemo/Cinnamon exigem o selo de "confiavel"
  gio set "$DESKTOP_DIR/point-blank.desktop" metadata::trusted true 2>/dev/null || true
  update-desktop-database "$APPS" >/dev/null 2>&1 || true
  passo "Atalho: $DESKTOP_DIR/point-blank.desktop"
}

# ------------------------------------------------------------------ 10. main
main() {
  passo "===== instalacao iniciada ====="

  ui_info "<b>Instalador do Point Blank para Linux (Wine)</b>

O que vou fazer:
  • instalar o Wine 9.0 corrigido (TLS 16 bytes + texto)
  • criar um prefixo isolado em ~/.wine-pb
  • instalar o WebView2 (necessário ao launcher)
  • rodar o instalador oficial do jogo na pasta que você escolher
  • aplicar DXVK 1.10.3 + patch do command list
  • configurar a ponte do patch server (iptables + serviço)
  • criar o atalho na área de trabalho

Você vai precisar da senha do sudo (para o iptables e o serviço)." \
    || exit 0

  checar_dependencias

  # --- instalador oficial
  local exe; exe=$(ui_arquivo_exe) || exit 0
  [ -n "$exe" ] && [ -f "$exe" ] || erro_fatal "Instalador não selecionado."
  local dir_base; dir_base="$(dirname "$exe")"
  local padrao; padrao="$(basename "$exe" .exe)"
  local bins=( "$dir_base/$padrao"-*.bin )
  [ -e "${bins[0]}" ] || erro_fatal \
    "Não achei os volumes .bin ao lado do instalador.
Coloque o .exe e os 16 arquivos <b>$padrao-*.bin</b> na mesma pasta."
  log "instalador: $exe (+ $(ls "$dir_base/$padrao"-*.bin 2>/dev/null | wc -l) volumes .bin)"

  # --- destino
  local dest; dest=$(ui_pasta "$HOME/Games/PointBlank") || exit 0
  [ -n "$dest" ] || erro_fatal "Pasta de destino não selecionada."
  dest="${dest%/}"
  if [ "$dest" = "$HOME" ] || [ "$dest" = "/" ]; then
    erro_fatal "Escolha uma pasta específica (ex.: ~/Games/PointBlank), não $dest."
  fi
  mkdir -p "$dest" || erro_fatal "Não consegui criar $dest"
  [ -w "$dest" ] || erro_fatal "Sem permissão de escrita em $dest"

  # --- espaço (só o que ainda falta baixar/instalar)
  local livre_kb precisa_kb
  livre_kb=$(df -Pk "$dest" | awk 'NR==2{print $4}')
  precisa_kb=0
  [ -f "$dest/PBLauncher.exe" ] || precisa_kb=$(( 14 * 1024 * 1024 ))
  [ -d "$PREFIX" ]              || precisa_kb=$(( precisa_kb + 3 * 1024 * 1024 ))
  if [ "${PB_PULAR_ESPACO:-0}" != "1" ] && [ "$livre_kb" -lt "$precisa_kb" ]; then
    erro_fatal "Espaço insuficiente em $dest.
Livre: $((livre_kb/1024/1024)) GB — necessário: ~$((precisa_kb/1024/1024)) GB.
(Espaço extra pode ser liberado apagando /tmp/opencode/wine-9.0 e ~/.wine-pb16.)"
  fi

  # --- resumo
  if ! ui_sim "<b>Confirmar instalação</b>

Instalador: <tt>$exe</tt>
Destino:    <tt>$dest</tt>
Prefixo:    <tt>$PREFIX</tt>

O jogo será instalado em <tt>$dest</tt> e exposto ao Wine como <tt>C:\\PointBlank</tt>.

Continuar?"; then
    exit 0
  fi

  local sem_sudo=0
  if [ "${PB_SEM_SUDO:-0}" = "1" ]; then
    log "PB_SEM_SUDO=1: pulando servicos (a ponte sobe sob demanda no pb-run.sh)"
    sem_sudo=1
  elif ! sudo_init; then
    ui_aviso "Sem a senha do sudo, não instalo o serviço da ponte.
O jogo vai pedir a senha (via PolicyKit) ao abrir, ou você pode rodar:
  sudo $LOCAL/iptables-pb.sh && sudo python3 $LOCAL/pb-bridge.py &"
    sem_sudo=1
  fi

  instalar_wine
  criar_prefixo
  instalar_webview2
  instalar_jogo "$exe" "$dest"
  instalar_fontes "$dest"
  instalar_dxvk
  instalar_runtime
  [ $sem_sudo -eq 1 ] || instalar_servicos
  escrever_config "$dest"
  criar_atalho

  # --- verificação final
  passo "Verificando instalação"
  local ok=1
  [ -x "$WINE" ]                          || { log "FALTA: wine"; ok=0; }
  [ -f "$PREFIX/drive_c/PointBlank/PBLauncher.exe" ] || { log "FALTA: launcher"; ok=0; }
  [ -f "$PREFIX/drive_c/windows/syswow64/d3d11.dll" ] || { log "FALTA: dxvk"; ok=0; }
  [ -x "$LOCAL/pb-run.sh" ]               || { log "FALTA: pb-run.sh"; ok=0; }
  [ -f "$DESKTOP_DIR/point-blank.desktop" ] || { log "FALTA: atalho"; ok=0; }

  if [ $ok -eq 1 ]; then
    notify-send "Point Blank" "Instalação concluída." 2>/dev/null
    passo "===== instalacao concluida ====="
    if ui_sim "<b>Instalação concluída!</b>

Atalho criado na área de trabalho (e no menu de aplicativos).

Dica: no primeiro login o launcher baixa o patch (~427 MB) — deixe a janela aberta.

Quer iniciar o jogo agora?"; then
      setsid "$LOCAL/pb-run.sh" >/dev/null 2>&1 &
    fi
  else
    ui_erro "A instalação terminou com pendências. Veja o log:\n$LOG"
    ui_texto "$LOG"
    exit 1
  fi
}

main "$@"
