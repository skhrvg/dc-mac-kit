#!/bin/bash
# SPDX-License-Identifier: MIT
#
# Smoke-тесты HTTP-интеграции с DC Service.
# Всё общение — windows-1251, как требует сервис.
#
#   ./dc-test.sh status              статус DC
#   ./dc-test.sh test                тест связи с терминалом (операция 26)
#   ./dc-test.sh sale 1200           оплата на 12.00 руб (сумма в копейках)
#   ./dc-test.sh void 1200 [RRN [код]]  отмена на 12.00 руб (операция 4); RRN (поле 14)
#                                    и код авторизации (поле 13) — из ответа на оплату,
#                                    чтобы отменить конкретную операцию
#   ./dc-test.sh return 1200         возврат (операция 29)
#   ./dc-test.sh settle              сверка итогов (операция 59)
#   ./dc-test.sh report              краткий отчёт (63 / 65=20)
#   ./dc-test.sh receipt             копия последнего чека (63 / 64=1 / 65=22)
#   ./dc-test.sh close               прервать текущую операцию
#   ./dc-test.sh slip                разобрать поле 90 в читаемые чеки (со stdin)
#   ./dc-test.sh tid                 показать TerminalID (--clear сбрасывает кэш)
#   ./dc-test.sh raw ./my.xml        отправить произвольный XML
#   ./dc-test.sh gui [1-5]           показать окно кассира без терминала: шлёт в
#                                    IPADDRESSGUI (DC PosGUI) тот же XML, что шлёт DC
#
# Флаги/переменные:
#   -j | DC_JSON=1        слать и принимать JSON вместо XML
#   DC_HOST=127.0.0.1     хост DC
#   DC_PORT=9015          порт DC (SERVERPORT из connector.xml)
#   DC_TID=00199991       TerminalID (поле 27). Шлётся во ВСЕХ операциях, включая
#                         тест связи. Если не задан — берётся из кэша, а при его
#                         отсутствии скрипт спросит терминал операцией 26 (в этот
#                         единственный раз терминал покажет «не получен terminal id»).
#   DC_IPADDR=ip:port     маршрутизировать на конкретный терминал по TCP/IP
#   DC_NCOM=/dev/cu.xxx   маршрутизировать на конкретный COM-терминал
#   DC_TIMEOUT=180        таймаут операции в секундах (поле <timeout>)
#   DC_GUI=ip:port        приёмник окон кассира для команды gui; по умолчанию
#                         IPADDRESSGUI из /etc/connector.xml, иначе 127.0.0.1:6000
#
set -uo pipefail

HOST="${DC_HOST:-127.0.0.1}"
PORT="${DC_PORT:-9015}"
TID="${DC_TID:-}"
OP_TIMEOUT="${DC_TIMEOUT:-180}"
JSON="${DC_JSON:-0}"
CURRENCY="${DC_CURRENCY:-643}"

if [ "${1:-}" = "-j" ]; then JSON=1; shift; fi

CMD="${1:-status}"; shift || true

command -v iconv >/dev/null || { echo "нужен iconv"; exit 1; }

session_id() { date +%s%H%M%S; }
trx_id()     { date +%H%M%S; }

# --------------------------------------------------------------- транспорт

post() {
  local body="$1" ctype accept
  if [ "$JSON" = "1" ]; then
    ctype='application/json; charset=windows-1251'
    accept='application/json'
  else
    ctype='text/xml; charset=windows-1251'
    accept='text/xml'
  fi

  printf '%s' "$body" \
    | iconv -f UTF-8 -t CP1251 \
    | curl -sS --max-time $((OP_TIMEOUT + 30)) \
        -X POST "http://${HOST}:${PORT}/" \
        -H "Content-Type: ${ctype}" \
        -H "Accept: ${accept}" \
        -H 'Accept-Charset: windows-1251' \
        --data-binary @- \
    | iconv -f CP1251 -t UTF-8
  echo
}

# Маршрутизация на конкретный терминал (иначе берётся из connector.xml)
routing_xml() {
  [ -n "${DC_IPADDR:-}" ] && printf '    <ipaddr>%s</ipaddr>\n' "$DC_IPADDR"
  [ -n "${DC_NCOM:-}"   ] && printf '    <ncom>%s</ncom>\n' "$DC_NCOM"
  return 0
}
routing_json() {
  [ -n "${DC_IPADDR:-}" ] && printf '  "ipaddr": "%s",\n' "$DC_IPADDR"
  [ -n "${DC_NCOM:-}"   ] && printf '  "ncom": "%s",\n' "$DC_NCOM"
  return 0
}

# build <id=value> ... — собирает запрос в текущем формате
build() {
  local sid; sid="$(session_id)"
  if [ "$JSON" = "1" ]; then
    local first=1
    printf '{\n  "fields": [\n'
    for kv in "$@"; do
      [ $first -eq 0 ] && printf ',\n'
      first=0
      printf '    { "id": %s, "hex": false, "value": "%s" }' "${kv%%=*}" "${kv#*=}"
    done
    printf '\n  ],\n'
    routing_json
    printf '  "timeout": "%s",\n  "sessionID": "%s"\n}\n' "$OP_TIMEOUT" "$sid"
  else
    printf '<?xml version="1.0" encoding="windows-1251"?>\n<request>\n'
    for kv in "$@"; do
      printf '    <field id="%s">%s</field>\n' "${kv%%=*}" "${kv#*=}"
    done
    routing_xml
    printf '    <timeout>%s</timeout>\n    <sessionID>%s</sessionID>\n</request>\n' "$OP_TIMEOUT" "$sid"
  fi
}

# TerminalID (поле 27). Терминал ждёт его в каждой операции; без него показывает
# «от кассы не получен terminal id», а содержательные операции отклоняет.
# Если DC_TID не задан и кэша нет, спрашиваем терминал операцией 26 и кэшируем.
tid_cache="${TMPDIR:-/tmp}/dc-tid-${HOST}_${PORT}"

discover_tid() {
  if [ -s "$tid_cache" ]; then cat "$tid_cache"; return 0; fi
  local req resp tid saved
  req=$(printf '<?xml version="1.0" encoding="windows-1251"?>\n<request>\n    <field id="25">26</field>\n    <timeout>%s</timeout>\n    <sessionID>%s</sessionID>\n</request>\n' \
        "$OP_TIMEOUT" "$(session_id)")
  saved="$JSON"; JSON=0
  resp=$(post "$req")
  JSON="$saved"
  tid=$(printf '%s' "$resp" | sed -n 's#.*<field id="27">\([^<]*\)</field>.*#\1#p' | head -1)
  if [ -n "$tid" ]; then
    printf '%s' "$tid" > "$tid_cache"
    printf '%s' "$tid"
    return 0
  fi
  return 1
}

run_op() {
  local -a f=()
  for a in "$@"; do f+=("$a"); done
  # Поле 27 нужно терминалу на ЛЮБОЙ операции, включая тест связи: без него
  # операция может пройти, но терминал покажет «от кассы не получен terminal id».
  # Для теста связи TID берём только если он уже известен (иначе вышел бы круг:
  # узнаём TID как раз тестом связи); для остальных операций — узнаём при нужде.
  if [ -z "$TID" ]; then
    if [[ " $* " == *" 25=26 "* ]]; then
      [ -s "$tid_cache" ] && TID=$(cat "$tid_cache")
    elif [ -s "$tid_cache" ]; then
      TID=$(cat "$tid_cache")
    else
      TID=$(discover_tid) || true
      [ -n "$TID" ] && echo "TerminalID определён автоматически: $TID  (кэш: $tid_cache)"
    fi
  fi
  [ -n "$TID" ] && f+=("27=$TID")
  local req resp; req="$(build "${f[@]}")"
  echo "--- запрос -------------------------------------------------"
  printf '%s\n' "$req"
  echo "--- ответ --------------------------------------------------"
  resp=$(post "$req")
  printf '%s\n' "$resp"

  # запоминаем TerminalID из любого ответа, если его ещё не знали
  if [ ! -s "$tid_cache" ]; then
    local t
    t=$(printf '%s' "$resp" | sed -n 's#.*<field id="27">\([^<]*\)</field>.*#\1#p' | head -1)
    [ -n "$t" ] && printf '%s' "$t" > "$tid_cache" && echo "(TerminalID $t запомнен: $tid_cache)"
  fi
}

# ----------------------------------------------------------------- команды

case "$CMD" in
  status)
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${HOST}:${PORT}/" || echo 000)
    case "$code" in
      200) echo "HTTP 200 — DC сейчас обменивается с терминалом (занят)" ;;
      404) echo "HTTP 404 — DC свободен и ждёт команду" ;;
      000) echo "нет ответа от ${HOST}:${PORT} — служба не запущена или порт другой" ;;
      *)   echo "неожиданный код: $code" ;;
    esac
    ;;

  test)    run_op 25=26 ;;                                  # тест связи
  sale)    run_op "0=${1:?укажите сумму в копейках}" "4=${CURRENCY}" 25=1  "26=$(trx_id)" ;;
  void)    run_op "0=${1:?укажите сумму в копейках}" "4=${CURRENCY}" 25=4  "26=$(trx_id)" \
                  ${2:+"14=$2"} ${3:+"13=$3"} ;;                  # + RRN и код авторизации
  return)  run_op "0=${1:?укажите сумму в копейках}" "4=${CURRENCY}" 25=29 "26=$(trx_id)" ;;
  settle)  run_op 25=59 ;;                                  # сверка итогов
  report)  run_op 25=63 65=20 ;;                            # краткий отчёт
  long)    run_op 25=63 65=21 ;;                            # длинный отчёт
  receipt) run_op 25=63 64=1 65=22 ;;                       # копия последнего чека
  keys)    run_op 25=76 ;;                                  # загрузка ключей

  close)
    [ -n "$TID" ] || TID=$(discover_tid) || true
    [ -n "$TID" ] || { echo "не удалось определить TerminalID — задайте DC_TID=<id>"; exit 1; }
    curl -sS -i --max-time 15 \
      -X POST "http://${HOST}:${PORT}/command/closeOpenConnection?TerminalId=${TID}" \
      | iconv -f CP1251 -t UTF-8
    echo
    ;;

  tid)
    if [ -n "$TID" ]; then echo "DC_TID задан явно: $TID"; fi
    if [ -s "$tid_cache" ]; then echo "в кэше: $(cat "$tid_cache")  ($tid_cache)"; fi
    if [ "${1:-}" = "--clear" ]; then rm -f "$tid_cache"; echo "кэш очищен"; fi
    if [ -z "$TID" ] && [ ! -s "$tid_cache" ]; then
      t=$(discover_tid) && echo "терминал сообщил: $t" || echo "не удалось получить TerminalID"
    fi
    ;;

  slip)
    # Разбор поля 90 (образ чека). Читает ответ DC со stdin или из файла:
    #   ./dc-test.sh sale 100 | ./dc-test.sh slip
    # Структура: подряд идущие блоки "0xNN^^<текст>~", строки разделены CR,
    # который в XML приезжает как &#13;. Всё на awk — BSD sed на macOS
    # не умеет \n в замене, а python3 есть не на каждой машине.
    cat "${1:-/dev/stdin}" | awk '
      { all = all $0 "\n" }
      END {
        tag = "<field id=\"90\">"
        i = index(all, tag)
        if (i == 0) { print "в ответе нет поля 90 (образа чека)"; exit 1 }
        r = substr(all, i + length(tag))
        j = index(r, "</field>")
        if (j > 0) r = substr(r, 1, j - 1)
        gsub(/&#13;\r?\n?/, "\n", r)
        gsub(/&lt;/,  "<",    r)
        gsub(/&gt;/,  ">",    r)
        gsub(/&amp;/, "\\&",  r)
        # Режем по "~" вручную: split() в BWK awk (он стоит на macOS) при
        # односимвольном разделителе режет ЕЩЁ И по переводам строки —
        # в исходнике: while (*s != sep && *s != '\n' && *s != '\0').
        c = 0
        while (length(r) > 0) {
          p = index(r, "~")
          if (p == 0) { blk = r; r = "" }
          else        { blk = substr(r, 1, p - 1); r = substr(r, p + 1) }
          if (blk !~ /[^ \t\r\n]/) continue
          tag = ""
          if (match(blk, /0[xX][0-9A-Fa-f]+\^\^/)) tag = substr(blk, RSTART, RLENGTH - 2)
          sub(/^[ \t\r\n]*0[xX][0-9A-Fa-f]+\^\^\n?/, "", blk)   # отступы строк чека не трогаем
          c++
          printf "\n=========== чек %d%s ===========\n%s\n", c, (tag != "" ? " (" tag ")" : ""), blk
        }
        if (c == 0) print "поле 90 пустое"
      }'
    ;;

  raw)
    f="${1:?укажите файл с телом запроса}"
    [ -f "$f" ] || { echo "нет файла $f"; exit 1; }
    post "$(cat "$f")"
    ;;

  gui)
    # Окно кассира в обход терминала. DC шлёт окна, только когда терминал сам
    # присылает запрос кассиру (операция 52), — тест связи этого не делает.
    # Эта команда проверяет вторую половину цепочки: приёмник по IPADDRESSGUI
    # слушает, рисует окно и отвечает. Формат — как у DC (GUIXmlDialog):
    # XML в windows-1251, приёмник читает до </request>, отвечает и закрывает.
    addr="${DC_GUI:-}"
    if [ -z "$addr" ] && [ -r /etc/connector.xml ]; then
      addr=$(sed -n 's#.*<IPADDRESSGUI>[[:space:]]*\([^<]*[^<[:space:]]\)[[:space:]]*</IPADDRESSGUI>.*#\1#p' /etc/connector.xml | head -1)
    fi
    addr="${addr:-127.0.0.1:6000}"
    case "${1:-2}" in
      1) body='<type>1</type><data>1^^Проверка^Информационное окно от dc-test.sh</data><timeout>10</timeout>' ;;
      2) body='<type>2</type><data>2^3^Проверка^Окно кассира работает? Нажмите OK или Да</data><timeout>30</timeout>' ;;
      3) body='<type>3</type><data>2^5^Проверка^Выберите вариант</data><adata>Первый;Второй;Третий</adata><timeout>30</timeout>' ;;
      4) body='<type>4</type><data>2^5^Проверка^Введите до шести цифр</data><adata>000999</adata><timeout>30</timeout>' ;;
      # DC PosGUI не печатает, а показывает окно — и требует тот же формат
      # «уровень^кнопки^заголовок^текст»; голый текст отвергает с кодом 64.
      5) body='<type>5</type><data>1^1^Печать^ПРОВЕРКА ПЕЧАТИ ОТ dc-test.sh</data>' ;;
      *) echo "тип окна: 1 информация, 2 подтверждение, 3 выбор, 4 ввод, 5 печать"; exit 1 ;;
    esac
    command -v nc >/dev/null || { echo "нужен nc"; exit 1; }
    echo "--- окно -> ${addr} ------------------------------------"
    printf '<request>%s</request>\n' "$body"
    echo "--- ответ приёмника ----------------------------------------"
    # Ответ PosGUI — ASCII (коды кнопок), кроме введённого текста в окне 4.
    resp=$(printf '<?xml version="1.0" encoding="windows-1251"?><request>%s</request>' "$body" \
             | iconv -f UTF-8 -t CP1251 \
             | nc -w 60 "${addr%:*}" "${addr##*:}")
    rc=$?
    if [ -z "$resp" ]; then
      echo "(пусто, nc rc=$rc) — по адресу ${addr} никто не слушает или не ответил."
      echo "Запущен ли DC PosGUI (dcctl gui)? Совпадает ли адрес с <listen> в /etc/dcposgui.xml?"
      exit 1
    fi
    printf '%s\n' "$resp"
    code=$(printf '%s' "$resp" | sed -n 's#.*<data>\([^<]*\)</data>.*#\1#p' | head -1)
    case "$code" in
      0)  echo "=> 0: окно показано (ответа кассира не требовалось) / напечатано" ;;
      1)  echo "=> 1: нажата OK" ;;
      2)  echo "=> 2: нажата Да" ;;
      4)  echo "=> 4: нажата Отмена" ;;
      8)  echo "=> 8: нажата Нет" ;;
      16) echo "=> 16: вышло время окна" ;;
      32) echo "=> 32: окно закрыто по Esc" ;;
      64) echo "=> 64: приёмник не смог показать окно (ошибка параметров)" ;;
    esac
    ;;

  *)
    # справка — шапка файла от описания до set -uo, без SPDX-строки
    sed -n '/Smoke-тесты/,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
    ;;
esac
