// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Network
import SwiftUI
import UIKit

/// How Henge gets a debugger attached. See docs/06-built-in-jit.md.
enum JITMethod: String, CaseIterable, Identifiable {
    /// StikDebug when it is installed, then TrollStore, otherwise Built-in StikJIT.
    case automatic
    case stikDebug
    case trollStore
    case jailbreak
    case builtIn

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Otomatik"
        case .stikDebug: return "StikDebug"
        case .trollStore: return "TrollStore"
        case .jailbreak: return "Jailbreak (Dopamine)"
        case .builtIn: return "Yerleşik StikJIT"
        }
    }
}

/// Where Built-in StikJIT's pairing file came from.
enum JITPairingSource: String {
    /// Made by Henge on this device (iOS 27, OnDevicePairing).
    case onDevice
    /// Imported from a file made on a computer.
    case imported
}

/// The RPPairing file Built-in StikJIT authenticates with. Lives in Documents,
/// so it is visible through Finder file sharing -- it is device-sensitive and
/// is only ever sent to Henge's own helper process.
enum JITPairingFileStore {
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StikJIT", isDirectory: true)
    }
    static var url: URL { directory.appendingPathComponent("pairingFile.plist") }
    static var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
    private static let sourceKey = "henge.jitPairingSource"

    static var source: JITPairingSource? {
        guard exists else { return nil }
        return UserDefaults.standard.string(forKey: sourceKey).flatMap(JITPairingSource.init(rawValue:)) ?? .imported
    }

    static func data() throws -> Data { try Data(contentsOf: url) }

    static func importFile(from source: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try store(try Data(contentsOf: source), source: .imported)
    }

    /// Validates an RPPairing plist and makes it the pairing file.
    static func store(_ data: Data, source: JITPairingSource) throws {
        guard !data.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any],
              let publicKey = dictionary["public_key"] as? Data, publicKey.count == 32,
              let privateKey = dictionary["private_key"] as? Data, privateKey.count == 32,
              let identifier = dictionary["identifier"] as? String, !identifier.isEmpty else {
            throw NSError(domain: "HengeJIT", code: 10,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Seçilen dosya geçerli bir uzaktan eşleştirme (RPPairing) dosyası değil. StikDebug rehberiyle yeni bir eşleştirme dosyası oluşturup tekrar deneyin."])
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        UserDefaults.standard.set(source.rawValue, forKey: sourceKey)
    }
}

@MainActor
final class JITCoordinator: ObservableObject {
    static let shared = JITCoordinator()

    /// Categorizes the root cause of a JIT setup/attach failure so the user immediately sees
    /// whether the issue comes from code signing (get-task-allow), pairing file, VPN, or code execution selftest.
    enum ConnectionProblem: Equatable {
        /// App signature lacks `get-task-allow` (e.g. signed with an enterprise/distribution cert in ESign).
        case signature
        /// Nothing answered at LocalDevVPN's address: the VPN is off or not routing.
        case vpn
        /// The device closed the connection, usually because it no longer accepts
        /// this pairing (every new pairing replaces the last).
        case pairing
        /// Debugger attached (`CS_DEBUGGED` set), but the 1 GB dual-mapped region or RX `henge_jit_selftest` failed.
        case selftest

        init?(helperMessage: String) {
            let text = helperMessage.lowercased()
            let has = { (needles: [String]) in needles.contains(where: text.contains) }
            if has(["get-task-allow", "debugserver", "attach failed", "not allowed to attach", "permission denied"]) && !Entitlements.getTaskAllow {
                self = .signature
            } else if has(["connectionreset", "connection reset", "device refused connection", "invalid pairing", "pair", "untrusted"]) {
                self = .pairing
            } else if has(["connectionrefused", "connection refused", "timedout", "timed out",
                           "networkunreachable", "network unreachable", "hostunreachable",
                           "host unreachable", "no route", "localdevvpn"]) {
                self = .vpn
            } else {
                return nil
            }
        }

        var categoryTitle: String {
            switch self {
            case .signature: return "İmza Hatası (get-task-allow Kapalı)"
            case .vpn: return "VPN / Bağlantı Hatası (LocalDevVPN)"
            case .pairing: return "Eşleştirme Dosyası Hatası (Pairing)"
            case .selftest: return "Kod Çalıştırma Testi Başarısız (Selftest)"
            }
        }

        var message: String {
            switch self {
            case .signature:
                return "İmza Hatası: Bu kurulumda 'get-task-allow' (hata ayıklama) izni bulunmuyor. ESign veya dağıtım sertifikasıyla imzalanan paketlerde Apple bu izni kapattığı için JIT açılamaz. Sideloadly (kişisel Apple hesabı) ile imzalayın veya imzalayıcıda get-task-allow iznini açın."
            case .vpn:
                return "VPN Hatası: Cihazın hata ayıklama servisine ulaşılamadı. LocalDevVPN uygulamasını açıp VPN bağlantısını etkinleştirin ve tekrar deneyin."
            case .pairing:
                return "Eşleştirme Hatası: Cihaz bağlantıyı reddetti (eşleştirme dosyası geçersiz veya süresi dolmuş). Yeni bir eşleştirme dosyası içe aktarın ve LocalDevVPN'in bağlı olduğundan emin olun."
            case .selftest:
                return "Kod Çalıştırma Testi Başarısız: Hata ayıklayıcı bağlandı (CS_DEBUGGED açık) ancak 1 GB çift eşlemeli (RX/RW) JIT bölgesi oluşturulamadı veya gerçek kod çalıştırma testi (selftest 42) başarısız oldu."
            }
        }
    }

    @Published var method: JITMethod {
        didSet { UserDefaults.standard.set(method.rawValue, forKey: "henge.jitMethod") }
    }
    @Published var showSetup = false
    @Published private(set) var connectionProblem: ConnectionProblem?
    @Published private(set) var busy = false
    @Published private(set) var status: String?
    @Published private(set) var error: String?
    @Published private(set) var txmPresent: Bool?
    /// The setup check passed for the current pairing file.
    @Published private(set) var prepared = false
    @Published private(set) var pairingSource = JITPairingFileStore.source
    /// Bumped each time the built-in helper attaches. Henge stays in the
    /// foreground for that, so nothing else tells ContentView to claim the region.
    @Published private(set) var attachGeneration = 0

    var hasPairing: Bool { pairingSource != nil }

    private init() {
        method = UserDefaults.standard.string(forKey: "henge.jitMethod")
            .flatMap(JITMethod.init(rawValue:)) ?? .automatic
    }

    var resolvedMethod: JITMethod {
        guard method == .automatic else { return method }
        if JITBootstrap.isStikDebugInstalled { return .stikDebug }
        if JITBootstrap.isTrollStoreInstalled { return .trollStore }
        if JITBootstrap.isJailbroken { return .jailbreak }
        return .builtIn
    }

    var automaticDescription: String {
        switch resolvedMethod {
        case .stikDebug: return "StikDebug yüklü olduğu için Henge doğrudan StikDebug üzerinden JIT açacak."
        case .trollStore: return "TrollStore yüklü olduğu için Henge JIT iznini TrollStore'dan isteyecek."
        case .jailbreak: return "Cihazda Jailbreak algılandı; Dopamine içindeki 'Allow JIT in Apps' ayarı kullanılır."
        default: return "StikDebug, TrollStore veya Jailbreak bulunamadı; Henge kendi yerleşik StikJIT yardımcısını kullanacak."
        }
    }

    func refreshPairingStatus() {
        pairingSource = JITPairingFileStore.source
    }

    private func log(_ line: String) { HengeLog.log("jit", line) }

    /// Get a debugger attached with whichever method applies, or open the setup
    /// walkthrough when that method is not set up yet.
    /// "Turn on JIT at launch": when Henge opens without JIT, ask the built-in StikJIT for it straight away, once per launch.
    /// Only when StikJIT can do it unattended -- it is available here and already paired -- so opening Henge never lands in
    /// the setup walkthrough by surprise.
    static let autoEnableKey = "henge.jit.autoEnable"
    private var autoTried = false

    /// A Henge TrollStore installed asks TrollStore for JIT each time it opens without it (#135), unless turned off in Settings:
    /// TrollStore attaches to the running Henge for a moment, with nothing to tap.
    static let trollStoreAutoKey = "henge.jit.trollStoreAuto"
    static var trollStoreAuto: Bool { UserDefaults.standard.object(forKey: trollStoreAutoKey) as? Bool ?? true }

    func enableAtLaunchIfAsked() {
        if !autoTried, JITBootstrap.isInstalledWithTrollStore, Self.trollStoreAuto {
            autoTried = true
            guard !JITBootstrap.ready else { return }
            log("installed by TrollStore: asking it for JIT at launch")
            method = .trollStore
            enable()
            return
        }
        guard !autoTried, UserDefaults.standard.bool(forKey: Self.autoEnableKey) else { return }
        autoTried = true
        guard !JITBootstrap.ready else { return }
        if !Entitlements.getTaskAllow, !JITBootstrap.isJailbroken, !JITBootstrap.isInstalledWithTrollStore {
            connectionProblem = .signature
            error = ConnectionProblem.signature.message
            log("JIT at launch skipped: get-task-allow entitlement is missing")
            return
        }
        guard HengeBuiltInJIT.isAvailable, hasPairing else {
            log("JIT at launch is on, but built-in StikJIT is not available or not paired; skipped")
            return
        }
        log("turning JIT on at launch with built-in StikJIT")
        method = .builtIn
        enable()
    }

    func enable() {
        guard !JITBootstrap.ready else { return }
        error = nil
        connectionProblem = nil
        if !Entitlements.getTaskAllow, !JITBootstrap.isJailbroken, !JITBootstrap.isInstalledWithTrollStore {
            connectionProblem = .signature
            error = ConnectionProblem.signature.message
            log("enable blocked: get-task-allow entitlement is missing in current signature")
            showSetup = true
            return
        }
        switch resolvedMethod {
        case .automatic:
            assertionFailure("Automatic must resolve to a concrete JIT method")
        case .stikDebug:
            // requestAttach() calls open() on stikjit:// and cannot report failure
            // synchronously: an unclaimed scheme fails open() silently. Wait for
            // CS_DEBUGGED so a missing StikDebug still ends in a clear message.
            if JITBootstrap.requestAttach() {
                awaitStikDebug()
            } else if JITBootstrap.requestTrollStoreAttach() {
                awaitTrollStore()
            } else {
                error = "StikDebug uygulaması yüklü değil. StikDebug yükleyin veya Yerleşik StikJIT kurulumunu tamamlayın."
                showSetup = true
            }
        case .trollStore:
            if JITBootstrap.requestTrollStoreAttach() {
                awaitTrollStore()
            } else {
                error = "TrollStore açılamadı. Henge'i TrollStore üzerinden kurun veya başka bir JIT yöntemi seçin."
                showSetup = true
            }
        case .jailbreak:
            // Nothing to ask: a jailbreak marks an app as debugged as it opens, if it has been told to. Say what to turn on.
            error = "Dopamine ayarlarından 'Allow JIT in Apps' seçeneğini açın ve Henge'i yeniden başlatın."
            showSetup = true
        case .builtIn:
            guard HengeBuiltInJIT.isAvailable, hasPairing else {
                log("built-in JIT is not set up; opening the walkthrough")
                showSetup = true
                return
            }
            enableBuiltIn()
        }
    }

    /// Verifies that after CS_DEBUGGED is set, the 1 GB dual-mapped JIT region is claimed and passes the
    /// native RX code execution selftest (`henge_jit_selftest` returning 42).
    private func verifyLiveJITAfterAttach(sourceName: String) {
        JITBootstrap.resetTrapPrewarmAttempt()
        let liveOK = JITBootstrap.prewarm() && JITBootstrap.isLive
        if liveOK {
            status = "JIT Açık (1 GB RX/RW bölgesi ve kod çalıştırma testi doğrulandı)."
            error = nil
            connectionProblem = nil
            attachGeneration += 1
            log("\(sourceName) attached and passed RX selftest (42)")
        } else {
            status = nil
            connectionProblem = .selftest
            error = JITBootstrap.lastFailure ?? ConnectionProblem.selftest.message
            log("\(sourceName) attached (CS_DEBUGGED=1) but JIT prewarm/selftest FAILED")
            showSetup = true
        }
    }

    private func awaitTrollStore() {
        busy = true
        status = "TrollStore üzerinden JIT izni bekleniyor…"
        log("waiting for TrollStore's attach")
        _ = Self.waitForDebugger(timeout: 60) { [weak self] attached in
            guard let self else { return }
            busy = false
            if attached {
                verifyLiveJITAfterAttach(sourceName: "TrollStore")
            } else {
                status = nil
                error = "TrollStore JIT iznini etkinleştirmedi. TrollStore Ayarları'nda 'URL Scheme' seçeneğini açın ve Henge'in TrollStore ile kurulduğundan (veya get-task-allow ile imzalandığından) emin olun."
                log("TrollStore did not enable JIT within a minute")
                showSetup = true
            }
        }
    }

    private func awaitStikDebug() {
        busy = true
        status = "StikDebug bağlantısı bekleniyor…"
        log("waiting for StikDebug's attach")
        _ = Self.waitForDebugger(timeout: 60) { [weak self] attached in
            guard let self else { return }
            busy = false
            if attached {
                verifyLiveJITAfterAttach(sourceName: "StikDebug")
            } else {
                status = nil
                error = "StikDebug 60 saniye içinde bağlanmadı. StikDebug ve LocalDevVPN'in açık olduğundan emin olup tekrar deneyin."
                log("StikDebug did not attach within a minute")
                showSetup = true
            }
        }
    }

    func importPairingFile(_ source: URL) {
        do {
            try JITPairingFileStore.importFile(from: source)
            OnDevicePairing.shared.cancel()
            refreshPairingStatus()
            method = .builtIn
            prepared = false
            status = "Eşleştirme dosyası içe aktarıldı."
            error = nil
            log("pairing file imported")
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// OnDevicePairing finished: its file becomes the pairing file and Built-in StikJIT the method.
    func storeOnDevicePairing(_ data: Data) throws {
        try JITPairingFileStore.store(data, source: .onDevice)
        refreshPairingStatus()
        method = .builtIn
        prepared = false
        status = "Bu cihazla eşleştirildi."
        error = nil
    }

    /// Check LocalDevVPN and the Developer Disk Image, mounting it when needed.
    func prepareBuiltIn() {
        if !Entitlements.getTaskAllow {
            connectionProblem = .signature
            error = ConnectionProblem.signature.message
            return
        }
        guard let pairing = builtInPairing() else { return }
        busy = true
        error = nil
        connectionProblem = nil
        status = "LocalDevVPN ve Geliştirici Disk Görüntüsü (DDI) kontrol ediliyor…"
        RemotePairingPortDiscovery.resolve { port in
            HengeBuiltInJIT.send(.prepare(pairingData: pairing, rsdPort: port)) { [weak self] result in
                guard let self else { return }
                busy = false
                switch result {
                case .success(let response):
                    txmPresent = response.txmPresent
                    prepared = response.success
                    status = response.success ? "Kurulum doğrulandı: \(response.message)" : nil
                    error = response.success ? nil : helperFailure(response.message)
                    log("setup check \(response.success ? "passed" : "failed"): \(response.message)")
                case .failure(let failure):
                    prepared = false
                    status = nil
                    error = helperFailure(failure.localizedDescription)
                }
            }
        }
    }

    func enableBuiltIn() {
        if !Entitlements.getTaskAllow {
            connectionProblem = .signature
            error = ConnectionProblem.signature.message
            showSetup = true
            return
        }
        guard let pairing = builtInPairing() else { return }
        guard let script = JITBootstrap.scriptBase64 else {
            error = "Henge JIT betiği (henge-jit.js) uygulama paketinde bulunamadı. Henge'i yeniden yükleyin."
            return
        }

        busy = true
        error = nil
        connectionProblem = nil
        status = "Yerleşik JIT yardımcısı başlatılıyor…"
        log("enabling JIT with the built-in helper")
        var readiness: Timer?
        var finished = false
        let finish: (String?) -> Void = { [weak self] failure in
            guard let self, !finished else { return }
            finished = true
            readiness?.invalidate()
            busy = false
            if let failure {
                status = nil
                error = failure
                log("built-in JIT failed: \(failure)")
                showSetup = true
            } else {
                verifyLiveJITAfterAttach(sourceName: "Built-in StikJIT")
            }
        }

        RemotePairingPortDiscovery.resolve { port in
            HengeBuiltInJIT.send(
                .enable(targetPID: getpid(), pairingData: pairing, scriptBase64: script, rsdPort: port),
                started: { [weak self] in
                    self?.status = "JIT yardımcısının bağlanması ve kod çalıştırma testi bekleniyor…"
                    readiness = Self.waitForDebugger { attached in
                        if attached {
                            finish(nil)
                        } else {
                            self?.connectionProblem = .vpn
                            finish("JIT yardımcısı 90 saniye içinde bağlanamadı. LocalDevVPN bağlantısının açık olduğundan ve eşleştirme dosyasının güncel olduğundan emin olup tekrar deneyin.")
                        }
                    }
                },
                completion: { [weak self] result in
                    // The helper replies once Henge detaches, or when attaching failed.
                    switch result {
                    case .success(let response):
                        self?.txmPresent = response.txmPresent
                        HengeLog.log("jit", "helper: \(response.message)")
                        if !response.success {
                            finish(self?.helperFailure(response.message) ?? response.message)
                        }
                    case .failure(let failure):
                        finish(self?.helperFailure(failure.localizedDescription) ?? failure.localizedDescription)
                    }
                })
        }
    }

    func resetDDI() {
        busy = true
        error = nil
        status = "Geliştirici Disk Görüntüsü (DDI) önbelleği sıfırlanıyor…"
        HengeBuiltInJIT.send(.resetDDI) { [weak self] result in
            guard let self else { return }
            busy = false
            prepared = false
            switch result {
            case .success(let response):
                status = response.success ? response.message : nil
                error = response.success ? nil : response.message
            case .failure(let failure):
                status = nil
                error = failure.localizedDescription
            }
        }
    }

    private func builtInPairing() -> Data? {
        if let reason = HengeBuiltInJIT.unavailableReason {
            error = reason
            return nil
        }
        guard let pairing = try? JITPairingFileStore.data() else {
            connectionProblem = .pairing
            error = "Önce bu cihazı eşleştirin veya bilgisayarda oluşturulan eşleştirme dosyasını (pairingFile.plist) içe aktarın."
            return nil
        }
        return pairing
    }

    /// The helper's failure as shown: a connection problem gets its plain
    /// explanation (the helper's own message is already in the log).
    private func helperFailure(_ message: String) -> String {
        connectionProblem = ConnectionProblem(helperMessage: message)
        if let problem = connectionProblem {
            return "\(problem.message)\n(Teknik detay: \(message))"
        }
        return message
    }

    /// Polls CS_DEBUGGED until it is set or `timeout` passes.
    private static func waitForDebugger(timeout: TimeInterval = 90,
                                        completion: @escaping (Bool) -> Void) -> Timer {
        let deadline = Date().addingTimeInterval(timeout)
        let timer = Timer(timeInterval: 0.5, repeats: true) { timer in
            if JITBootstrap.debuggedFlag {
                timer.invalidate()
                completion(true)
            } else if Date() >= deadline {
                timer.invalidate()
                completion(false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

/// LocalDevVPN, which Built-in StikJIT and StikDebug reach the device through:
/// open it to connect when it is installed, otherwise its App Store page.
enum LocalDevVPN {
    static let appStore = URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!
    /// `enable` connects the VPN; `scheme` has LocalDevVPN return to Henge afterwards.
    static let connect = URL(string: "localdevvpn://enable?scheme=henge")!

    static var isInstalled: Bool { UIApplication.shared.canOpenURL(URL(string: "localdevvpn://")!) }
    static var actionTitle: String { isInstalled ? "LocalDevVPN'i Bağla" : "LocalDevVPN'i İndir" }

    @MainActor static func open() {
        let installed = isInstalled
        HengeLog.log("jit", "LocalDevVPN \(installed ? "connect" : "app-store")")
        UIApplication.shared.open(installed ? connect : appStore)
    }
}

/// The device advertises RemotePairing on a port it picks at boot, while
/// StikJIT defaults to the old fixed 49152. Find the advertised port so
/// Built-in StikJIT keeps working after the device restarts.
enum RemotePairingPortDiscovery {
    private static let serviceType = "_remotepairing._tcp"
    private static let queue = DispatchQueue(label: "com.henge.app.remotepairing-discovery", qos: .utility)
    private static let lock = NSLock()
    private static var cachedPort: UInt16?
    private static var lastFailure: Date?

    /// Calls back on the main thread. nil means the helper should use StikJIT's
    /// default.
    static func resolve(timeout: TimeInterval = 3, completion: @escaping (UInt16?) -> Void) {
        lock.lock()
        if let cachedPort {
            lock.unlock()
            DispatchQueue.main.async { completion(cachedPort) }
            return
        }
        if let lastFailure, Date().timeIntervalSince(lastFailure) < 30 {
            lock.unlock()
            DispatchQueue.main.async { completion(nil) }
            return
        }
        lock.unlock()

        queue.async {
            let port = discover(timeout: timeout)
            lock.lock()
            if let port {
                cachedPort = port
                lastFailure = nil
            } else {
                lastFailure = Date()
            }
            lock.unlock()
            HengeLog.log("jit", "RemotePairing port "
                        + (port.map { String($0) } ?? "not found; using StikJIT's default"))
            DispatchQueue.main.async { completion(port) }
        }
    }

    private static func discover(timeout: TimeInterval) -> UInt16? {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: parameters)

        let semaphore = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var finished = false
        var resolvedPort: UInt16?
        var pendingConnection: NWConnection?

        func finish(_ port: UInt16?) {
            resultLock.lock()
            if !finished {
                finished = true
                resolvedPort = port
                semaphore.signal()
            }
            resultLock.unlock()
        }

        func hasFinished() -> Bool {
            resultLock.lock()
            defer { resultLock.unlock() }
            return finished
        }

        browser.browseResultsChangedHandler = { results, _ in
            guard !hasFinished() else { return }

            let preferred = results.first { result in
                result.interfaces.contains { $0.name == "lo0" }
            } ?? results.first
            guard let result = preferred, case .service = result.endpoint else { return }

            resultLock.lock()
            let alreadyConnecting = pendingConnection != nil
            if !alreadyConnecting {
                pendingConnection = NWConnection(to: result.endpoint, using: parameters)
            }
            let connection = pendingConnection
            resultLock.unlock()

            guard !alreadyConnecting, let connection else { return }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let remoteEndpoint = connection.currentPath?.remoteEndpoint,
                       case .hostPort(_, let port) = remoteEndpoint {
                        finish(port.rawValue)
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }

        browser.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled:
                finish(nil)
            default:
                break
            }
        }

        browser.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + timeout)
        browser.cancel()

        resultLock.lock()
        let connectionToCancel = pendingConnection
        resultLock.unlock()
        connectionToCancel?.cancel()

        resultLock.lock()
        defer { resultLock.unlock() }
        return resolvedPort
    }
}

