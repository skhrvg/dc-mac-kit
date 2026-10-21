// SPDX-License-Identifier: MIT
//
// btbridge — мост TCP <-> Bluetooth RFCOMM для терминалов, подключённых по Bluetooth.
//
// Зачем
// -----
// На macOS 26 последовательный порт /dev/cu.<терминал> обслуживает мост Serial
// Port внутри bluetoothd, и он ломается в двух случаях:
//   1) терминал подключили вручную в Пункте управления — единственный канал
//      RFCOMM терминала забирает служба дисплеев Брайля, а Serial Port получает
//      OI_RFCOMM_Connect failed (status=911);
//   2) порт закрыли и открыли снова (например, dcctl restart) — канал остаётся
//      поднятым, но данные через мост больше не идут.
// В обоих случаях запись в порт проходит без ошибок, а до терминала не доходит
// ни байта; лечится только перезапуском bluetoothd. btbridge обходит этот мост:
// канал RFCOMM открывается напрямую через IOBluetooth, а DC Service подключается
// к мосту как к IP-терминалу (CONNECTION_TYPE=IP, IPADDRESS=127.0.0.1:27017).
//
// Как работает
// ------------
//   - слушает TCP (по умолчанию 127.0.0.1:27017). Клиент один. DC 2.1
//     подключается при старте и держит соединение, пока работает. Второе
//     подключение вытесняет прежнее, только если пришлёт данные: проверки порта
//     (nc -z из dcctl) не должны рвать соединение DC;
//   - канал RFCOMM открывается, как только подключился DC, и держится, пока DC
//     подключён, — в том числе между операциями: стоит его отпустить, как macOS
//     отдаёт канал своей службе Брайля. Если канал закрыл терминал (сон,
//     перезагрузка), мост переоткрывает его в фоне. DC отключился — канал
//     закрывается и освобождается для других;
//   - если соединение с терминалом уже поднял кто-то другой (Брайль после
//     ручного «Подключить», Serial Port после /dev/cu.*), мост сначала рвёт его:
//     неудачная попытка открыть занятый канал длится до 5 с;
//   - канал открывается асинхронно, поэтому мост читает кассу и засекает время
//     её кадров, даже пока канал ещё не готов;
//   - кадр, пришедший, пока канал открывался, уходит терминалу, только если
//     открытие уложилось в --ack-budget. Иначе DC уже не ждёт подтверждения
//     (WAITACK, по умолчанию 5 с) и вернул кассе ошибку, а опоздавший кадр
//     заставил бы терминал выполнить операцию, которую касса считает
//     несостоявшейся. Такой кадр отбрасывается;
//   - номер канала берётся из SDP-записи Serial Port, иначе — из --channel.
//
// Доступ к Bluetooth
// ------------------
// TCC выдаёт его «ответственному» процессу и проверяет его Info.plist. Поэтому
// мост собирается в BTBridge.app (Info.plist с NSBluetoothAlwaysUsageDescription)
// и запускается только самостоятельным процессом: LaunchAgent в сессии
// пользователя или `open BTBridge.app`. Запущенный из терминала, он унаследует
// права терминала, а без них TCC завершит процесс.
//
// Сборка (install.sh делает это сам):
//   swiftc -O -o btbridge btbridge.swift -framework IOBluetooth

import Darwin
import Foundation
import IOBluetooth

// ------------------------------------------------------------------ лог

var verbose = false
let timeFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

func log(_ level: Character, _ msg: String) {
    if level == "D" && !verbose { return }
    print("\(timeFmt.string(from: Date())) \(level) \(msg)")
    fflush(stdout)
}

func hexdump(_ d: Data, _ limit: Int = 48) -> String {
    let b = d.prefix(limit)
    let hx = b.map { String(format: "%02x", $0) }.joined(separator: " ")
    let asc = String(b.map { (32..<127).contains($0) ? Character(UnicodeScalar($0)) : "." })
    return hx + (d.count > limit ? " …" : "") + "  |" + asc + "|"
}

/// Крутит текущий run loop: колбэки IOBluetooth приходят только через него.
func pump(_ seconds: Double, until: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end && !until() {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
}

// ------------------------------------------------------------ параметры

struct Options {
    enum Mode { case serve, probe, list }
    var mode: Mode = .serve
    var host = "127.0.0.1"
    var port: UInt16 = 27017
    var device: String?
    var channel: BluetoothRFCOMMChannelID?
    var ackBudget = 4.0    // с на открытие канала, пока DC ждёт подтверждения (WAITACK = 5)
    var count = 1          // циклов в --probe
}

func usage() -> Never {
    print("""
    использование: btbridge (--serve | --probe | --list) [параметры]
      --serve            мост для DC Service
      --probe            тест связи с терминалом напрямую, без DC
      --list             сопряжённые устройства и их каналы Serial Port
      --device ИМЯ|АДРЕС терминал (имя из настроек Bluetooth или адрес a0-44-b7-…)
      --channel N        канал RFCOMM, если в SDP его нет
      --host 127.0.0.1   --port 27017
      --ack-budget 4     сколько секунд можно открывать канал, пока DC ждёт
                         подтверждения (меньше WAITACK из connector.xml)
      --count 1          сколько раз повторить --probe
      -v                 подробный лог
    """)
    exit(2)
}

func parseOptions() -> Options {
    var o = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    func next(_ name: String) -> String { guard let v = it.next() else { print("\(name): нужно значение"); usage() }; return v }
    while let a = it.next() {
        switch a {
        case "--serve": o.mode = .serve
        case "--probe": o.mode = .probe
        case "--list": o.mode = .list
        case "--device": o.device = next(a)
        case "--channel": guard let c = UInt8(next(a)) else { usage() }; o.channel = c
        case "--host": o.host = next(a)
        case "--port": guard let p = UInt16(next(a)) else { usage() }; o.port = p
        case "--ack-budget": guard let v = Double(next(a)), v > 0 else { usage() }; o.ackBudget = v
        case "--count": guard let v = Int(next(a)), v > 0 else { usage() }; o.count = v
        case "-v", "--verbose": verbose = true
        default: print("неизвестный параметр: \(a)"); usage()
        }
    }
    return o
}

// ------------------------------------------------------------ терминал

func normAddr(_ s: String) -> String { s.lowercased().replacingOccurrences(of: ":", with: "-") }

func pairedDevices() -> [IOBluetoothDevice] { (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [] }

func describe(_ d: IOBluetoothDevice) -> String { "\(d.name ?? "?") (\(d.addressString ?? "?"))" }

let serialPortUUID = IOBluetoothSDPUUID(uuid16: BluetoothSDPUUID16(kBluetoothSDPUUID16ServiceClassSerialPort.rawValue))

func cachedChannel(_ d: IOBluetoothDevice) -> BluetoothRFCOMMChannelID? {
    guard let rec = d.getServiceRecord(for: serialPortUUID) else { return nil }
    var ch: BluetoothRFCOMMChannelID = 0
    return rec.getRFCOMMChannelID(&ch) == kIOReturnSuccess ? ch : nil
}

/// Запрос SDP к терминалу (асинхронный, результат — через колбэк на run loop).
final class SDPQuery: NSObject {
    private var done: ((IOReturn) -> Void)?
    static var active: [SDPQuery] = []

    static func run(_ d: IOBluetoothDevice, _ done: @escaping (IOReturn) -> Void) {
        let q = SDPQuery()
        q.done = done
        active.append(q)
        let r = d.performSDPQuery(q)
        if r != kIOReturnSuccess { q.finish(r) }
    }

    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) { finish(status) }

    private func finish(_ r: IOReturn) {
        SDPQuery.active.removeAll { $0 === self }
        let d = done; done = nil
        d?(r)
    }
}

/// Канал Serial Port для --probe/--list: кэш SDP, иначе запрос к терминалу с ожиданием.
func serialChannelSync(_ d: IOBluetoothDevice, fallback: BluetoothRFCOMMChannelID?) -> BluetoothRFCOMMChannelID? {
    if let c = fallback ?? cachedChannel(d) { return c }
    log("I", "SDP-записи Serial Port нет в кэше — запрашиваю у терминала")
    var status: IOReturn?
    SDPQuery.run(d) { status = $0 }
    pump(10) { status != nil }
    if let c = cachedChannel(d) { return c }
    log("E", "у терминала не найдена служба Serial Port (SDP: \(status.map { String(format: "0x%08x", $0) } ?? "нет ответа")) — задайте --channel")
    return nil
}

/// Канал RFCOMM к терминалу. Всё асинхронно: главный поток не блокируется,
/// и мост успевает читать кассу и засекать время её кадров, пока канал открывается.
final class Link: NSObject, IOBluetoothRFCOMMChannelDelegate {
    enum State { case closed, opening, open }
    private(set) var state = State.closed
    private var channel: IOBluetoothRFCOMMChannel?
    private var dev: IOBluetoothDevice?
    private var id: BluetoothRFCOMMChannelID = 0
    private var attempt = 0
    private var started = Date()
    private var watchdog: DispatchWorkItem?
    /// Если терминал недоступен (перезагрузка, вне зоны), вызов радиосвязи
    /// кончается таймаутом, а bluetoothd оставляет запрос в своей очереди и
    /// не сообщает ни успеха, ни отказа. Без сторожа канал «открывался» бы вечно.
    static let openTimeout = 12.0
    var onOpen: (Bool) -> Void = { _ in }
    var onData: (Data) -> Void = { _ in }
    var onClosed: () -> Void = {}

    /// Открыть канал. Соединение с терминалом без нашего канала означает, что его
    /// держит кто-то другой (Брайль после ручного «Подключить», Serial Port после
    /// /dev/cu.*): рвём его сразу, не дожидаясь отказа — тот приходит до 5 с.
    func open(_ d: IOBluetoothDevice, _ id: BluetoothRFCOMMChannelID) {
        guard state == .closed else { return }
        state = .opening; dev = d; self.id = id; attempt = 0; started = Date()
        if d.isConnected() { evict("соединение с терминалом поднял кто-то другой (ручное «Подключить» или /dev/cu.*)") }
        else { tryOpen() }
    }

    private func evict(_ why: String) {
        guard let d = dev else { return }
        log("W", "\(why) — разрываю соединение с терминалом")
        _ = d.closeConnection()
        let deadline = Date().addingTimeInterval(2)
        func wait() {
            if d.isConnected() && Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: wait)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.tryOpen() }
            }
        }
        wait()
    }

    private func tryOpen() {
        guard state == .opening, let d = dev else { return }
        attempt += 1
        var ch: IOBluetoothRFCOMMChannel?
        let r = d.openRFCOMMChannelAsync(&ch, withChannelID: id, delegate: self)
        if r != kIOReturnSuccess { failed(r); return }
        channel = ch
        watchdog?.cancel()
        let n = attempt
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.state == .opening, self.attempt == n else { return }
            log("W", String(format: "канал RFCOMM %d не открылся за %.0f с — терминал недоступен?", self.id, Link.openTimeout))
            let stale = self.channel
            self.channel = nil
            self.state = .closed
            stale?.close()
            self.onOpen(false)
        }
        watchdog = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Link.openTimeout, execute: w)
    }

    func rfcommChannelOpenComplete(_ ch: IOBluetoothRFCOMMChannel!, status: IOReturn) {
        guard state == .opening, ch === channel else {
            // пока открывался, канал стал не нужен (DC ушёл, сработал сторож) — не держим его зря
            if status == kIOReturnSuccess { ch?.close() }
            return
        }
        watchdog?.cancel(); watchdog = nil
        if status == kIOReturnSuccess {
            channel = ch
            state = .open
            log("I", String(format: "канал RFCOMM %d открыт за %.1f с, MTU %d", id, Date().timeIntervalSince(started), ch.getMTU()))
            onOpen(true)
        } else {
            failed(status)
        }
    }

    private func failed(_ r: IOReturn) {
        log("W", String(format: "канал RFCOMM %d не открылся: 0x%08x", id, r))
        channel = nil
        if attempt == 1, let d = dev, d.isConnected() { evict("канал занят другой службой"); return }
        state = .closed
        onOpen(false)
    }

    func write(_ data: Data) -> Bool {
        guard state == .open, let ch = channel else { return false }
        let mtu = max(Int(ch.getMTU()), 1)
        var bytes = [UInt8](data)
        var off = 0
        while off < bytes.count {
            let n = min(mtu, bytes.count - off)
            let r = bytes.withUnsafeMutableBytes { ch.writeSync($0.baseAddress! + off, length: UInt16(n)) }
            if r != kIOReturnSuccess { log("E", String(format: "запись в канал: 0x%08x", r)); return false }
            off += n
        }
        return true
    }

    func close(_ why: String) {
        watchdog?.cancel(); watchdog = nil
        let ch = channel
        let was = state
        state = .closed
        channel = nil
        ch?.close()
        if was != .closed { log("I", "канал закрыт: \(why)") }
    }

    func rfcommChannelData(_ ch: IOBluetoothRFCOMMChannel!, data p: UnsafeMutableRawPointer!, length n: Int) {
        guard state == .open else { return }
        onData(Data(bytes: p, count: n))
    }

    func rfcommChannelClosed(_ ch: IOBluetoothRFCOMMChannel!) {
        guard ch === channel else { return }       // закрыли мы сами или это прежний канал
        if state == .opening {                     // закрылся, не успев открыться
            watchdog?.cancel(); watchdog = nil
            failed(kIOReturnNotOpen)
            return
        }
        guard state == .open else { return }
        state = .closed
        channel = nil
        log("W", "терминал закрыл канал")
        onClosed()
    }
}

func findDevice(_ want: String?) -> IOBluetoothDevice? {
    let all = pairedDevices()
    if all.isEmpty {
        log("E", "список сопряжённых устройств пуст — нет доступа к Bluetooth? Разрешите BTBridge в Настройки → Конфиденциальность и безопасность → Bluetooth")
        return nil
    }
    if let want {
        let w = want.lowercased()
        if let d = all.first(where: { ($0.name ?? "").lowercased() == w || normAddr($0.addressString ?? "") == normAddr(w) }) { return d }
        log("E", "терминал «\(want)» не найден среди сопряжённых: " + all.map(describe).joined(separator: ", "))
        return nil
    }
    let spp = all.filter { cachedChannel($0) != nil }
    if spp.count == 1 { return spp[0] }
    log("E", "задайте терминал: --device ИМЯ|АДРЕС. Сопряжённые" + (spp.isEmpty ? "" : " с Serial Port") + ": " + (spp.isEmpty ? all : spp).map(describe).joined(separator: ", "))
    return nil
}

// ----------------------------------------------------------------- мост

final class Bridge {
    let o: Options
    let link = Link()
    var listenFD: Int32 = -1
    var acceptSrc: DispatchSourceRead?
    var clientFD: Int32 = -1
    var clientSrc: DispatchSourceRead?
    var channelID: BluetoothRFCOMMChannelID?
    var sdpRunning = false
    var pending: [(data: Data, at: Date)] = []    // от кассы, пока канал открывается
    var reopenWork: DispatchWorkItem?
    var failures = 0
    var up = 0, down = 0

    init(_ o: Options) { self.o = o; channelID = o.channel }

    func start() {
        signal(SIGPIPE, SIG_IGN)
        listenFD = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = o.port.bigEndian
        guard inet_pton(AF_INET, o.host, &a.sin_addr) == 1 else { log("E", "неверный адрес \(o.host)"); exit(1) }
        let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard r == 0, listen(listenFD, 4) == 0 else { log("E", "не удалось занять \(o.host):\(o.port): \(String(cString: strerror(errno)))"); exit(1) }

        link.onOpen = { [unowned self] ok in self.opened(ok) }
        link.onData = { [unowned self] d in self.fromTerminal(d) }
        link.onClosed = { [unowned self] in self.scheduleReopen() }

        // Доступ к Bluetooth и терминал проверяем до первого клиента: запрос TCC
        // всплывёт при установке, а не посреди первой оплаты.
        if let d = findDevice(o.device) {
            if channelID == nil { channelID = serialChannelSync(d, fallback: nil) }
            log("I", "терминал \(describe(d))" + (channelID.map { ", Serial Port на канале \($0)" } ?? ""))
        }

        acceptSrc = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: .main)
        acceptSrc!.setEventHandler { [unowned self] in self.accept() }
        acceptSrc!.resume()
        log("I", "жду DC Service на \(o.host):\(o.port)")
    }

    func accept() {
        var a = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let fd = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(listenFD, $0, &len) } }
        guard fd >= 0 else { return }
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let port = UInt16(bigEndian: a.sin_port)
        if clientFD >= 0 {
            // Клиент уже есть. Вытесняет его только подключение, приславшее данные:
            // проверки порта (nc -z из dcctl) соединяются и сразу уходят и не
            // должны рвать постоянное соединение DC.
            log("D", "второе подключение от 127.0.0.1:\(port) — клиентом станет, если пришлёт данные")
            watchCandidate(fd, port)
            return
        }
        becomeClient(fd, port)
        // DC 2.1 подключается при старте и держит соединение: открываем канал
        // сразу, чтобы к первой операции он уже был готов.
        failures = 0
        ensureLink()
    }

    func becomeClient(_ fd: Int32, _ port: UInt16) {
        clientFD = fd
        up = 0; down = 0
        log("I", "подключение от 127.0.0.1:\(port)")
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [unowned self] in self.fromClient() }
        src.setCancelHandler { close(fd) }
        clientSrc = src
        src.resume()
    }

    var candidates: [Int32: DispatchSourceRead] = [:]

    func watchCandidate(_ fd: Int32, _ port: UInt16) {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [unowned self] in
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &buf, buf.count)
            let s = self.candidates.removeValue(forKey: fd)
            if n <= 0 { s?.cancel(); return }       // проверка порта: подключились и ушли
            // Прежний клиент, видимо, мёртв: новый вытесняет его, канал к терминалу остаётся.
            s?.setCancelHandler {}
            s?.cancel()
            log("W", "новое подключение от 127.0.0.1:\(port) прислало данные — вытесняет прежнее")
            self.dropClient()
            self.becomeClient(fd, port)
            self.handle(Data(buf[0..<n]))
        }
        src.setCancelHandler { close(fd) }
        candidates[fd] = src
        src.resume()
    }

    func dropClient() {
        clientSrc?.cancel()
        clientSrc = nil
        clientFD = -1
    }

    /// Открыть канал, если его нет. Номер канала — из SDP (асинхронно, если не в кэше).
    func ensureLink() {
        guard link.state == .closed, !sdpRunning else { return }
        reopenWork?.cancel(); reopenWork = nil
        guard let dev = findDevice(o.device) else { opened(false); return }
        if let id = channelID ?? cachedChannel(dev) {
            channelID = id
            link.open(dev, id)
            return
        }
        log("I", "SDP-записи Serial Port нет в кэше — запрашиваю у терминала")
        sdpRunning = true
        SDPQuery.run(dev) { [unowned self] status in
            self.sdpRunning = false
            if let id = cachedChannel(dev) { self.channelID = id; self.link.open(dev, id) }
            else { log("E", String(format: "у терминала не найдена служба Serial Port (SDP: 0x%08x) — задайте --channel", status)); self.opened(false) }
        }
    }

    func opened(_ ok: Bool) {
        guard ok else {
            drop("канал к терминалу не открылся")
            failures += 1
            scheduleReopen()
            return
        }
        failures = 0
        flush()
    }

    /// Отправить терминалу то, что касса прислала, пока канал открывался, — если
    /// касса ещё ждёт подтверждения. Опоздавший кадр терминал бы принял и выполнил,
    /// а касса уже вернула ошибку: такой кадр и всё, что за ним, отбрасываем.
    func flush() {
        guard let first = pending.first else { return }
        let age = Date().timeIntervalSince(first.at)
        if age > o.ackBudget {
            drop(String(format: "канал открывался %.1f с — дольше, чем DC ждёт подтверждения (--ack-budget %.0f с); кадр терминалу не отправлен, DC вернул кассе ошибку", age, o.ackBudget))
            return
        }
        for p in pending { send(p.data) }
        pending.removeAll()
    }

    func drop(_ why: String) {
        guard !pending.isEmpty else { return }
        let n = pending.reduce(0) { $0 + $1.data.count }
        pending.removeAll()
        log("E", "\(why): отброшено \(n) байт от DC")
    }

    func send(_ d: Data) {
        if link.write(d) { up += d.count } else { link.close("ошибка записи"); scheduleReopen() }
    }

    /// Пока DC подключён, канал держим открытым: после обрыва переоткрываем в фоне.
    func scheduleReopen() {
        reopenWork?.cancel(); reopenWork = nil
        guard clientFD >= 0 else { return }
        let delay = min(30.0, 2.0 * pow(2.0, Double(min(failures, 4))))
        let w = DispatchWorkItem { [unowned self] in self.reopenWork = nil; self.ensureLink() }
        reopenWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
        if failures > 0 { log("I", String(format: "повторю через %.0f с", delay)) }
    }

    func fromClient() {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = read(clientFD, &buf, buf.count)
        if n <= 0 {
            log("I", "DC закрыл соединение (к терминалу \(up) байт, от терминала \(down))")
            dropClient()
            reopenWork?.cancel(); reopenWork = nil
            pending.removeAll()
            link.close("DC отключился")
            return
        }
        handle(Data(buf[0..<n]))
    }

    func handle(_ d: Data) {
        log("I", "DC -> терминал  \(d.count) байт  \(hexdump(d))")
        if link.state == .open {
            flush()
            send(d)
        } else {
            pending.append((d, Date()))
            if link.state == .closed { ensureLink() }
        }
    }

    func fromTerminal(_ d: Data) {
        log("I", "терминал -> DC  \(d.count) байт  \(hexdump(d))")
        down += d.count
        guard clientFD >= 0 else { log("W", "DC не подключён — данные терминала отброшены"); return }
        d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            var off = 0
            while off < d.count {
                let w = Darwin.send(clientFD, p.baseAddress! + off, d.count - off, 0)
                if w <= 0 { log("E", "запись клиенту: \(String(cString: strerror(errno)))"); return }
                off += w
            }
        }
    }
}

// ------------------------------------------------------------- --probe

let testFrame = Data([0x02, 0x05, 0x00, 0x19, 0x02, 0x00, 0x32, 0x36, 0x25, 0xD3])   // тест связи: поле 25 = «26»

func probe(_ o: Options) -> Int32 {
    guard let dev = findDevice(o.device) else { return 1 }
    log("I", "терминал \(describe(dev)), соединение: \(dev.isConnected() ? "есть" : "нет")")
    guard let id = serialChannelSync(dev, fallback: o.channel) else { return 1 }
    var ok = 0
    for n in 1...o.count {
        if o.count > 1 { log("I", "— попытка \(n)/\(o.count)") }
        let link = Link()
        var rx = Data()
        var opened: Bool?
        link.onOpen = { opened = $0 }
        link.onData = { d in rx.append(d); log("I", "← \(hexdump(d))") }
        link.open(dev, id)
        pump(15) { opened != nil }
        guard opened == true else { continue }
        _ = link.write(testFrame)
        log("I", "→ \(hexdump(testFrame))")
        func packetDone() -> Bool {
            guard let i = rx.firstIndex(of: 0x02), rx.count >= i + 3 else { return false }
            let len = Int(rx[i + 1]) | Int(rx[i + 2]) << 8
            return rx.count - i >= 5 + len
        }
        pump(15) { packetDone() || link.state != .open }
        if packetDone() {
            for b: UInt8 in [0x06, 0x06, 0x06, 0x04] { _ = link.write(Data([b])); pump(0.055) }
            log("I", "→ 06 06 06 04 — терминал ответил на тест связи")
            ok += 1
        } else {
            log("E", rx.isEmpty ? "терминал не ответил" : "ответ пришёл не целиком")
        }
        link.close("тест окончен")
        if n < o.count { pump(1) }
    }
    print(ok == o.count ? "OK: связь с терминалом по RFCOMM есть" : "ОШИБКА: успешных тестов \(ok) из \(o.count)")
    return ok == o.count ? 0 : 1
}

func list(_ o: Options) -> Int32 {
    let all = pairedDevices()
    if all.isEmpty { log("E", "сопряжённых устройств не видно — нет доступа к Bluetooth?"); return 1 }
    for d in all {
        let ch = cachedChannel(d).map { "Serial Port, канал \($0)" } ?? "—"
        print("  \(describe(d))  \(d.isConnected() ? "подключено" : "не подключено")  \(ch)")
    }
    return 0
}

// ---------------------------------------------------------------- main

let opts = parseOptions()
switch opts.mode {
case .list: exit(list(opts))
case .probe: exit(probe(opts))
case .serve:
    let bridge = Bridge(opts)
    bridge.start()
    let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    signal(SIGTERM, SIG_IGN)
    term.setEventHandler { bridge.link.close("останов"); log("I", "остановлен"); exit(0) }
    term.resume()
    RunLoop.main.run()
}
