#!/bin/bash
# SPDX-License-Identifier: MIT
#
# Удаление DC Service с macOS. По умолчанию конфиг и логи сохраняются.
#   ./uninstall.sh          снять службу, оставить $PREFIX/service
#   ./uninstall.sh --purge  снести всё, включая конфиг и логи
#
set -euo pipefail

PREFIX="${PREFIX:-/opt/dcservice}"
LABEL="ru.inpas.dualconnector"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

msg() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

BLABEL="ru.inpas.paxbridge"
BPLIST="/Library/LaunchDaemons/${BLABEL}.plist"

msg "останавливаю службу и мост USB"
$SUDO launchctl bootout system/"$LABEL" 2>/dev/null || true
$SUDO launchctl bootout system/"$BLABEL" 2>/dev/null || true

for f in "$PLIST" "$BPLIST"; do
  if [ -f "$f" ]; then
    $SUDO rm -f "$f"
    msg "удалён $f"
  fi
done
# симлинки конфигов в /etc — только если это наши симлинки
for f in /etc/connector.xml /etc/dcposgui.xml; do
  if [ -L "$f" ] && readlink "$f" | grep -q "^$PREFIX/"; then
    $SUDO rm -f "$f"
    msg "удалён симлинк $f"
  fi
done

if [ "${1:-}" = "--purge" ]; then
  printf 'Удалить %s целиком, вместе с конфигом и логами? [y/N] ' "$PREFIX"
  read -r ans
  case "$ans" in
    y|Y|yes|YES)
      $SUDO rm -rf "$PREFIX"
      msg "удалено $PREFIX"
      ;;
    *) msg "отменено, каталог оставлен" ;;
  esac
else
  $SUDO rm -f "$PREFIX/dcservice.jar"
  $SUDO rm -rf "$PREFIX/bin" "$PREFIX/lib" "$PREFIX/native" "$PREFIX/tools" "$PREFIX/bridge"
  msg "программные файлы удалены, $PREFIX/service (конфиг и логи) оставлен"
fi

$SUDO rm -f /usr/local/bin/dcctl 2>/dev/null || true
msg "готово"
