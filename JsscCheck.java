// SPDX-License-Identifier: MIT
// Проверка, что нативная библиотека jssc грузится на этой машине.
//
// Запуск (JDK 11+, single-file source mode):
//   java -Djava.library.path=/opt/dcservice/native \
//        -cp /opt/dcservice/lib/jssc-2.10.4.jar:/opt/dcservice/dcservice.jar \
//        /opt/dcservice/tools/JsscCheck.java
//
// Почему в classpath обязательно ОБА jar'а: jssc ссылается на
// org.scijava.nativelib.NativeLoader, но сам его не содержит — это внешняя
// зависимость. В нашей раскладке scijava приезжает из dcservice.jar.
//
// Почему нужен -Djava.library.path: тот scijava внутри dcservice.jar — версии
// 2.3.x (2019), и для mac он знает только INTEL_32/INTEL_64/PPC, а на aarch64
// говорит «No native library available for this platform». Спасает порядок
// действий внутри NativeLoader.loadLibrary():
//
//     try { System.loadLibrary(name); }              // ← отсюда мы и грузимся
//     catch (UnsatisfiedLinkError e) { ...распаковщик со сломанным детектом... }
//
// libjssc.dylib на java.library.path перехватывает управление на первой строке.

import jssc.SerialNativeInterface;
import jssc.SerialPortList;

public class JsscCheck {
    public static void main(String[] args) {
        System.out.println("os.name           = " + System.getProperty("os.name"));
        System.out.println("os.arch           = " + System.getProperty("os.arch"));
        System.out.println("java.version      = " + System.getProperty("java.version"));
        System.out.println("java.library.path = " + System.getProperty("java.library.path"));

        try {
            System.out.println("jssc (java)       = " + SerialNativeInterface.getLibraryVersion());
            System.out.println("jssc (native)     = " + SerialNativeInterface.getNativeLibraryVersion());
        } catch (Throwable t) {
            System.out.println("jssc              = НЕ ЗАГРУЗИЛСЯ: " + t);
            System.out.println();
            System.out.println("Что проверить:");
            System.out.println("  1. NoClassDefFoundError org/scijava/... — в -cp нет dcservice.jar");
            System.out.println("  2. UnsatisfiedLinkError / No native library available —");
            System.out.println("     нет libjssc.dylib на java.library.path. Достать из jar:");
            System.out.println("       unzip -o -j <jssc.jar> 'natives/osx_arm64/libjssc.dylib' -d /opt/dcservice/native");
            System.out.println("  3. code signature / library validation — снимите карантин:");
            System.out.println("       xattr -dr com.apple.quarantine /opt/dcservice/native");
            System.exit(1);
        }

        String[] ports = SerialPortList.getPortNames();
        System.out.println();
        System.out.println("Найдено последовательных портов: " + ports.length);
        for (String p : ports) {
            System.out.println("  " + p);
        }
        if (ports.length == 0) {
            System.out.println("  (пусто — воткните терминал по USB и повторите)");
        }
        System.out.println();
        System.out.println("OK: нативная часть jssc работает.");
    }
}
