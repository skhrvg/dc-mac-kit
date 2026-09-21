#!/bin/bash
# SPDX-License-Identifier: MIT
#
# Почему терминал не виден как последовательный порт.
#
# Проверяет цепочку по шагам:
#   USB-устройство появилось в системе?
#     └─ к нему привязался драйвер последовательного порта?
#          └─ появился /dev/cu.*?
#
# Обрыв на любом из шагов диагностируется по-разному, поэтому смотрим все три.
#
#   ./usb-diag.sh          быстрая проверка
#   ./usb-diag.sh --log    плюс системный лог по USB за последние 5 минут
#
set -uo pipefail

# VID вендоров:
#   Verifone 11CA и старый PAX 1234 — из ru.inpas.communication.pc.Serial (dcservice.jar)
#   PAX Prolin 2FB8 (D230 и др.)    — из ttyPos.h драйвера LinuxDriver_V317
VID_VERIFONE="11ca"
VID_PAX_OLD="1234"
VID_PAX_PROLIN="2fb8"

hdr() { printf '\n\033[1;34m=== %s\033[0m\n' "$*"; }
ok()  { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
bad() { printf '\033[1;31m  ✗\033[0m %s\n' "$*"; }
inf() { printf '    %s\n' "$*"; }

[ "$(uname -s)" = "Darwin" ] || { echo "скрипт для macOS"; exit 1; }

# ------------------------------------------------- 1. последовательные порты

hdr "1. Последовательные порты в /dev"

SYSTEM_PORTS='Bluetooth-Incoming-Port|debug-console|wlan-debug'
ALL_CU=$(ls /dev/cu.* 2>/dev/null || true)
REAL_CU=$(printf '%s\n' "$ALL_CU" | grep -vE "$SYSTEM_PORTS" | grep -v '^$' || true)

if [ -n "$ALL_CU" ]; then
  printf '%s\n' "$ALL_CU" | sed 's/^/    /'
else
  inf "(пусто)"
fi

if [ -n "$REAL_CU" ]; then
  ok "есть порты помимо системных:"
  printf '%s\n' "$REAL_CU" | sed 's/^/      /'
  inf "в connector.xml: <CONNECTION_PORT>$(printf '%s\n' "$REAL_CU" | head -1)</CONNECTION_PORT>"
else
  bad "кроме штатных Bluetooth/debug-console ничего нет"
fi

# ------------------------------------------------------- 2. дерево USB

hdr "2. USB-устройства"

# Источник — реестр IOKit (ioreg). Он не зависит от формата system_profiler,
# который Apple меняет между версиями macOS.
USB_LIST=$(ioreg -p IOUSB -w0 -l 2>/dev/null | awk '
  function flush() {
    if (vid != "" && pid != "")
      printf "%04x:%04x  bcdDevice=%04x  %s\n", vid, pid, (bcd == "" ? 0 : bcd), (pn != "" ? pn : nm)
  }
  /\+-o / {
    flush()
    nm = $0; sub(/^.*\+-o /, "", nm); sub(/ +<class.*/, "", nm); sub(/@.*/, "", nm)
    vid = pid = bcd = pn = ""
  }
  /"idVendor" = /          { vid = $NF }
  /"idProduct" = /         { pid = $NF }
  /"bcdDevice" = /         { bcd = $NF }
  /"USB Product Name" = /  { pn = $0; sub(/.*= "/, "", pn); sub(/"[[:space:]]*$/, "", pn) }
  END { flush() }
')

if [ -n "$USB_LIST" ]; then
  printf '%s\n' "$USB_LIST" | sed 's/^/    /'
else
  bad "в реестре IOKit нет ни одного USB-устройства"
fi

PAX_LINE=$(printf '%s\n' "$USB_LIST" | grep -iE "^($VID_PAX_PROLIN|$VID_PAX_OLD):" | head -1)
VF_LINE=$(printf '%s\n' "$USB_LIST" | grep -iE "^$VID_VERIFONE:" | head -1)
if [ -n "$PAX_LINE" ]; then
  ok "терминал PAX на шине: $PAX_LINE"
elif [ -n "$VF_LINE" ]; then
  ok "терминал Verifone на шине: $VF_LINE"
else
  bad "устройств Verifone ($VID_VERIFONE) и PAX ($VID_PAX_PROLIN / $VID_PAX_OLD) не найдено"
fi

# --------------------------------------- 3. драйвер последовательного порта

hdr "3. Драйверы последовательного порта (IOSerialBSDClient)"

SER=$(ioreg -r -c IOSerialBSDClient -l 2>/dev/null \
      | grep -E '"IOCalloutDevice"|"IOTTYDevice"' | sed 's/^ *//' || true)
if [ -n "$SER" ]; then
  printf '%s\n' "$SER" | sed 's/^/    /'
else
  bad "ни одного IOSerialBSDClient — драйвер последовательного порта ни к чему не привязан"
fi

hdr "4. Загруженные драйверы USB-serial"

CDC=$(kextstat 2>/dev/null | grep -icE "AppleUSBCDC|AppleUSBACM" || true)
if [ "${CDC:-0}" -gt 0 ]; then
  ok "штатный CDC/ACM-драйвер Apple загружен"
else
  inf "AppleUSBCDC в kextstat не виден (на свежих macOS это норма — драйвер встроен в ядро)"
fi

THIRD=$(kextstat 2>/dev/null | grep -iE "ftdi|silabs|cp210|prolific|pl2303|ch34|wch" || true)
if [ -n "$THIRD" ]; then
  ok "сторонние драйверы переходников:"
  printf '%s\n' "$THIRD" | sed 's/^/      /'
else
  inf "сторонних драйверов (FTDI / SiLabs CP210x / Prolific / CH34x) нет"
fi

EXTS=$(systemextensionsctl list 2>/dev/null | grep -iE "serial|ftdi|silabs|usb" || true)
if [ -n "$EXTS" ]; then
  inf "системные расширения:"
  printf '%s\n' "$EXTS" | sed 's/^/      /'
  if printf '%s\n' "$EXTS" | grep -qi "waiting for user"; then
    echo
    bad "расширение ЗАБЛОКИРОВАНО и ждёт вашего подтверждения"
    inf "Системные настройки → Конфиденциальность и безопасность → разрешить"
    inf "ПО разработчика, затем перезагрузить мак. Пока не подтвердите,"
    inf "драйвер не работает, и устройства на его чипе порт не получат."
  fi
fi

# ------------------------------------------------------------- 5. лог

if [ "${1:-}" = "--log" ]; then
  hdr "5. Системный лог по USB за 5 минут"
  log show --last 5m --style compact 2>/dev/null \
    | grep -iE "usb|iokit|serial" | tail -40 | sed 's/^/    /' \
    || inf "(лог недоступен)"
fi

# --------------------------------------------------------- интерпретация

hdr "Что это значит"

if [ -n "$REAL_CU" ]; then
  cat <<'EOF'
  Порт есть — терминал виден как последовательный порт: USB-CDC или Bluetooth
  (у Bluetooth-порта в имени название терминала).
  В connector.xml: CONNECTION_TYPE=COM, CONNECTION_PORT=<порт cu.*>.
EOF
elif [ -n "$PAX_LINE" ]; then
  cat <<'EOF'
  Терминал PAX на шине, но последовательного порта нет — это НОРМАЛЬНО:
  он в «стандартном» USB-режиме (ttyPOS), где говорит собственным протоколом
  поверх bulk-эндпоинтов, а не притворяется COM-портом. На Linux этот протокол
  обслуживает модуль ядра ttyPos; под macOS его заменяет paxbridge.py.

  После install.sh мост работает службой ru.inpas.paxbridge:

    dcctl bridge status               служба, порт, терминал на шине
    dcctl bridge probe                проверить, что терминал отвечает по протоколу

  В connector.xml:  CONNECTION_TYPE=IP,  IPADDRESS=127.0.0.1:27016
  (без установки:   paxbridge.py --probe  /  paxbridge.py --serve)
EOF
elif [ -n "$VF_LINE" ]; then
  cat <<'EOF'
  Терминал Verifone на шине, но порт не создался — значит он отдаёт
  интерфейс, который macOS не считает CDC-ACM. Проверьте режим USB в меню
  терминала (нужен виртуальный COM-порт / CDC) и перезагрузите его.
EOF
else
  cat <<'EOF'
  Терминала в реестре USB нет — до драйверов дело не доходит.

    • РЕЖИМ. Включите на терминале связь с кассой по USB и ПЕРЕЗАГРУЗИТЕ его:
      режим обычно применяется только после рестарта.
    • КАБЕЛЬ. Нужен кабель с линиями данных, не только зарядный.
    • ПОРТ. Прямой порт мака, без хаба и переходника.

  Проверка без скрипта:  ioreg -p IOUSB -w0 | grep -i -E "pax|2fb8"
EOF
fi
echo
