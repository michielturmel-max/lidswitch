#!/usr/bin/env bash
# Install lidswitch: CLI on PATH, opencode plugin, Hyprland lid bindings, and
# the one privileged change that stops logind from suspending on lid close.
#
# Safe to run twice. Everything it touches is either additive or replaced from
# this repo, and each step backs up what it overwrites.

set -euo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/lidswitch"
OC_CONFIG_DIR="$HOME/.config/opencode"
PLUGIN_DIR="$OC_CONFIG_DIR/plugin"
HYPR_BINDINGS="$HOME/.config/hypr/bindings.lua"
LOGIND_DROPIN="/etc/systemd/logind.conf.d/50-lidswitch.conf"

MARK_BEGIN="# >>> lidswitch >>>"
MARK_END="# <<< lidswitch <<<"

DO_LOGIND=1
DO_HYPR=1  # alleen de controle of Omarchy het deksel nog goed afhandelt

usage() {
  cat <<USAGE
lidswitch install [opties]

  --no-logind   sla de logind-wijziging over (geen sudo nodig)
  --no-hypr     de Hyprland-bindings niet toevoegen
  -h, --help    dit
USAGE
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --no-logind) DO_LOGIND=0; shift ;;
    --no-hypr) DO_HYPR=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "onbekende optie: $1" >&2; usage; exit 2 ;;
  esac
done

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mlet op:\033[0m %s\n' "$*" >&2; }
ok() { printf '    \033[32m%s\033[0m\n' "$*"; }

backup() {
  local target=$1
  [[ -e $target ]] || return 0
  local bak="$target.bak.$(date +%Y%m%d-%H%M%S)"
  cp -a "$target" "$bak"
  ok "backup: $bak"
}

# ----------------------------------------------------------------- CLI ----

say "CLI op PATH"
mkdir -p "$BIN_DIR"
ln -sf "$PROJECT_DIR/bin/lidswitch" "$BIN_DIR/lidswitch"
ln -sf "$PROJECT_DIR/uninstall.sh" "$BIN_DIR/lidswitch-uninstall"
ok "$BIN_DIR/lidswitch -> $PROJECT_DIR/bin/lidswitch"
ok "$BIN_DIR/lidswitch-uninstall"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) warn "$BIN_DIR staat niet in je PATH; voeg het toe of gebruik het volledige pad" ;;
esac

# --------------------------------------------------------------- config ----

say "configuratie"
mkdir -p "$CONFIG_DIR"
for f in policy.json config.json; do
  if [[ -e $CONFIG_DIR/$f ]]; then
    ok "$f bestaat al, niet overschreven"
  else
    cp "$PROJECT_DIR/config/$f" "$CONFIG_DIR/$f"
    ok "geinstalleerd: $CONFIG_DIR/$f"
  fi
done
mkdir -p "$HOME/.local/state/lidswitch/sessions"
ok "status: $HOME/.local/state/lidswitch/"

# --------------------------------------------------------------- plugin ----

say "opencode-plugin"
mkdir -p "$PLUGIN_DIR"
PLUGIN_TARGET="$PLUGIN_DIR/lidswitch.ts"
if [[ -e $PLUGIN_TARGET && ! -L $PLUGIN_TARGET ]]; then
  backup "$PLUGIN_TARGET"
  rm -f "$PLUGIN_TARGET"
fi
ln -sfn "$PROJECT_DIR/plugin/lidswitch.ts" "$PLUGIN_TARGET"
ok "$PLUGIN_TARGET -> $PROJECT_DIR/plugin/lidswitch.ts"

if [[ ! -d $OC_CONFIG_DIR/node_modules/@opencode-ai/plugin ]]; then
  warn "@opencode-ai/plugin ontbreekt in $OC_CONFIG_DIR/node_modules"
  warn "de plugin gebruikt alleen 'import type', dus dit zou geen fout mogen geven"
fi

# ----------------------------------------------------------- balkwidget ----

if [[ $DO_HYPR -eq 1 ]]; then
  # Quickshell laadt de widget uit een eigen map, dus een symlink naar het
  # project zou paden in de QML naar /proc laten wijzen. Daarom gekopieerd, en
  # een bestaande map wordt eerst weggezet zodat er geen oude resten blijven
  # staan die de shell al geladen heeft.
  say "balkwidget"
  WIDGET_SRC="$PROJECT_DIR/omarchy-plugin/lidswitch"
  WIDGET_DIR="$HOME/.config/omarchy/plugins/lidswitch"
  if [[ -d $WIDGET_SRC ]]; then
    if [[ -e $WIDGET_DIR ]]; then
      backup "$WIDGET_DIR"
      rm -rf "$WIDGET_DIR"
    fi
    mkdir -p "$WIDGET_DIR"
    # Quickshell herlaadt zodra het bestand verandert, en een gewone cp truncateert
    # eerst: de shell leest dan een half bestand en de helft van de widget faalt.
    # Naar een naast bestand schrijven en renamen is atomair, dus de shell ziet
    # alleen het complete bestand.
    cp -r "$WIDGET_SRC/." "$WIDGET_DIR.new"
    rm -rf "$WIDGET_DIR"
    mv "$WIDGET_DIR.new" "$WIDGET_DIR"
    ok "geïnstalleerd: $WIDGET_DIR"
    ok "zet hem aan met: omarchy restart shell"
  else
    warn "widget-bron ontbreekt: $WIDGET_SRC"
  fi
fi

# ------------------------------------------------------------- Hyprland ----

if [[ $DO_HYPR -eq 1 ]]; then
  say "Hyprland: laat Omarchy het deksel doen"
  removed=0
  if [[ -f $HYPR_BINDINGS ]]; then
    tmp=$(mktemp)
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
      $0 == b { skip = 1 }
      skip != 1 { print }
      $0 == e { skip = 0 }
    ' "$HYPR_BINDINGS" >"$tmp"
    if ! cmp -s "$tmp" "$HYPR_BINDINGS"; then
      mv "$tmp" "$HYPR_BINDINGS"
      ok "oude lidswitch-bindings verwijderd uit $(basename "$HYPR_BINDINGS")"
      removed=1
    else
      rm -f "$tmp"
    fi
  fi
  [[ $removed -eq 0 ]] && ok "geen wijziging nodig: Omarchy vergrendelt en schakelt het scherm al zelf om"
  hyprctl binds 2>/dev/null | grep -q 'switch:on:Lid Switch' \
    && ok "dekselbinding van Omarchy staat aan" \
    || warn "geen dekselbinding gevonden; controleer of Omarchy normaal werkt"
  ok "lidswitch leest de dekselstand zelf en raakt je Hyprland-config niet aan"
else
  say "Hyprland-controle overgeslagen (--no-hypr)"
fi

# -------------------------------------------------------------- service ----

say "systemd-service"
UNIT_DIR="$HOME/.config/systemd/user"
mkdir -p "$UNIT_DIR" "$HOME/.local/state/lidswitch/sessions"
if [[ -f $UNIT_DIR/lidswitch.service ]]; then
  backup "$UNIT_DIR/lidswitch.service"
fi
install -m644 "$PROJECT_DIR/systemd/lidswitch.service" "$UNIT_DIR/lidswitch.service"
ok "geïnstalleerd: $UNIT_DIR/lidswitch.service"

systemctl --user daemon-reload
if systemctl --user enable --now lidswitch.service >/dev/null 2>&1; then
  ok "lidswitch.service draait"
else
  warn "kon lidswitch.service niet starten; probeer: systemctl --user enable --now lidswitch.service"
  warn "en kijk in het log met: journalctl --user -u lidswitch.service -n 30"
fi

# --------------------------------------------------------------- logind ----

if [[ $DO_LOGIND -eq 1 ]]; then
  say "logind: geen slaapstand bij deksel dicht"
  current=$(busctl --system get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager HandleLidSwitch 2>/dev/null | awk '{print $NF}')
  ok "huidige HandleLidSwitch: ${current:-onbekend}"

  if sudo -n true 2>/dev/null; then
    sudo install -Dm644 "$PROJECT_DIR/systemd/50-lidswitch-logind.conf" "$LOGIND_DROPIN"
    ok "geïnstalleerd: $LOGIND_DROPIN"
    warn "logind herstarten kan je sessie beëindigen; het gaat ook pas in bij een reboot"
    warn "dus: herstart de laptop één keer om het in te schakelen"
  else
    warn "sudo zonder wachtwoord kan niet; voer dit zelf uit:"
    printf '        sudo install -Dm644 %q %q\n' "$PROJECT_DIR/systemd/50-lidswitch-logind.conf" "$LOGIND_DROPIN"
  fi
else
  say "logind overgeslagen (--no-logind)"
fi

# ------------------------------------------------------------ sloten af ----

cat <<EOF

Klaar. Wat er nu gebeurt:

  deksel dicht   Omarchy vergrendelt het scherm en haalt het interne display
                 weg; de laptop gaat NIET in slaapstand. De plugin in opencode
                 ziet dat je weg bent en laat het model zelfstandig doorwerken.
  deksel open    het scherm gaat aan en opencode krijgt een samenvatting van
                 wat er is gebeurd en welke vragen op jou wachten.

Tijdens afwezigheid beantwoordt de plugin elke rechtenvraag zelf: normaal
werk gaat door, en alles wat jouw beslissing nodig heeft wordt uitgesteld tot
de laatste todo.

Nog nodig:
  - herstart opencode, zodat de plugin geladen wordt
  - herstart de laptop eenmalig, zodat HandleLidSwitch=ignore actief wordt
    (tot die tijd gaat de laptop nog in slaapstand bij deksel dicht)

Controleer daarna met:  lidswitch check
EOF
