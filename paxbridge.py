#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Протокол восстановлен по модулю ядра ttyPos из LinuxDriver_V317 (PAX),
# который распространяется под GPL (MODULE_LICENSE("GPL")). Этот файл —
# переложение того же протокола на Python для userspace, поэтому он
# распространяется на тех же условиях: GNU GPL версии 2 или (на ваш выбор)
# любой более поздней. Текст лицензии: LICENSES/GPL-2.0-or-later.txt
"""
paxbridge — мост TCP <-> USB-канал терминалов PAX (протокол ttyPos) для macOS.

Зачем
-----
В «стандартном» USB-режиме терминалы PAX (включая Prolin-модели вроде D230)
не притворяются последовательным портом. На Linux их обслуживает модуль ядра
ttyPos из LinuxDriver_V317 и отдаёт как /dev/ttyPos*. Под macOS такого модуля
нет — но весь протокол живёт в userspace поверх двух bulk-эндпоинтов, и его
можно говорить через libusb без kext. Мост поднимает TCP-порт, DC Service
подключается к нему как к IP-терминалу (CONNECTION_TYPE=IP), а байты уходят
в терминал по USB.

Протокол (восстановлен по ttyPos.c / ttyPos.h)
---------------------------------------------
  пакет   = SeqNo:1 | ReqType:1 | Len:2 (LE) | Data[Len]
  ReqType = 0 WRITE, 1 READ, 2 STATUS, 3 RESET, 4 MAXDATA
  SeqNo   — 4 бита, растёт на каждую новую команду (на повторах — прежний)

  целостность:
    bcdDevice >= 0x300 — Len += 1, в конец Data дописывается XOR
                         всего пакета (заголовок уже с новым Len + данные);
                         в ответе XOR по Len+4 байтам обязан дать 0
    иначе              — 8-битный XOR (Len + Data + младшие полубайты
                         SeqNo/ReqType) раскладывается по старшим
                         полубайтам SeqNo и ReqType

  старт:
    bcdDevice >= 0x300 — vendor control OUT: bmRequestType=0x40,
                         bRequest=0x01, wValue=0x0300 («set host»)
    bcdDevice >= 0x200 — MAXDATA -> uint16 макс. длина Data

  опрос:
    STATUS         -> 4 x uint32 LE: TxBufSize, RxBufSize, TxLeft, RxLeft
                      TxLeft — сколько байт терминал хочет отдать нам,
                      RxLeft — сколько он готов принять
    READ  n        -> данные (или STATUS, если отдавать уже нечего)
    WRITE data     -> STATUS

Режимы
------
  paxbridge.py --list               все USB-устройства (ищем PAX)
  paxbridge.py --probe              подключиться, согласовать, спросить STATUS
  paxbridge.py --serve [--port N]   мост TCP <-> USB (для DC Service)
  paxbridge.py --selftest           проверка протокола на эмуляторе, без железа
  paxbridge.py ... --libusb PATH    явный путь к libusb-1.0.dylib

Зависимости: libusb (brew install libusb) и pyusb (pip install pyusb).
"""

import argparse
import logging
import select
import socket
import struct
import sys
import time

log = logging.getLogger("paxbridge")

# --------------------------------------------------------------- константы

KNOWN_DEVICES = [
    (0x2FB8, 0x1101, "PAX Prolin"),
    (0x2FB8, 0x110B, "PAX Prolin (double)"),
    (0x2FB8, 0x110E, "PAX Prolin (HID composite)"),
    (0x2FB8, 0x0101, "PAX Prolin (monitor)"),
    (0x1234, 0x0101, "PAX (старый VID)"),
]

WRITE, READ, STATUS, RESET, MAXDATA = 0, 1, 2, 3, 4
REQ_NAMES = {WRITE: "WRITE", READ: "READ", STATUS: "STATUS", RESET: "RESET", MAXDATA: "MAXDATA"}

MAX_RETRY = 5            # MAX_RETRY_S в драйвере
DEFAULT_MAXDATA = 508    # pdx->maxdata по умолчанию
MAX_DATA_CAP = 65532     # sizeof(ST_BULK_IO.Data)
USB_TIMEOUT_MS = 1000    # timeout_jiffies = 1000 мс

# Под launchd окружения шелла нет, а Homebrew на Apple Silicon кладёт libusb
# в /opt/homebrew/lib, куда загрузчик по умолчанию не заглядывает. Поэтому
# ищем библиотеку явно: --libusb, затем PAXBRIDGE_LIBUSB, затем типовые пути.
LIBUSB_CANDIDATES = [
    "/opt/homebrew/lib/libusb-1.0.dylib",   # Homebrew, Apple Silicon
    "/usr/local/lib/libusb-1.0.dylib",      # Homebrew, Intel
    "/opt/local/lib/libusb-1.0.dylib",      # MacPorts
]


def get_backend(explicit=None):
    import os
    try:
        import usb.backend.libusb1 as libusb1
    except ImportError:
        sys.exit("нужен pyusb:  pip install pyusb   (и libusb:  brew install libusb)")
    path = explicit or os.environ.get("PAXBRIDGE_LIBUSB")
    for cand in ([path] if path else LIBUSB_CANDIDATES):
        if cand and os.path.exists(cand):
            be = libusb1.get_backend(find_library=lambda _name, c=cand: c)
            if be is not None:
                log.debug("libusb: %s", cand)
                return be
    if path:
        sys.exit(f"libusb не загрузился из {path}")
    be = libusb1.get_backend()            # пусть pyusb поищет сам
    if be is None:
        sys.exit("не найден libusb. Поставьте:  brew install libusb   "
                 "(или укажите --libusb /путь/libusb-1.0.dylib)")
    return be


class ProtoError(Exception):
    pass


def hexdump(data, limit=96):
    b = bytes(data[:limit])
    hx = b.hex(" ")
    asc = "".join(chr(c) if 32 <= c < 127 else "." for c in b)
    tail = f" …(+{len(data) - limit})" if len(data) > limit else ""
    return f"{hx}  |{asc}|{tail}"


def xor_all(buf):
    x = 0
    for c in buf:
        x ^= c
    return x


# ------------------------------------------------------ кодирование пакетов

def pack(seq, req, data, xor_mode):
    """Собрать пакет так же, как ProcessCommand() + SetChecksum()."""
    seq &= 0x0F
    req &= 0x0F
    data = bytes(data)
    if xor_mode:
        ln = len(data) + 1                      # Len += 1 ДО подсчёта XOR
        body = bytes([seq, req]) + struct.pack("<H", ln) + data
        return body + bytes([xor_all(body)])
    ln = len(data)
    lenb = struct.pack("<H", ln)
    a = xor_all(lenb + data) ^ seq ^ req        # байты [2..dn) + младшие полубайты
    s = (seq & 0x0F) | (a & 0xF0)               # старший полубайт суммы -> SeqNo
    r = (req | (a << 4)) & 0xFF                 # младший полубайт суммы -> ReqType
    return bytes([s, r]) + lenb + data


def unpack(raw, xor_mode):
    """Разобрать ответ так же, как VerifyChecksum() / ветка bcdDevice >= 0x300."""
    if len(raw) < 4:
        raise ProtoError(f"слишком короткий ответ: {len(raw)} байт")
    seq, req = raw[0], raw[1]
    ln = struct.unpack_from("<H", raw, 2)[0]
    if len(raw) < ln + 4:
        raise ProtoError(f"ответ обрезан: Len={ln}, пришло {len(raw) - 4}")
    body = raw[: ln + 4]
    if xor_mode:
        if ln < 1:
            raise ProtoError("Len < 1 в XOR-режиме")
        if xor_all(body) != 0:
            raise ProtoError("не сошёлся XOR")
        return seq, req, bytes(body[4 : 4 + ln - 1])
    a = xor_all(body[2:]) ^ (seq & 0x0F) ^ (req & 0x0F)
    b = ((seq & 0xF0) + (req >> 4)) & 0xFF
    if a != b:
        raise ProtoError(f"не сошлась контрольная сумма: {a:02X} != {b:02X}")
    return seq & 0x0F, req & 0x0F, bytes(body[4 : 4 + ln])


# ------------------------------------------------------------- транспорт USB

class UsbTransport:
    """Тонкая обёртка над pyusb: bulk IN/OUT + control-запрос «set host»."""

    def __init__(self, vid=None, pid=None, interface=None, index=0, libusb=None):
        try:
            import usb.core
            import usb.util
        except ImportError:
            sys.exit("нужен pyusb:  pip install pyusb   (и libusb:  brew install libusb)")
        self.usb = usb
        self.backend = get_backend(libusb)
        self.dev = self._find(vid, pid, index)
        self.bcd = self.dev.bcdDevice
        self._select_interface(interface)

    def _find(self, vid, pid, index):
        usb = self.usb
        pairs = [(vid, pid)] if vid is not None else [(v, p) for v, p, _ in KNOWN_DEVICES]
        found = []
        for v, p in pairs:
            kw = {"idVendor": v}
            if p is not None:
                kw["idProduct"] = p
            found.extend(usb.core.find(find_all=True, backend=self.backend, **kw))
        if not found:
            raise ProtoError("терминал PAX на USB не найден (см. --list)")
        if index >= len(found):
            raise ProtoError(f"устройств найдено {len(found)}, индекс {index} вне диапазона")
        dev = found[index]
        log.info("устройство %04X:%04X bcdDevice=%04X", dev.idVendor, dev.idProduct, dev.bcdDevice)
        return dev

    def _select_interface(self, want):
        usb, dev = self.usb, self.dev
        try:
            cfg = dev.get_active_configuration()
        except usb.core.USBError:
            cfg = None
        if cfg is None:
            dev.set_configuration()
            cfg = dev.get_active_configuration()

        cands = []
        for intf in cfg:
            ins = [e for e in intf if (e.bmAttributes & 3) == 2 and (e.bEndpointAddress & 0x80)]
            outs = [e for e in intf if (e.bmAttributes & 3) == 2 and not (e.bEndpointAddress & 0x80)]
            if ins and outs:
                cands.append((intf, ins[0], outs[0]))
            log.debug("интерфейс %d: класс %02X, bulk IN %s, bulk OUT %s",
                      intf.bInterfaceNumber, intf.bInterfaceClass,
                      [hex(e.bEndpointAddress) for e in ins], [hex(e.bEndpointAddress) for e in outs])
        if not cands:
            raise ProtoError("у устройства нет интерфейса с парой bulk-эндпоинтов")
        if want is not None:
            cands = [c for c in cands if c[0].bInterfaceNumber == want]
            if not cands:
                raise ProtoError(f"интерфейс {want} не найден или без bulk-эндпоинтов")
        else:
            cands.sort(key=lambda c: 0 if c[0].bInterfaceClass == 0xFF else 1)  # vendor вперёд

        intf, ep_in, ep_out = cands[0]
        self.intf_num = intf.bInterfaceNumber
        self.ep_in = ep_in.bEndpointAddress
        self.ep_out = ep_out.bEndpointAddress

        # как в pos_usb_probe(): 64 байта только для high-speed с wMaxPacketSize=64
        self.max_transfer = 512
        speed = getattr(dev, "speed", None)
        if ep_in.wMaxPacketSize == 64 and speed == getattr(usb.util, "SPEED_HIGH", 3):
            self.max_transfer = 64

        try:
            if dev.is_kernel_driver_active(self.intf_num):
                dev.detach_kernel_driver(self.intf_num)
        except (NotImplementedError, usb.core.USBError):
            pass  # на macOS не поддерживается и не нужно для vendor-класса
        usb.util.claim_interface(dev, self.intf_num)
        log.info("интерфейс %d, IN %02X, OUT %02X, max_transfer %d",
                 self.intf_num, self.ep_in, self.ep_out, self.max_transfer)

    def set_host(self):
        self.dev.ctrl_transfer(0x40, 0x01, 0x0300, 0, None, timeout=5000)

    def bulk_out(self, data):
        self.dev.write(self.ep_out, data, timeout=USB_TIMEOUT_MS)

    def bulk_in(self, size):
        return bytes(self.dev.read(self.ep_in, size, timeout=USB_TIMEOUT_MS))

    def close(self):
        try:
            self.usb.util.release_interface(self.dev, self.intf_num)
            self.usb.util.dispose_resources(self.dev)
        except Exception:
            pass


# ------------------------------------------------------------- протокол

class PaxLink:
    def __init__(self, transport):
        self.t = transport
        self.xor_mode = transport.bcd >= 0x300
        self.need_maxdata = transport.bcd >= 0x200
        self.maxdata = DEFAULT_MAXDATA
        self.seq = 0

    @property
    def chunk(self):
        return max(1, self.maxdata - 1)   # драйвер режет по maxdata-1

    def _xfer(self, req, data, new_seq):
        if new_seq:
            self.seq = (self.seq + 1) & 0x0F
        pkt = pack(self.seq, req, data, self.xor_mode)
        log.debug(">> %-7s seq=%X len=%d  %s", REQ_NAMES.get(req), self.seq, len(data), hexdump(data) if data else "")
        self.t.bulk_out(pkt)

        buf = self.t.bulk_in(self.t.max_transfer)
        if len(buf) >= 4:
            total = struct.unpack_from("<H", buf, 2)[0] + 4
            if total > len(buf):
                buf += self.t.bulk_in(total - len(buf))
        seq, rtype, rdata = unpack(buf, self.xor_mode)
        log.debug("<< %-7s seq=%X len=%d  %s", REQ_NAMES.get(rtype, rtype), seq, len(rdata),
                  hexdump(rdata) if rdata and rtype == READ else "")
        return seq, rtype, rdata

    def _cmd(self, req, data=b""):
        last = None
        for attempt in range(MAX_RETRY):
            try:
                seq, rtype, rdata = self._xfer(req, data, new_seq=(attempt == 0))
            except ProtoError as e:
                last = e
                log.warning("%s: повтор %d — %s", REQ_NAMES[req], attempt + 1, e)
                continue
            if seq != self.seq:
                last = ProtoError(f"seq ответа {seq:X} != {self.seq:X}")
                log.warning("%s: повтор %d — %s", REQ_NAMES[req], attempt + 1, last)
                continue
            return rtype, rdata
        raise ProtoError(f"{REQ_NAMES[req]}: {MAX_RETRY} попыток не удались: {last}")

    def handshake(self):
        if self.xor_mode:
            self.t.set_host()
            log.info("set host отправлен (bcdDevice >= 0x300, XOR-режим)")
        if self.need_maxdata:
            rtype, d = self._cmd(MAXDATA)
            if rtype != MAXDATA or len(d) != 2:
                raise ProtoError(f"MAXDATA: неожиданный ответ type={rtype} len={len(d)}")
            self.maxdata = min(struct.unpack("<H", d)[0], MAX_DATA_CAP)
        log.info("maxdata = %d", self.maxdata)

    @staticmethod
    def _state(d):
        return struct.unpack("<4I", d[:16])

    def status(self):
        rtype, d = self._cmd(STATUS)
        if rtype != STATUS or len(d) != 16:
            raise ProtoError(f"STATUS: неожиданный ответ type={rtype} len={len(d)}")
        return self._state(d)

    def read(self, n):
        rtype, d = self._cmd(READ, struct.pack("<H", n))
        if rtype == READ:
            if len(d) > n:
                raise ProtoError(f"READ: прислали {len(d)} байт при запрошенных {n}")
            return d, None
        if rtype == STATUS and len(d) >= 16:
            return b"", self._state(d)          # отдавать уже нечего
        raise ProtoError(f"READ: неожиданный ответ type={rtype}")

    def write(self, data):
        rtype, d = self._cmd(WRITE, data)
        if rtype != STATUS or len(d) != 16:
            raise ProtoError(f"WRITE: неожиданный ответ type={rtype} len={len(d)}")
        return self._state(d)


# ------------------------------------------------------------------ мост

def pump(link, conn, idle_s):
    """Гонять байты между TCP-клиентом и терминалом, пока клиент не отключится."""
    pending = bytearray()
    up = down = 0
    while True:
        _, _, tx_left, rx_left = link.status()

        # терминал -> клиент
        while tx_left > 0:
            data, st = link.read(min(tx_left, link.chunk))
            if st is not None:
                tx_left, rx_left = st[2], st[3]
                if not data:
                    break
            if data:
                conn.sendall(data)
                down += len(data)
                log.info("терминал -> DC  %d байт  %s", len(data), hexdump(data, 48))
                tx_left -= len(data)
            else:
                break

        # клиент -> терминал
        r, _, _ = select.select([conn], [], [], 0 if pending else idle_s)
        if r:
            chunk = conn.recv(65536)
            if not chunk:
                log.info("DC закрыл соединение (к терминалу %d байт, от терминала %d)", up, down)
                return
            pending += chunk

        while pending and rx_left > 0:
            n = min(len(pending), link.chunk, rx_left)
            st = link.write(bytes(pending[:n]))
            log.info("DC -> терминал  %d байт  %s", n, hexdump(pending[:n], 48))
            del pending[:n]
            up += n
            rx_left = st[3]


def serve(make_transport, host, port, idle_s):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((host, port))
    srv.listen(1)
    log.info("жду DC Service на %s:%d", host, port)

    transport = None
    while True:
        conn, addr = srv.accept()
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        log.info("подключение от %s:%d", *addr)
        try:
            # Если кабель передёргивали, старый дескриптор мёртв и handshake упадёт.
            # Тогда переоткрываем устройство и повторяем — в рамках того же
            # подключения, чтобы запрос кассы не пропал.
            for attempt in (1, 2):
                try:
                    if transport is None:
                        transport = make_transport()
                    link = PaxLink(transport)
                    link.handshake()
                    break
                except Exception as e:  # noqa: BLE001
                    if transport is not None:
                        transport.close()
                        transport = None
                    if attempt == 2:
                        raise
                    log.warning("терминал не ответил на согласование (%s) — переоткрываю USB", e)
                    time.sleep(0.5)
            pump(link, conn, idle_s)
        except Exception as e:  # noqa: BLE001 — логируем любую ошибку и ждём следующего клиента
            log.error("сессия прервана: %s", e)
            if transport is not None:
                transport.close()
                transport = None     # на следующем подключении ищем устройство заново
        finally:
            conn.close()


# --------------------------------------------------------------- --list

def list_devices(libusb=None):
    try:
        import usb.core
        import usb.util
    except ImportError:
        sys.exit("нужен pyusb:  pip install pyusb   (и libusb:  brew install libusb)")
    devs = list(usb.core.find(find_all=True, backend=get_backend(libusb)))
    known = {(v, p): n for v, p, n in KNOWN_DEVICES}
    if not devs:
        print("USB-устройств не найдено")
        return 1
    hit = False
    for d in devs:
        tag = known.get((d.idVendor, d.idProduct))
        hit = hit or bool(tag)
        mark = "  <== " + tag if tag else ""
        print(f"{d.idVendor:04X}:{d.idProduct:04X}  bcdDevice={d.bcdDevice:04X}  класс={d.bDeviceClass:02X}{mark}")
        for name, idx in (("производитель", d.iManufacturer), ("продукт", d.iProduct)):
            if idx:
                try:
                    print(f"    {name}: {usb.util.get_string(d, idx)}")
                except Exception:
                    pass
        try:
            for cfg in d:
                for intf in cfg:
                    eps = ", ".join(
                        f"{e.bEndpointAddress:02X}/{['ctrl','iso','bulk','int'][e.bmAttributes & 3]}/{e.wMaxPacketSize}"
                        for e in intf)
                    print(f"    интерфейс {intf.bInterfaceNumber}: класс {intf.bInterfaceClass:02X}  [{eps}]")
        except Exception as e:
            print(f"    (не удалось прочитать конфигурацию: {e})")
    if not hit:
        print("\nизвестных PAX-устройств (VID 2FB8 / 1234) не найдено")
    return 0 if hit else 1


# ------------------------------------------------------------ --selftest

class FakePax:
    """Эмулятор терминала: разбирает пакеты хоста и отвечает по протоколу.
    Всё, что получено через WRITE, возвращается обратно через READ (эхо)."""

    def __init__(self, bcd, maxdata, max_transfer=512, rx_cap=1500):
        self.bcd = bcd
        self.xor_mode = bcd >= 0x300
        self.maxdata = maxdata
        self.max_transfer = max_transfer
        self.rx_cap = rx_cap
        self.outbox = bytearray()   # что терминал хочет отдать
        self.resp = b""
        self.host_set = False
        self.corrupt_next = 0        # испортить N следующих ответов (проверка повторов)
        self.stats = {n: 0 for n in REQ_NAMES.values()}

    def set_host(self):
        self.host_set = True

    def _state(self):
        return struct.pack("<4I", 4096, self.rx_cap, len(self.outbox), self.rx_cap)

    def bulk_out(self, pkt):
        if self.xor_mode:
            assert xor_all(pkt) == 0, "хост прислал битый XOR"
            seq, req = pkt[0], pkt[1]
            ln = struct.unpack_from("<H", pkt, 2)[0]
            data = pkt[4 : 4 + ln - 1]
        else:
            seq, req, data = unpack(pkt, xor_mode=False)
        self.stats[REQ_NAMES[req]] += 1
        if req == MAXDATA:
            reply = (MAXDATA, struct.pack("<H", self.maxdata))
        elif req == STATUS:
            reply = (STATUS, self._state())
        elif req == WRITE:
            assert len(data) <= self.maxdata - 1, "хост превысил maxdata-1"
            assert len(data) <= self.rx_cap, "хост превысил RxLeft"
            self.outbox += bytes(data)          # эхо
            reply = (STATUS, self._state())
        elif req == READ:
            want = struct.unpack("<H", data)[0]
            if not self.outbox:
                reply = (STATUS, self._state())
            else:
                chunk = bytes(self.outbox[:want])
                del self.outbox[:want]
                reply = (READ, chunk)
        else:
            raise AssertionError(f"неизвестная команда {req}")
        out = bytearray(pack(seq & 0x0F, reply[0], reply[1], self.xor_mode))
        if self.corrupt_next:
            self.corrupt_next -= 1
            out[-1] ^= 0x5A
        self.resp = bytes(out)

    def bulk_in(self, size):
        chunk, self.resp = self.resp[:size], self.resp[size:]
        return chunk

    def close(self):
        pass


def selftest():
    import threading

    ok = True

    def check(name, cond):
        nonlocal ok
        print(f"  {'✓' if cond else '✗'} {name}")
        ok = ok and cond

    for bcd, maxdata, label in ((0x0310, 2048, "XOR-режим, bcdDevice 0x0310"),
                                (0x0210, 508, "полубайтовая сумма, bcdDevice 0x0210"),
                                (0x0100, 508, "старый, без MAXDATA, bcdDevice 0x0100")):
        print(f"\n[{label}]")
        dev = FakePax(bcd, maxdata)
        link = PaxLink(dev)
        link.handshake()
        check("set host отправлен только при bcd >= 0x300", dev.host_set == (bcd >= 0x300))
        exp = maxdata if bcd >= 0x200 else DEFAULT_MAXDATA
        check(f"maxdata согласован = {exp}", link.maxdata == exp)

        st = link.status()
        check("STATUS разобран, TxLeft = 0", st[2] == 0)

        payload = bytes(range(256)) * 12       # 3072 байта: больше maxdata и 512
        sent = 0
        while sent < len(payload):
            n = min(len(payload) - sent, link.chunk, st[3])
            st = link.write(payload[sent : sent + n])
            sent += n
        check("WRITE порциями по maxdata-1 и RxLeft", sent == len(payload))

        got = bytearray()
        st = link.status()
        while st[2] > 0:
            d, s2 = link.read(min(st[2], link.chunk))
            got += d
            st = s2 if s2 else link.status()
        check(f"READ вернул эхо целиком ({len(got)} байт)", bytes(got) == payload)

        dev.corrupt_next = 2
        st = link.status()
        check("повтор после двух битых ответов подряд", st[2] == 0)

    print("\n[мост TCP <-> USB на эмуляторе]")
    dev = FakePax(0x0310, 2048)
    srv_port = []

    def run():
        s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("127.0.0.1", 0)); s.listen(1); srv_port.append(s.getsockname()[1])
        c, _ = s.accept()
        link = PaxLink(dev); link.handshake()
        try:
            pump(link, c, 0.002)
        finally:
            c.close(); s.close()

    th = threading.Thread(target=run, daemon=True); th.start()
    while not srv_port:
        time.sleep(0.01)
    cli = socket.create_connection(("127.0.0.1", srv_port[0]))
    msg = b"\x05" + "ОПЛАТА 1.00 РУБ".encode("cp1251") * 200 + b"\x04"
    cli.sendall(msg)
    cli.settimeout(3)
    back = bytearray()
    try:
        while len(back) < len(msg):
            part = cli.recv(65536)
            if not part:
                break
            back += part
    except socket.timeout:
        pass
    cli.close(); th.join(2)
    check(f"байты прошли через мост туда и обратно ({len(back)} из {len(msg)})", bytes(back) == msg)

    print("\nИТОГ:", "всё сошлось" if ok else "ЕСТЬ ОШИБКИ")
    return 0 if ok else 1


# ------------------------------------------------------------------ main

def main():
    ap = argparse.ArgumentParser(description="мост TCP <-> USB для терминалов PAX (протокол ttyPos)")
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--list", action="store_true", help="показать USB-устройства")
    mode.add_argument("--probe", action="store_true", help="согласовать протокол и спросить STATUS")
    mode.add_argument("--serve", action="store_true", help="поднять мост для DC Service")
    mode.add_argument("--selftest", action="store_true", help="проверка протокола на эмуляторе")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=27016)
    ap.add_argument("--vid", type=lambda x: int(x, 16))
    ap.add_argument("--pid", type=lambda x: int(x, 16))
    ap.add_argument("--interface", type=int, help="номер интерфейса (для двухканальных 0x110B)")
    ap.add_argument("--index", type=int, default=0, help="какое по счёту устройство, если их несколько")
    ap.add_argument("--idle-ms", type=float, default=5, help="пауза опроса в простое, мс")
    ap.add_argument("--libusb", help="путь к libusb-1.0.dylib (по умолчанию ищется сам)")
    ap.add_argument("-v", "--verbose", action="count", default=0)
    a = ap.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if a.verbose else logging.INFO,
        format="%(asctime)s %(levelname).1s %(message)s", datefmt="%H:%M:%S")

    if a.selftest:
        return selftest()
    if a.list:
        return list_devices(a.libusb)

    make = lambda: UsbTransport(a.vid, a.pid, a.interface, a.index, a.libusb)  # noqa: E731

    if a.probe:
        t = make()
        try:
            link = PaxLink(t)
            link.handshake()
            txb, rxb, txl, rxl = link.status()
            print(f"\nOK: терминал отвечает по протоколу ttyPos")
            print(f"  bcdDevice {t.bcd:04X} ({'XOR' if link.xor_mode else 'полубайтовая сумма'}), maxdata {link.maxdata}")
            print(f"  буферы: TxBufSize={txb} RxBufSize={rxb} TxLeft={txl} RxLeft={rxl}")
            return 0
        finally:
            t.close()

    serve(make, a.host, a.port, a.idle_ms / 1000.0)
    return 0


if __name__ == "__main__":
    sys.exit(main())
