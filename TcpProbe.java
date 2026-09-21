// SPDX-License-Identifier: MIT
// Повторяет ровно то, что делает ru.inpas.communication.pc.TcpClient:
//     new Socket() → setSoTimeout(...) → connect(InetSocketAddress)
//
// Смысл: отделить «Java-процесс не может открыть сокет в локальную сеть»
// (права Local Network в macOS, файрвол, маршрут) от «DC не дошёл до connect».
// nc здесь не показатель — у Terminal свои разрешения, и это другой бинарник.
//
// Запуск (JDK 11+):
//   java TcpProbe.java 192.168.1.100 9000
//
// Полезно прогнать дважды: из Terminal и из-под launchd (скажем, добавив
// вызов в обёртку запуска) — расхождение укажет на TCC.

import java.net.InetSocketAddress;
import java.net.Socket;

public class TcpProbe {
    public static void main(String[] args) {
        if (args.length < 2) {
            System.out.println("использование: java TcpProbe.java <ip> <порт> [таймаут_мс]");
            return;
        }
        String host = args[0];
        int port = Integer.parseInt(args[1]);
        int timeout = args.length > 2 ? Integer.parseInt(args[2]) : 20000;

        System.out.println("цель        = " + host + ":" + port);
        System.out.println("таймаут     = " + timeout + " мс");

        long t0 = System.currentTimeMillis();
        try (Socket s = new Socket()) {
            s.setSoTimeout(60000);
            s.connect(new InetSocketAddress(host, port), timeout);
            long dt = System.currentTimeMillis() - t0;
            System.out.println("РЕЗУЛЬТАТ   = соединение установлено за " + dt + " мс");
            System.out.println("локальный   = " + s.getLocalSocketAddress());
            System.out.println("удалённый   = " + s.getRemoteSocketAddress());
            System.out.println();
            System.out.println("Java до терминала достучалась. Если DC при этом говорит");
            System.out.println("'Can't open device', проблема не в сети, а в его init().");
        } catch (Exception e) {
            long dt = System.currentTimeMillis() - t0;
            System.out.println("РЕЗУЛЬТАТ   = ОШИБКА через " + dt + " мс");
            System.out.println("исключение  = " + e);
            System.out.println();
            System.out.println("Как читать:");
            System.out.println("  Operation not permitted      — macOS режет локальную сеть (Local Network / TCC)");
            System.out.println("  Connection refused           — порт закрыт, на нём никто не слушает");
            System.out.println("  timed out / No route to host  — сети до хоста нет, или режет файрвол");
        }
    }
}
