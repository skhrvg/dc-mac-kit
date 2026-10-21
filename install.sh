#!/bin/bash
# SPDX-License-Identifier: MIT
#
# DC Linux Service (INPAS DualConnector) 2.0.17.7 / 2.1.0.15 — установка на macOS Apple Silicon.
#
# Ни один файл дистрибутива не модифицируется. Совместимость достигается
# внешними рычагами (подробности — в bin/dcservice-run.sh и README):
#   1) -Dos.name=Linux — иначе FactoryCommunication не создаёт НИ ОДНОГО устройства:
#      в его switch по OSType есть только WINDOWS/LINUX/ANDROID, MAC_OS уходит в
#      default: return null. Это корень ошибки "Can't open device ...null";
#   2) подмена jssc через порядок classpath (встроенная 2.9.2 без нативов под arm64);
#   3) libjssc.dylib на java.library.path, в обход сломанного детекта архитектуры;
#   4) с DC 2.1 — libjSerialComm.dylib там же: из-за п. 1 jSerialComm иначе
#      берёт Linux-сборку .so, и обмен по COM/Bluetooth рвётся без ответа.
#
# Запускать из папки macos-kit внутри распакованного дистрибутива:
#   ./install.sh
#
# Переменные окружения:
#   PREFIX=/opt/dcservice     куда ставить
#   RUN_USER=$(id -un)        от чьего имени крутить службу
#   JSSC_VERSION=2.10.4       версия jssc с Maven Central
#   JSSC_JAR_PATH=/path.jar   взять локальный jar вместо скачивания
#   DC_DIST=/path/to/dist     где лежит распакованный дистрибутив DC (по умолчанию ..)
#   BRIDGE_PORT=27016         порт моста USB для PAX (paxbridge)
#   BT_DEVICE=UNIPOS          терминал для моста Bluetooth (имя или адрес; по умолчанию
#                             ищется единственное сопряжённое устройство с последовательным портом)
#   BT_PORT=27017             порт моста Bluetooth (btbridge)
#
set -euo pipefail

PREFIX="${PREFIX:-/opt/dcservice}"
LABEL="ru.inpas.dualconnector"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
JSSC_VERSION="${JSSC_VERSION:-2.10.4}"
JSSC_JAR="jssc-${JSSC_VERSION}.jar"
JSSC_URL="https://repo1.maven.org/maven2/io/github/java-native/jssc/${JSSC_VERSION}/${JSSC_JAR}"

# Мост USB для PAX (paxbridge) — отдельная служба launchd
BLABEL="ru.inpas.paxbridge"
BPLIST="/Library/LaunchDaemons/${BLABEL}.plist"
BRIDGE_PORT="${BRIDGE_PORT:-27016}"

# Мост Bluetooth (btbridge) — LaunchAgent пользователя RUN_USER (см. раздел моста ниже)
BTLABEL="ru.inpas.btbridge"
BT_PORT="${BT_PORT:-27017}"
BT_DEVICE="${BT_DEVICE:-}"
BT_APP="$PREFIX/btbridge/BTBridge.app"

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Каталог распакованного дистрибутива DC Linux Service. По умолчанию комплект
# лежит внутри него (macos-kit рядом с files/, Scheme/, Documents/);
# иначе укажите путь явно:  DC_DIST=/path/to/dist ./install.sh
DIST_DIR="${DC_DIST:-$(cd "$KIT_DIR/.." && pwd)}"
SRC="$DIST_DIR/files"

RUN_USER="${RUN_USER:-$(id -un)}"
RUN_GROUP="$(id -gn "$RUN_USER")"
RUN_UID="$(id -u "$RUN_USER")"
RUN_HOME="$(dscl . -read "/Users/$RUN_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"

# мост Bluetooth живёт в сессии RUN_USER: его LaunchAgents, его база TCC
BTPLIST="${RUN_HOME}/Library/LaunchAgents/${BTLABEL}.plist"
AS_USER=""
[ "$(id -un)" != "$RUN_USER" ] && AS_USER="sudo -u $RUN_USER"

msg()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- проверки

[ "$(uname -s)" = "Darwin" ] || die "скрипт только для macOS"
[ -f "$SRC/dcservice.jar" ] || die "не найден $SRC/dcservice.jar — положите macos-kit внутрь папки дистрибутива или задайте DC_DIST=/путь/к/дистрибутиву"

find_java() {
  if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
    printf '%s' "$JAVA_HOME/bin/java"; return
  fi
  if [ -x /usr/libexec/java_home ]; then
    local jh
    jh="$(/usr/libexec/java_home -v 11+ 2>/dev/null || true)"
    if [ -n "$jh" ]; then printf '%s' "$jh/bin/java"; return; fi
  fi
  command -v java 2>/dev/null || true
}

JAVA="$(find_java)"
[ -n "$JAVA" ] || die "Java не найдена. Поставьте arm64-сборку JDK 17:  brew install --cask temurin@17"

JAVA_PROPS="$("$JAVA" -XshowSettings:properties -version 2>&1)"
JAVA_ARCH="$(printf '%s\n' "$JAVA_PROPS" | awk -F'=' '/os\.arch[ ]*=/{gsub(/[ \t]/,"",$2); print $2; exit}')"
JAVA_VER="$(printf '%s\n' "$JAVA_PROPS"  | awk -F'=' '/java\.version[ ]*=/{gsub(/[ \t]/,"",$2); print $2; exit}' | cut -d. -f1)"
JAVA_HOME_DIR="$(printf '%s\n' "$JAVA_PROPS" | awk -F'=' '/java\.home[ ]*=/{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')"

[ "${JAVA_VER:-0}" -ge 11 ] 2>/dev/null || die "нужна Java 11+, найдена ${JAVA_VER:-?} ($JAVA)"
msg "Java: $JAVA (версия $JAVA_VER, os.arch=$JAVA_ARCH)"
if [ "$JAVA_ARCH" != "aarch64" ]; then
  warn "JVM не arm64 — похоже на Rosetta. Заработает, но лучше поставить нативный arm64 JDK."
fi
case "$JAVA_HOME_DIR" in
  "$HOME"/*)
    warn "JDK лежит в домашнем каталоге ($JAVA_HOME_DIR)."
    warn "Если это рантайм из IDE (JetBrains jbr и подобные), он исчезнет при обновлении IDE и служба встанет."
    warn "Для боевой установки поставьте системный JDK и переустановите:  brew install --cask temurin@17"
    ;;
esac

# ------------------------------------------------------------------- jssc

mkdir -p "$KIT_DIR/vendor"
if [ -n "${JSSC_JAR_PATH:-}" ]; then
  [ -f "$JSSC_JAR_PATH" ] || die "не найден $JSSC_JAR_PATH"
  JSSC_JAR="$(basename "$JSSC_JAR_PATH")"
  cp "$JSSC_JAR_PATH" "$KIT_DIR/vendor/$JSSC_JAR"
  msg "jssc взят локально: $JSSC_JAR"
elif [ -f "$KIT_DIR/vendor/$JSSC_JAR" ]; then
  msg "jssc уже скачан: vendor/$JSSC_JAR"
else
  msg "качаю $JSSC_JAR с Maven Central"
  curl -fL --retry 3 --connect-timeout 15 -o "$KIT_DIR/vendor/$JSSC_JAR" "$JSSC_URL" \
    || die "не удалось скачать. Скачайте вручную $JSSC_URL и повторите с JSSC_JAR_PATH=/путь/$JSSC_JAR"
fi

# ---------------------------------------------------------------- раскладка

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

msg "ставлю в $PREFIX (служба от имени $RUN_USER)"
$SUDO mkdir -p "$PREFIX/bin" "$PREFIX/lib" "$PREFIX/native" "$PREFIX/tools" "$PREFIX/service/config" "$PREFIX/service/log"

$SUDO cp "$SRC/dcservice.jar" "$PREFIX/dcservice.jar"
# чистим старые версии, чтобы в lib/ лежал ровно один jssc
$SUDO rm -f "$PREFIX/lib/"jssc-*.jar
$SUDO cp "$KIT_DIR/vendor/$JSSC_JAR" "$PREFIX/lib/$JSSC_JAR"

for j in dcconsole.jar dcposgui.jar dccontrol.jar; do
  [ -f "$SRC/$j" ] && $SUDO cp "$SRC/$j" "$PREFIX/tools/$j"
done
# cp -R в существующий каталог вложил бы копию внутрь — сносим перед копированием
for d in cp lib; do
  if [ -d "$SRC/$d" ]; then
    $SUDO rm -rf "${PREFIX:?}/tools/$d"
    $SUDO cp -R "$SRC/$d" "$PREFIX/tools/$d"
  fi
done

# Нативная библиотека jssc — отдельным файлом на java.library.path.
#
# Почему не «просто jar»: jssc не тащит за собой native-lib-loader, это внешняя
# зависимость. На classpath остаётся ТОЛЬКО старый scijava 2.3.x (2019) из
# dcservice.jar, а он для mac знает лишь INTEL_32/INTEL_64/PPC и на aarch64
# отдаёт «No native library available for this platform».
# Зато NativeLoader.loadLibrary() первым делом делает System.loadLibrary() и
# только при UnsatisfiedLinkError уходит в этот распаковщик. Положив .dylib на
# java.library.path, мы до детекта архитектуры просто не доходим.
case "$JAVA_ARCH" in
  aarch64) NATIVE_SRC="natives/osx_arm64/libjssc.dylib" ;;
  *)       NATIVE_SRC="natives/osx_64/libjssc.dylib" ;;
esac
$SUDO rm -f "$PREFIX/native/libjssc.dylib"
$SUDO unzip -o -j "$PREFIX/lib/$JSSC_JAR" "$NATIVE_SRC" -d "$PREFIX/native" >/dev/null \
  || die "в $JSSC_JAR нет $NATIVE_SRC — возьмите версию jssc 2.9.3 или новее"
msg "нативная библиотека: $NATIVE_SRC → $PREFIX/native/libjssc.dylib"

# Нативная библиотека jSerialComm — с DC 2.1 обмен по COM идёт через неё, а не через jssc.
#
# jSerialComm выбирает сборку по os.name, а оно подменено на Linux: распаковывает
# libjSerialComm.so, и dlopen её отвергает («slice is not valid mach-o file»).
# UnsatisfiedLinkError летит из Serial.init() мимо catch (Exception), поток
# HTTP-обработчика умирает, касса получает оборванное соединение без ответа.
# Но до распаковки jSerialComm делает System.loadLibrary("jSerialComm"), а имя
# файла для него JVM строит по настоящей ОС — libjSerialComm.dylib. Кладём туда
# маковскую сборку из того же dcservice.jar, рядом с libjssc.dylib.
case "$JAVA_ARCH" in
  aarch64) JSC_SRC="OSX/aarch64/libjSerialComm.jnilib" ;;
  *)       JSC_SRC="OSX/x86_64/libjSerialComm.jnilib" ;;
esac
$SUDO rm -f "$PREFIX/native/libjSerialComm.dylib"
if unzip -l "$PREFIX/dcservice.jar" "$JSC_SRC" >/dev/null 2>&1; then
  unzip -p "$PREFIX/dcservice.jar" "$JSC_SRC" | $SUDO tee "$PREFIX/native/libjSerialComm.dylib" >/dev/null
  msg "нативная библиотека: dcservice.jar!/$JSC_SRC → $PREFIX/native/libjSerialComm.dylib"
else
  msg "в dcservice.jar нет jSerialComm (DC до 2.1) — пропускаю"
fi
# Если установку запускает процесс, который помечает созданные файлы карантином,
# dlopen откажет: «library load disallowed by system policy». Снимаем заранее.
$SUDO xattr -dr com.apple.quarantine "$PREFIX/native" 2>/dev/null || true

for t in JsscCheck.java TcpProbe.java; do
  [ -f "$KIT_DIR/$t" ] && $SUDO cp "$KIT_DIR/$t" "$PREFIX/tools/$t"
done

# конфиг службы — не перезатираем существующий
FRESH_CONFIG=0
if [ ! -f "$PREFIX/service/config/connector.xml" ]; then
  $SUDO cp "$KIT_DIR/connector.xml.template" "$PREFIX/service/config/connector.xml"
  $SUDO sed -i '' "s#__PREFIX__#${PREFIX}#g" "$PREFIX/service/config/connector.xml"
  FRESH_CONFIG=1
  msg "создан $PREFIX/service/config/connector.xml (шаблон)"
else
  msg "connector.xml уже есть — не трогаю"
fi

# Конфиг службы должен лежать там, где его ищет LINUX-ветка Utils.getConfigFolder(),
# то есть в /etc. Источник правды оставляем в service/config, в /etc — симлинк.
if [ -f "$PREFIX/service/config/connector.xml" ]; then
  if [ -e /etc/connector.xml ] && [ ! -L /etc/connector.xml ]; then
    warn "/etc/connector.xml существует и не является симлинком — оставляю как есть"
  else
    $SUDO ln -sfn "$PREFIX/service/config/connector.xml" /etc/connector.xml
    msg "/etc/connector.xml → $PREFIX/service/config/connector.xml"
  fi
fi

# До чтения конфига логгер пишет в путь по умолчанию LINUX-ветки.
$SUDO mkdir -p /var/log/dualconnector
$SUDO chown "${RUN_USER}:${RUN_GROUP}" /var/log/dualconnector

# Конфиг окна кассира.
#
# У DC PosGUI своя детекция ОС и свой Utils: os.name → WINDOWS / LINUX / UNKNOWN,
# ветки для macOS нет вообще, поэтому getConfigFolder() оставляет поле null и
# приложение ищет "null/dcposgui.xml". CSINSTALL тут не помогает — PosGUI его для
# конфига не читает (только для запуска DC Control).
# Обходим подменой os.name=Linux в обёртке bin/dcposgui: тогда конфиг берётся
# из /etc/, куда мы кладём симлинк на наш файл — источник правды остаётся один.
# getLogFolder() при этом никем не вызывается, так что /var/log не задействован.
if [ ! -f "$PREFIX/service/config/dcposgui.xml" ] && [ -f "$SRC/dcposgui.xml" ]; then
  $SUDO cp "$SRC/dcposgui.xml" "$PREFIX/service/config/dcposgui.xml"
fi
if [ -f "$PREFIX/service/config/dcposgui.xml" ]; then
  if [ -e /etc/dcposgui.xml ] && [ ! -L /etc/dcposgui.xml ]; then
    warn "/etc/dcposgui.xml существует и не является симлинком — оставляю как есть"
  else
    $SUDO ln -sfn "$PREFIX/service/config/dcposgui.xml" /etc/dcposgui.xml
    msg "/etc/dcposgui.xml → $PREFIX/service/config/dcposgui.xml"
  fi
fi

# ------------------------------------------------------------ обёртка запуска

$SUDO tee "$PREFIX/bin/dcservice-run.sh" >/dev/null <<'RUNEOF'
#!/bin/bash
# Запуск DC Service. Три обхода:
#
#   1) -Dos.name=Linux — САМОЕ ВАЖНОЕ. FactoryCommunication создаёт устройства
#      через switch по OSType, где есть только WINDOWS(1), LINUX(2), ANDROID(3):
#          createTcpClient():  case 1,2,3 -> new TcpClient();  default -> null
#          createUsbHost():    case 1,2   -> new Serial();     default -> null
#      MAC_OS попадает в default, результат заворачивается в BufferedDevice,
#      а тот на null молча возвращает false из init(). Наружу это выглядит как
#      "Can't open device <адрес>null" — и в COM-режиме, и в IP.
#      Utils.getOSType() читает os.name через Apache SystemUtils, поэтому
#      подмена свойства переводит службу на рабочую LINUX-ветку.
#      Следствие: конфиг берётся из /etc/connector.xml (install.sh кладёт туда
#      симлинк), а мониторинг устройств идёт по Linux-пути — libudev на маке
#      не находится, и он сам откатывается на inotify, что работает.
#
#   2) jssc из lib/ идёт ПЕРВЫМ в classpath и перекрывает встроенную 2.9.2;
#   3) -Djava.library.path на native/ — чтобы System.loadLibrary("jssc")
#      сработал раньше, чем в дело вступит старый scijava из dcservice.jar,
#      не умеющий mac+aarch64. С DC 2.1 там же libjSerialComm.dylib: из-за
#      п. 1 jSerialComm иначе распакует Linux-сборку и не загрузится.
set -euo pipefail

PREFIX="__PREFIX__"
JSSC_JAR="__JSSC_JAR__"

export CSINSTALL="${CSINSTALL:-$PREFIX}"

if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
  JAVA="$JAVA_HOME/bin/java"
elif [ -x /usr/libexec/java_home ]; then
  JAVA="$(/usr/libexec/java_home -v 11+)/bin/java"
else
  JAVA="$(command -v java)"
fi

exec "$JAVA" \
  -Xms32m -Xmx256m \
  -Dos.name=Linux \
  -Djava.library.path="$PREFIX/native" \
  -cp "$PREFIX/lib/$JSSC_JAR:$PREFIX/dcservice.jar" \
  ru.inpas.service.ServiceMain
RUNEOF

$SUDO sed -i '' -e "s#__PREFIX__#${PREFIX}#g" -e "s#__JSSC_JAR__#${JSSC_JAR}#g" "$PREFIX/bin/dcservice-run.sh"
$SUDO chmod 755 "$PREFIX/bin/dcservice-run.sh"

# ----------------------------------------------------------------- dcctl

$SUDO tee "$PREFIX/bin/dcctl" >/dev/null <<'CTLEOF'
#!/bin/bash
# Замена DC Service Control: dccontrol дёргает systemctl и на macOS бесполезен.
set -uo pipefail
LABEL="ru.inpas.dualconnector"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
PREFIX="__PREFIX__"
BLABEL="ru.inpas.paxbridge"
BPLIST="/Library/LaunchDaemons/${BLABEL}.plist"
BRIDGE_PORT="__BRIDGE_PORT__"
# мост Bluetooth — LaunchAgent в сессии пользователя, а не системная служба
BTLABEL="ru.inpas.btbridge"
BTPLIST="__BTPLIST__"
BT_PORT="__BT_PORT__"
BT_UID="__BT_UID__"
BT_USER="__BT_USER__"
BT_APP="$PREFIX/btbridge/BTBridge.app"

loaded()  { launchctl print system/"$LABEL"  >/dev/null 2>&1; }
bloaded() { launchctl print system/"$BLABEL" >/dev/null 2>&1; }
btloaded() { launchctl print gui/"$BT_UID"/"$BTLABEL" >/dev/null 2>&1; }
# терминал моста — из его plist, чтобы источник был один
bt_device() { /usr/libexec/PlistBuddy -c "Print :ProgramArguments" "$BTPLIST" 2>/dev/null | awk 'p { print $1; exit } $1 == "--device" { p = 1 }'; }
# в сессии пользователя моста: его launchd-домен, его разрешение на Bluetooth
as_bt() { if [ "$(id -u)" = "$BT_UID" ]; then "$@"; else sudo launchctl asuser "$BT_UID" sudo -u "$BT_USER" "$@"; fi; }

case "${1:-}" in
  start)
    if loaded; then
      echo "уже загружено — restart для перезапуска, status для состояния"
      exit 0
    fi
    [ -x "$PREFIX/bin/dcservice-run.sh" ] || { echo "нет исполняемого $PREFIX/bin/dcservice-run.sh"; exit 1; }
    plutil -lint "$PLIST" >/dev/null || { echo "битый plist: $PLIST"; exit 1; }
    if err=$(sudo launchctl bootstrap system "$PLIST" 2>&1); then
      echo "запущено"
    else
      echo "не удалось: $err"
      echo
      echo "  '5: Input/output error' обычно значит, что job уже загружен."
      echo "  Снять и загрузить заново:"
      echo "    sudo launchctl bootout system/$LABEL; sudo launchctl bootstrap system $PLIST"
      exit 1
    fi
    ;;
  stop)
    loaded || { echo "не загружено"; exit 0; }
    sudo launchctl bootout system/"$LABEL"
    # bootout асинхронен — дождёмся выгрузки, иначе следующий start упадёт с «5: I/O error»
    for i in $(seq 1 20); do loaded || break; sleep 0.5; done
    echo "остановлено"
    ;;
  restart)
    if loaded; then
      sudo launchctl kickstart -k system/"$LABEL" && echo "перезапущено"
    else
      sudo launchctl bootstrap system "$PLIST" && echo "запущено"
    fi
    ;;
  status)
    if loaded; then
      launchctl print system/"$LABEL" 2>/dev/null \
        | awk '/^[[:space:]]*(state|pid|last exit code|program) = / { if (!($1 in seen)) { seen[$1] = 1; sub(/^[[:space:]]*/, "  "); print } }'
    else
      echo "  launchd: не загружено"
    fi
    if [ -f "$BPLIST" ]; then
      if bloaded; then b=$(launchctl print system/"$BLABEL" 2>/dev/null | sed -n 's/^[[:space:]]*state = //p' | head -1)
      else b="не загружен"; fi
      echo "  мост USB (paxbridge): ${b:-?}, порт $BRIDGE_PORT"
    fi
    if [ -f "$BTPLIST" ]; then
      if btloaded; then b=$(launchctl print gui/"$BT_UID"/"$BTLABEL" 2>/dev/null | sed -n 's/^[[:space:]]*state = //p' | head -1)
      else b="не загружен"; fi
      echo "  мост Bluetooth (btbridge): ${b:-?}, порт $BT_PORT, терминал $(bt_device)"
    fi
    cfg="$PREFIX/service/config/connector.xml"
    # многострочные XML-комментарии надо выкидывать целиком, иначе в сводку
    # попадает закомментированный блок альтернативного подключения
    strip_comments() { awk '/<!--/{c=1} !c; /-->/{c=0}' "$1"; }
    if [ -f "$cfg" ]; then
      echo
      echo "  конфиг: $cfg"
      strip_comments "$cfg" \
        | sed -nE 's#.*<(SERVERPORT|CONNECTION_TYPE|CONNECTION_PORT|IPADDRESS|IPADDRESSGUI)>(.*)</\1>.*#    \1 = \2#p'
    fi
    p=$(strip_comments "$cfg" 2>/dev/null | sed -n 's#.*<SERVERPORT>\([0-9]*\)</SERVERPORT>.*#\1#p' | head -1)
    p="${p:-9015}"
    printf '\nHTTP (127.0.0.1:%s): ' "$p"
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${p}/" || echo 000)
    case "$code" in
      200) echo "отвечает, идёт обмен с терминалом" ;;
      404) echo "отвечает, свободен" ;;
      000) echo "не отвечает" ;;
      *)   echo "код $code" ;;
    esac
    ;;
  log)
    shopt -s nullglob
    logs=("$PREFIX/service/log/"*.log)
    if [ ${#logs[@]} -eq 0 ]; then echo "логов пока нет в $PREFIX/service/log"; exit 0; fi
    tail -n 100 -f "${logs[@]}"
    ;;
  logdir)  echo "$PREFIX/service/log"; ls -la "$PREFIX/service/log" ;;
  config)  "${EDITOR:-nano}" "$PREFIX/service/config/connector.xml" ;;
  check)
    cfg="$PREFIX/service/config/connector.xml"
    [ -f "$cfg" ] || { echo "нет $cfg"; exit 1; }

    # Первым делом — well-formed ли XML. Классика: закомментировали блок,
    # внутри которого уже был комментарий. Вложенных комментариев в XML нет,
    # комментарий кончается на ПЕРВОМ '-->', остаток становится живым текстом,
    # файл ломается, и DC молча уезжает на значения по умолчанию.
    if command -v xmllint >/dev/null; then
      if err=$(xmllint --noout "$cfg" 2>&1); then
        echo "  ✓ XML корректен"
      else
        echo "  ✗ XML битый — DC проигнорирует файл и возьмёт значения по умолчанию:"
        printf '%s\n' "$err" | sed 's/^/      /'
        echo "      Частая причина: <!-- --> внутри другого <!-- -->."
        exit 1
      fi
    fi

    clean() { awk '/<!--/{c=1} !c; /-->/{c=0}' "$cfg"; }
    val() { clean | sed -n "s#.*<$1>\(.*\)</$1>.*#\1#p"; }
    rc=0

    # дубли тега — частая ловушка: раскомментировали альтернативу, а старый блок оставили
    for t in CONNECTION_TYPE CONNECTION_PORT IPADDRESS SERVERPORT; do
      n=$(val "$t" | grep -c . || true)
      if [ "$n" -gt 1 ]; then
        echo "  ✗ <$t> встречается $n раза — какое значение победит, не определено:"
        val "$t" | sed 's/^/      /'
        rc=1
      fi
    done

    ctype=$(val CONNECTION_TYPE | head -1)
    case "$ctype" in
      IP)
        addr=$(val IPADDRESS | head -1)
        if [ -z "$addr" ]; then
          echo "  ✗ CONNECTION_TYPE=IP, но <IPADDRESS> пуст или закомментирован"; rc=1
        elif ! printf '%s' "$addr" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]+$'; then
          echo "  ✗ IPADDRESS='$addr' — DC принимает только A.B.C.D:порт."
          echo "      Имя хоста не проходит валидацию и превращается в null."
          rc=1
        else
          echo "  ✓ IP-режим, адрес $addr"
          h=${addr%:*}; p=${addr##*:}
          if nc -z -G 3 "$h" "$p" 2>/dev/null; then
            echo "  ✓ TCP $h:$p принимает соединение"
          else
            echo "  ✗ TCP $h:$p не отвечает — терминал выключен, другой порт или файрвол"; rc=1
          fi
        fi
        ;;
      COM)
        port=$(val CONNECTION_PORT | head -1)
        if [ -z "$port" ]; then
          echo "  ✗ CONNECTION_TYPE=COM, но <CONNECTION_PORT> пуст"; rc=1
        elif [ ! -e "$port" ]; then
          echo "  ✗ CONNECTION_PORT='$port' — такого устройства нет. Доступные:"; ls -1 /dev/cu.* 2>/dev/null | sed 's/^/      /'
          rc=1
        else
          case "$port" in
            /dev/tty.*) echo "  ! '$port' — вариант tty.* блокируется до DCD, берите cu.*"; rc=1 ;;
            *) echo "  ✓ COM-режим, порт $port на месте" ;;
          esac
        fi
        ;;
      "") echo "  ✗ <CONNECTION_TYPE> не задан (или весь блок закомментирован)"; rc=1 ;;
      *)  echo "  ✗ CONNECTION_TYPE='$ctype' — допустимо только COM или IP"; rc=1 ;;
    esac

    gui=$(val IPADDRESSGUI | head -1)
    if [ -n "$gui" ]; then
      h=${gui%:*}; p=${gui##*:}
      if nc -z -G 2 "$h" "$p" 2>/dev/null; then
        echo "  ✓ приёмник диалогов $gui слушает"
      else
        echo "  ! IPADDRESSGUI=$gui никто не слушает — диалоги кассиру уйдут в никуда."
        echo "      Поднимите 'dcctl gui', укажите адрес своего ПО или удалите тег."
      fi
    fi
    exit $rc
    ;;
  fg)
    # Запуск в переднем плане из Terminal.
    # Главное применение: отличить настоящую сетевую ошибку от блокировки
    # macOS Local Network (TCC). LaunchDaemon живёт вне пользовательской
    # сессии, промпт показать некому, и подключения в локалку молча режутся;
    # запущенный из Terminal процесс наследует разрешение терминала.
    # Работает здесь, но не под launchd → это TCC, службу надо делать LaunchAgent.
    if loaded; then
      echo "служба загружена в launchd — сначала 'dcctl stop', иначе порт занят"
      exit 1
    fi
    echo "Ctrl-C для выхода. Логи также в $PREFIX/service/log"
    exec "$PREFIX/bin/dcservice-run.sh"
    ;;
  probe)
    # Проверить, что до терминала достучится именно Java (не nc — у него свои права).
    # Без аргументов берёт адрес из connector.xml.
    if [ -n "${2:-}" ]; then h="$2"; p="${3:?укажите порт}"
    else
      a=$(awk '/<!--/{c=1} !c; /-->/{c=0}' "$PREFIX/service/config/connector.xml" 2>/dev/null \
          | sed -n 's#.*<IPADDRESS>\(.*\)</IPADDRESS>.*#\1#p' | head -1)
      [ -n "$a" ] || { echo "в конфиге нет IPADDRESS — задайте: dcctl probe <ip> <порт>"; exit 1; }
      h=${a%:*}; p=${a##*:}
    fi
    if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then JAVA="$JAVA_HOME/bin/java"
    else JAVA="$(/usr/libexec/java_home -v 11+)/bin/java"; fi
    exec "$JAVA" "$PREFIX/tools/TcpProbe.java" "$h" "$p"
    ;;
  ports)   ls -1 /dev/cu.* 2>/dev/null || echo "последовательных портов не видно" ;;
  gui)
    # PosGUI не знает macOS: его getConfigFolder() для не-Windows/Linux отдаёт null,
    # отсюда "null/dcposgui.xml". Подменяем os.name → читает /etc/dcposgui.xml (симлинк).
    # Metal LAF — чтобы Swing не полез за GTK, решив по os.name, что он на Linux.
    if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
      JAVA="$JAVA_HOME/bin/java"
    else
      JAVA="$(/usr/libexec/java_home -v 11+)/bin/java"
    fi
    [ -e /etc/dcposgui.xml ] || { echo "нет /etc/dcposgui.xml — перезапустите install.sh"; exit 1; }
    exec "$JAVA" \
      -Dos.name=Linux \
      -Dswing.defaultlaf=javax.swing.plaf.metal.MetalLookAndFeel \
      -cp "$PREFIX/tools/cp/*:$PREFIX/tools/dcposgui.jar" \
      --module-path "$PREFIX/tools/lib" --add-modules com.sun.xml.bind \
      ru.inpas.DCPosGUI.Launcher
    ;;
  jssc)
    JAVA="$(/usr/libexec/java_home -v 11+)/bin/java"
    jar="$(ls "$PREFIX/lib/"jssc-*.jar 2>/dev/null | head -1)"
    [ -n "$jar" ] || { echo "нет jssc в $PREFIX/lib"; exit 1; }
    # dcservice.jar нужен в classpath: он отдаёт scijava, на который ссылается jssc
    "$JAVA" -Djava.library.path="$PREFIX/native" \
            -cp "$jar:$PREFIX/dcservice.jar" \
            "$PREFIX/tools/JsscCheck.java"
    ;;
  bridge)
    # Мост TCP <-> USB для терминалов PAX в стандартном USB-режиме (ttyPOS)
    case "${2:-status}" in
      start)
        if bloaded; then echo "мост уже загружен"
        else sudo launchctl bootstrap system "$BPLIST" && echo "мост запущен"; fi ;;
      stop)
        if bloaded; then
          sudo launchctl bootout system/"$BLABEL"
          for i in $(seq 1 20); do bloaded || break; sleep 0.5; done
          echo "мост остановлен"
        else echo "мост не загружен"; fi ;;
      restart)
        if bloaded; then sudo launchctl kickstart -k system/"$BLABEL" && echo "мост перезапущен"
        else sudo launchctl bootstrap system "$BPLIST" && echo "мост запущен"; fi ;;
      status)
        if bloaded; then
          launchctl print system/"$BLABEL" 2>/dev/null \
            | awk '/^[[:space:]]*(state|pid|last exit code|program) = / { if (!($1 in seen)) { seen[$1] = 1; sub(/^[[:space:]]*/, "  "); print } }'
        else echo "  launchd: мост не загружен"; fi
        if nc -z -G 2 127.0.0.1 "$BRIDGE_PORT" 2>/dev/null; then echo "  127.0.0.1:$BRIDGE_PORT слушается"
        else echo "  127.0.0.1:$BRIDGE_PORT НЕ слушается"; fi
        ioreg -p IOUSB -w0 2>/dev/null | grep -qiE "D2[0-9]0|PAX" \
          && echo "  терминал PAX на шине USB: да" || echo "  терминал PAX на шине USB: не виден"
        ;;
      log) tail -n 100 -f "$PREFIX/service/log/paxbridge.log" ;;
      probe)
        # мост держит USB-интерфейс, поэтому на время проверки его останавливаем
        was=0
        if bloaded; then
          was=1; sudo launchctl bootout system/"$BLABEL"
          for i in $(seq 1 20); do bloaded || break; sleep 0.5; done
        fi
        "$PREFIX/bridge/.venv/bin/python3" "$PREFIX/bridge/paxbridge.py" --probe
        rc=$?
        if [ "$was" = 1 ]; then sudo launchctl bootstrap system "$BPLIST"; fi
        exit $rc
        ;;
      *) echo "использование: dcctl bridge {start|stop|restart|status|log|probe}" ;;
    esac
    ;;
  bt)
    # Мост TCP <-> Bluetooth RFCOMM (вариант Д). Это LaunchAgent в сессии
    # пользователя: доступ к Bluetooth TCC выдаёт приложению этого пользователя.
    [ -f "$BTPLIST" ] || { echo "мост Bluetooth не установлен — нужен сопряжённый терминал, затем ./install.sh (или BT_DEVICE=… ./install.sh)"; exit 1; }
    case "${2:-status}" in
      start)
        if btloaded; then echo "мост Bluetooth уже загружен"
        else as_bt launchctl bootstrap gui/"$BT_UID" "$BTPLIST" && echo "мост Bluetooth запущен"; fi ;;
      stop)
        if btloaded; then
          as_bt launchctl bootout gui/"$BT_UID"/"$BTLABEL"
          for i in $(seq 1 20); do btloaded || break; sleep 0.5; done
          echo "мост Bluetooth остановлен"
        else echo "мост Bluetooth не загружен"; fi ;;
      restart)
        if btloaded; then as_bt launchctl kickstart -k gui/"$BT_UID"/"$BTLABEL" && echo "мост Bluetooth перезапущен"
        else as_bt launchctl bootstrap gui/"$BT_UID" "$BTPLIST" && echo "мост Bluetooth запущен"; fi ;;
      status)
        if btloaded; then
          launchctl print gui/"$BT_UID"/"$BTLABEL" 2>/dev/null \
            | awk '/^[[:space:]]*(state|pid|last exit code|program) = / { if (!($1 in seen)) { seen[$1] = 1; sub(/^[[:space:]]*/, "  "); print } }'
        else echo "  launchd: мост Bluetooth не загружен"; fi
        if nc -z -G 2 127.0.0.1 "$BT_PORT" 2>/dev/null; then echo "  127.0.0.1:$BT_PORT слушается"
        else echo "  127.0.0.1:$BT_PORT НЕ слушается"; fi
        echo "  терминал: $(bt_device)"
        ;;
      log) tail -n 100 -f "$PREFIX/service/log/btbridge.log" ;;
      probe|list)
        # Запуск через open: доступ к Bluetooth выдан BTBridge.app, а процесс,
        # запущенный прямо из терминала, получил бы права терминала.
        # На время теста мост останавливаем, чтобы не столкнуться с запросом DC.
        was=0
        if [ "$2" = probe ] && btloaded; then
          was=1; as_bt launchctl bootout gui/"$BT_UID"/"$BTLABEL"
          for i in $(seq 1 20); do btloaded || break; sleep 0.5; done
        fi
        out=$(mktemp /tmp/btbridge.XXXXXX); chmod 666 "$out"
        if [ "$2" = probe ]; then set -- --probe --device "$(bt_device)"; else set -- --list; fi
        as_bt open -n -W --stdout "$out" --stderr "$out" "$BT_APP" --args "$@"
        cat "$out"
        rc=0; [ "$1" = --probe ] && ! grep -q '^OK' "$out" && rc=1
        rm -f "$out"
        if [ "$was" = 1 ]; then as_bt launchctl bootstrap gui/"$BT_UID" "$BTPLIST"; fi
        exit $rc
        ;;
      *) echo "использование: dcctl bt {start|stop|restart|status|log|probe|list}" ;;
    esac
    ;;
  *) echo "использование: dcctl {start|stop|restart|status|check|fg|probe|log|logdir|config|ports|jssc|gui|bridge|bt}" ;;
esac
CTLEOF

$SUDO sed -i '' -e "s#__PREFIX__#${PREFIX}#g" -e "s#__BRIDGE_PORT__#${BRIDGE_PORT}#g" \
  -e "s#__BTPLIST__#${BTPLIST}#g" -e "s#__BT_PORT__#${BT_PORT}#g" \
  -e "s#__BT_UID__#${RUN_UID}#g" -e "s#__BT_USER__#${RUN_USER}#g" "$PREFIX/bin/dcctl"
$SUDO chmod 755 "$PREFIX/bin/dcctl"

# ------------------------------------------------------------------- launchd

$SUDO tee "$PLIST" >/dev/null <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>${PREFIX}/bin/dcservice-run.sh</string>
    </array>

    <key>EnvironmentVariables</key>
    <dict>
        <key>CSINSTALL</key>
        <string>${PREFIX}</string>
        <key>JAVA_HOME</key>
        <string>${JAVA_HOME_DIR}</string>
    </dict>

    <key>UserName</key>
    <string>${RUN_USER}</string>

    <key>WorkingDirectory</key>
    <string>${PREFIX}</string>

    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>30</integer>
    <key>ProcessType</key>
    <string>Interactive</string>

    <key>StandardOutPath</key>
    <string>${PREFIX}/service/log/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>${PREFIX}/service/log/launchd.err.log</string>
</dict>
</plist>
PLISTEOF

$SUDO chown root:wheel "$PLIST"
$SUDO chmod 644 "$PLIST"
plutil -lint "$PLIST" >/dev/null || die "plist не прошёл проверку"

# ----------------------------------------------- мост USB для PAX (paxbridge)
#
# Терминалы PAX в «стандартном» USB-режиме (ttyPOS) не создают COM-порта.
# На Linux их обслуживает модуль ядра ttyPos, под macOS — paxbridge.py: тот же
# протокол через libusb, без kext. Мост слушает 127.0.0.1:$BRIDGE_PORT, DC
# подключается к нему как к IP-терминалу. Ставим всегда: пока нет клиента,
# мост ничего не опрашивает и USB не трогает.
BRIDGE_OK=0
if [ -f "$KIT_DIR/paxbridge.py" ]; then
  msg "ставлю мост USB для PAX (paxbridge)"
  $SUDO mkdir -p "$PREFIX/bridge"
  $SUDO cp "$KIT_DIR/paxbridge.py" "$PREFIX/bridge/paxbridge.py"

  PY=$(command -v python3 || true)
  if [ -z "$PY" ]; then
    warn "python3 не найден — мост не установлен. Поставьте инструменты:  xcode-select --install"
  else
    if [ ! -x "$PREFIX/bridge/.venv/bin/python3" ]; then
      $SUDO "$PY" -m venv "$PREFIX/bridge/.venv" || die "не удалось создать venv для моста"
    fi
    if $SUDO "$PREFIX/bridge/.venv/bin/python3" -m pip install --quiet --disable-pip-version-check --no-cache-dir pyusb; then
      BRIDGE_OK=1
    else
      warn "pyusb не установился — мост не заработает"
    fi

    LIBUSB=""
    for c in /opt/homebrew/lib/libusb-1.0.dylib /usr/local/lib/libusb-1.0.dylib /opt/local/lib/libusb-1.0.dylib; do
      if [ -f "$c" ]; then LIBUSB="$c"; break; fi
    done
    LIBUSB_ARGS=""
    if [ -n "$LIBUSB" ]; then
      msg "libusb: $LIBUSB"
      # путь фиксируем явно: под launchd окружения шелла нет
      LIBUSB_ARGS="        <string>--libusb</string>
        <string>${LIBUSB}</string>"
    else
      warn "libusb не найден — поставьте:  brew install libusb   и перезапустите install.sh"
      BRIDGE_OK=0
    fi

    $SUDO tee "$BPLIST" >/dev/null <<BPLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${BLABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>${PREFIX}/bridge/.venv/bin/python3</string>
        <string>${PREFIX}/bridge/paxbridge.py</string>
        <string>--serve</string>
        <string>--host</string>
        <string>127.0.0.1</string>
        <string>--port</string>
        <string>${BRIDGE_PORT}</string>
${LIBUSB_ARGS}
    </array>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PYTHONUNBUFFERED</key>
        <string>1</string>
    </dict>

    <key>UserName</key>
    <string>${RUN_USER}</string>

    <key>WorkingDirectory</key>
    <string>${PREFIX}/bridge</string>

    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>ProcessType</key>
    <string>Interactive</string>

    <key>StandardOutPath</key>
    <string>${PREFIX}/service/log/paxbridge.log</string>
    <key>StandardErrorPath</key>
    <string>${PREFIX}/service/log/paxbridge.log</string>
</dict>
</plist>
BPLISTEOF
    $SUDO chown root:wheel "$BPLIST"
    $SUDO chmod 644 "$BPLIST"
    plutil -lint "$BPLIST" >/dev/null || die "plist моста не прошёл проверку"
  fi
fi

# ------------------------------------------------- мост Bluetooth (btbridge)
#
# Вариант Д: терминал по Bluetooth через собственный мост RFCOMM <-> TCP.
# Последовательный порт /dev/cu.<терминал> на macOS 26 идёт через мост Serial
# Port в bluetoothd, а тот ломается от ручного «Подключить» и от повторного
# открытия порта (подробности — в btbridge.swift и README). btbridge открывает
# канал RFCOMM сам, DC подключается к нему как к IP-терминалу.
#
# Доступ к Bluetooth TCC выдаёт приложению в сессии пользователя, поэтому мост —
# это BTBridge.app под LaunchAgent пользователя RUN_USER, а не LaunchDaemon.
# Ставим, только если есть сопряжённый Bluetooth-терминал (или задан BT_DEVICE):
# при старте мост запрашивает доступ к Bluetooth, и тем, кому он не нужен,
# этот запрос ни к чему.
if [ -z "$BT_DEVICE" ]; then
  # сопряжённые устройства с последовательным портом, кроме входящего порта самого мака
  BT_FOUND=$(ioreg -r -d1 -c IOBluetoothDevice -l -w0 2>/dev/null | awk -F'"' '
    function flush() {
      if (name != "" && name != "Bluetooth-Incoming-Port" && addr != "")
        print substr(addr,1,2) "-" substr(addr,3,2) "-" substr(addr,5,2) "-" substr(addr,7,2) "-" substr(addr,9,2) "-" substr(addr,11,2), name
      name = ""; addr = ""
    }
    /\+-o / { flush() }
    /"BTTTYName" =/ { name = $4 }
    /"BTAddress" =/ { addr = $0; sub(/.*</, "", addr); sub(/>.*/, "", addr) }
    END { flush() }' || true)
  case "$(printf '%s' "$BT_FOUND" | grep -c .)" in
    0) ;;
    1) BT_DEVICE="${BT_FOUND%% *}"; msg "Bluetooth-терминал: ${BT_FOUND#* } ($BT_DEVICE)" ;;
    *) warn "сопряжённых Bluetooth-устройств с последовательным портом несколько — мост Bluetooth не ставлю."
       printf '%s\n' "$BT_FOUND" | sed 's/^/      /'
       warn "Выберите терминал и повторите:  BT_DEVICE=<адрес> ./install.sh" ;;
  esac
fi

BT_OK=0
if [ -n "$BT_DEVICE" ] && [ -f "$KIT_DIR/btbridge.swift" ]; then
  if ! command -v swiftc >/dev/null; then
    warn "swiftc не найден — мост Bluetooth не собран. Поставьте инструменты:  xcode-select --install"
  else
    msg "собираю мост Bluetooth (btbridge)"
    BT_TMP="$(mktemp -d)"
    mkdir -p "$BT_TMP/BTBridge.app/Contents/MacOS"
    if swiftc -O -o "$BT_TMP/BTBridge.app/Contents/MacOS/btbridge" "$KIT_DIR/btbridge.swift" -framework IOBluetooth; then
      cat > "$BT_TMP/BTBridge.app/Contents/Info.plist" <<BTINFOEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>${BTLABEL}</string>
    <key>CFBundleName</key>
    <string>BTBridge</string>
    <key>CFBundleExecutable</key>
    <string>btbridge</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Мост DC Service: связь с платёжным терминалом по Bluetooth.</string>
</dict>
</plist>
BTINFOEOF
      codesign -s - -f --identifier "$BTLABEL" "$BT_TMP/BTBridge.app" >/dev/null 2>&1 \
        || warn "codesign не подписал BTBridge.app — доступ к Bluetooth может не выдаться"
      # Разрешение TCC привязано к подписи сборки, а ad-hoc-подпись меняется вместе
      # с бинарником. Со старой записью TCC молча отказывает и заново не спрашивает,
      # поэтому при новой сборке запись сбрасываем — мост спросит доступ при старте.
      if cmp -s "$BT_TMP/BTBridge.app/Contents/MacOS/btbridge" "$BT_APP/Contents/MacOS/btbridge"; then
        msg "сборка моста не изменилась — разрешение на Bluetooth сохраняется"
      else
        $SUDO rm -rf "$BT_APP"
        $SUDO mkdir -p "$PREFIX/btbridge"
        $SUDO cp -R "$BT_TMP/BTBridge.app" "$PREFIX/btbridge/"
        $SUDO xattr -dr com.apple.quarantine "$BT_APP" 2>/dev/null || true
        $AS_USER tccutil reset BluetoothAlways "$BTLABEL" >/dev/null 2>&1 || true
        BT_NEW=1
      fi
      BT_OK=1
    else
      warn "мост Bluetooth не собрался — смотрите ошибки swiftc выше"
    fi
    rm -rf "$BT_TMP"
  fi
fi

if [ "$BT_OK" -eq 1 ]; then
  $AS_USER mkdir -p "$(dirname "$BTPLIST")"
  $AS_USER tee "$BTPLIST" >/dev/null <<BTPLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${BTLABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>${BT_APP}/Contents/MacOS/btbridge</string>
        <string>--serve</string>
        <string>--host</string>
        <string>127.0.0.1</string>
        <string>--port</string>
        <string>${BT_PORT}</string>
        <string>--device</string>
        <string>${BT_DEVICE}</string>
    </array>

    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>ProcessType</key>
    <string>Interactive</string>

    <key>StandardOutPath</key>
    <string>${PREFIX}/service/log/btbridge.log</string>
    <key>StandardErrorPath</key>
    <string>${PREFIX}/service/log/btbridge.log</string>
</dict>
</plist>
BTPLISTEOF
  plutil -lint "$BTPLIST" >/dev/null || die "plist моста Bluetooth не прошёл проверку"
fi

# Права. Файлы дистрибутива могут лежать с режимом 600 — sudo cp копирует его как есть,
# и тогда jar'ы читает только root, а служба крутится от $RUN_USER и падает на старте.
msg "выставляю права"
$SUDO chmod -R a+rX "$PREFIX"
$SUDO chmod 755 "$PREFIX/bin/"*
$SUDO chown -R "${RUN_USER}:${RUN_GROUP}" "$PREFIX/service"
$SUDO chmod 644 "$PREFIX/service/config/connector.xml"
[ -f "$PREFIX/service/config/dcposgui.xml" ] && $SUDO chmod 644 "$PREFIX/service/config/dcposgui.xml"

# --------------------------------------------------------------- проверка jssc

msg "проверяю загрузку нативной библиотеки jssc"
if "$JAVA" -Djava.library.path="$PREFIX/native" \
           -cp "$PREFIX/lib/$JSSC_JAR:$PREFIX/dcservice.jar" \
           "$PREFIX/tools/JsscCheck.java"; then
  :
else
  warn "JsscCheck не отработал — смотрите вывод выше"
fi

# ------------------------------------------------------------------- финал

# Перезапуск задания launchd. bootout асинхронен: команда возвращается раньше,
# чем задание реально выгружено, и немедленный bootstrap падает с
# «5: Input/output error». Поэтому ждём выгрузки и повторяем bootstrap.
# Функция никогда не валит установку — при неудаче только предупреждает.
relaunch() {
  local label="$1" plist="$2" i err=""
  $SUDO launchctl bootout system/"$label" 2>/dev/null || true
  for i in $(seq 1 20); do
    launchctl print system/"$label" >/dev/null 2>&1 || break
    sleep 0.5
  done
  for i in 1 2 3; do
    if err=$($SUDO launchctl bootstrap system "$plist" 2>&1); then
      return 0
    fi
    sleep 1
  done
  warn "не удалось загрузить $label: $err"
  warn "попробуйте вручную:  sudo launchctl bootstrap system $plist"
  return 1
}

echo
# мост — первым: DC может быть настроен ходить в терминал через него
if [ -f "$BPLIST" ]; then
  if relaunch "$BLABEL" "$BPLIST"; then
    if [ "$BRIDGE_OK" -eq 1 ]; then
      msg "мост USB запущен на 127.0.0.1:$BRIDGE_PORT  (для PAX по USB: CONNECTION_TYPE=IP, IPADDRESS=127.0.0.1:$BRIDGE_PORT)"
    else
      warn "мост USB загружен, но без pyusb/libusb работать не будет — см. предупреждения выше"
    fi
  fi
fi

# мост Bluetooth — LaunchAgent, грузится в сессию RUN_USER
if [ "$BT_OK" -eq 1 ]; then
  if launchctl print "gui/$RUN_UID" >/dev/null 2>&1; then
    $AS_USER launchctl bootout "gui/$RUN_UID/$BTLABEL" 2>/dev/null || true
    for i in $(seq 1 20); do
      launchctl print "gui/$RUN_UID/$BTLABEL" >/dev/null 2>&1 || break
      sleep 0.5
    done
    if err=$($AS_USER launchctl bootstrap "gui/$RUN_UID" "$BTPLIST" 2>&1); then
      msg "мост Bluetooth запущен на 127.0.0.1:$BT_PORT, терминал $BT_DEVICE  (вариант Д: CONNECTION_TYPE=IP, IPADDRESS=127.0.0.1:$BT_PORT)"
      if [ "${BT_NEW:-0}" -eq 1 ]; then
        warn "macOS спросит, разрешить ли BTBridge доступ к Bluetooth, — разрешите."
        warn "Проверка связи с терминалом:  $PREFIX/bin/dcctl bt probe"
      fi
    else
      warn "не удалось загрузить мост Bluetooth: $err"
    fi
  else
    warn "$RUN_USER не вошёл в систему — мост Bluetooth запустится при его входе"
  fi
fi

if [ "$FRESH_CONFIG" -eq 1 ]; then
  warn "connector.xml создан из шаблона — ОТРЕДАКТИРУЙТЕ его перед стартом:"
  echo "    sudo $PREFIX/bin/dcctl config"
  echo
  echo "  Что задать (оставьте ровно один вариант):"
  echo "    А  USB-CDC / COM:  CONNECTION_TYPE=COM, CONNECTION_PORT=/dev/cu.*"
  echo "    Б  сеть:           CONNECTION_TYPE=IP,  IPADDRESS=<ip терминала>:<порт>"
  echo "    В  PAX по USB:     CONNECTION_TYPE=IP,  IPADDRESS=127.0.0.1:$BRIDGE_PORT"
  echo "    Д  Bluetooth:      CONNECTION_TYPE=IP,  IPADDRESS=127.0.0.1:$BT_PORT  (мост btbridge)"
  echo
  echo "  Видимые последовательные порты:"
  ls -1 /dev/cu.* 2>/dev/null | sed 's/^/    /' || echo "    (нет)"
  echo
  echo "  Затем:  sudo $PREFIX/bin/dcctl start"
else
  if relaunch "$LABEL" "$PLIST"; then
    msg "служба DC запущена"
  fi
fi

echo
msg "готово. Управление:  $PREFIX/bin/dcctl {start|stop|restart|status|log|ports|jssc|bridge|bt}"
msg "для удобства:  sudo ln -sf $PREFIX/bin/dcctl /usr/local/bin/dcctl"
