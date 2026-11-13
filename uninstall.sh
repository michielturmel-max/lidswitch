#!/usr/bin/env bash
# Undo everything install.sh did.

set -euo pipefail

LOGIND_DROPIN="/etc/systemd/logind.conf.d/50-lidswitch.conf"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mlet op:\033[0m %s\n' "$*" >&2; }

say "CLI verwijderen"
rm -f "$HOME/.local/bin/lidswitch" "$HOME/.local/bin/lidswitch-uninstall"
printf '    verwijderd\n'

say "opencode-plugin verwijderen"
rm -f "$HOME/.config/opencode/plugin/lidswitch.ts"
printf '    verwijderd\n'

WIDGET_DIR="$HOME/.config/omarchy/plugins/lidswitch"
if [[ -d $WIDGET_DIR ]]; then
  say "balkwidget verwijderen"
  rm -rf "$WIDGET_DIR"
  printf '    verwijderd (zet Quickshell daarna opnieuw vast met omarchy plugin reload)\n'
fi

UNIT="$HOME/.config/systemd/user/lidswitch.service"
if [[ -f $UNIT ]]; then
  say "systemd-service verwijderen"
  systemctl --user disable --now lidswitch.service >/dev/null 2>&1 || true
  rm -f "$UNIT"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  printf '    verwijderd en gestopt\n'
fi

if [[ -f $LOGIND_DROPIN ]]; then
  say "logind-config verwijderen"
  if sudo -n true 2>/dev/null; then
    sudo rm -f "$LOGIND_DROPIN"
    printf '    verwijderd (deksel sluiten gaat weer in slaapstand na reboot)\n'
  else
    warn "voer zelf uit: sudo rm $LOGIND_DROPIN"
  fi
fi

say "configuratie en status"
warn "overgebleven, zelf te verwijderen als je wilt:"
printf '        %s\n' "$HOME/.config/lidswitch" "$HOME/.local/state/lidswitch"
