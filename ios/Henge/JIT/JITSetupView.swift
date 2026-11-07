// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UniformTypeIdentifiers

/// The JIT walkthrough: pick a way in, follow its numbered steps, end with JIT on.
///
/// Three ways in. Pairing on this iPhone (iOS 27) and a pairing file made on a
/// computer both lead to Built-in StikJIT and share the last two steps,
/// LocalDevVPN and enabling. StikDebug has its own short page. Presented from
/// onboarding, Settings › JIT, and whenever Start finds JIT not set up.
struct JITSetupFlow: View {
    enum Step: Hashable { case pairOnDevice, importFile, connect, enable, stikDebug, trollStore, jailbreak }

    @ObservedObject private var jit = JITCoordinator.shared
    @ObservedObject private var pairing = OnDevicePairing.shared
    @State private var path: [Step] = []
    @State private var importing = false
    @Environment(\.dismiss) private var dismiss

    private var device: String { OnDevicePairing.deviceKind }

    var body: some View {
        NavigationStack(path: $path) {
            choose
                .hengeDestination(for: Step.self) { step in
                    switch step {
                    case .pairOnDevice: pairOnDevice
                    case .importFile: importFile
                    case .connect: connect
                    case .enable: enable
                    case .stikDebug: stikDebug
                    case .trollStore: trollStore
                    case .jailbreak: jailbreak
                    }
                }
        }
        .tint(Theme.accent)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.propertyList, .data]) { result in
            switch result {
            case .success(let url): jit.importPairingFile(url)
            case .failure(let failure):
                HengeLog.log("jit", "pairing import failed: \(failure.localizedDescription)")
            }
        }
        .onAppear {
            jit.refreshPairingStatus()
            pairing.reset()
            // A failed enable from the Library lands on the step that can fix it.
            if jit.error != nil, jit.hasPairing, jit.resolvedMethod == .builtIn {
                path = [.enable]
            }
            HengeLog.log("ui", "JIT walkthrough opened")
        }
        // Swiping the sheet away, or a copy shown from onboarding, must not
        // leave a request to show it again behind.
        .onDisappear { jit.showSetup = false }
    }

    private func close() {
        jit.showSetup = false
        dismiss()
    }

    // MARK: Choose

    private var preflightChecklist: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("JIT Ön Kontrol Listesi").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textDim)
            checkRow("İmza İzni (get-task-allow)",
                     ok: Entitlements.getTaskAllow || JITBootstrap.isJailbroken || JITBootstrap.isInstalledWithTrollStore,
                     detail: Entitlements.getTaskAllow ? "Açık (Sideloadly / Geliştirme imzası)" : "Kapalı — ESign/dağıtım sertifikasında JIT çalışmaz")
            checkRow("Yardımcı Uzantı (HengeJITHelper)",
                     ok: HengeBuiltInJIT.helperIdentifier != nil,
                     detail: HengeBuiltInJIT.helperIdentifier ?? "Eksik — İmzalarken uygulama uzantılarını koruyun")
            checkRow("Eşleştirme Dosyası (pairingFile.plist)",
                     ok: jit.hasPairing,
                     detail: jit.hasPairing ? (jit.pairingSource == .onDevice ? "Cihaz üzerinde eşleştirildi" : "Bilgisayardan içe aktarıldı") : "Henüz içe aktarılmadı")
            checkRow("LocalDevVPN Uygulaması",
                     ok: LocalDevVPN.isInstalled,
                     detail: LocalDevVPN.isInstalled ? "Yüklü (JIT açılırken bağlı olmalı)" : "App Store'dan yüklenmeli")
            checkRow("Kod Çalıştırma Testi (RX Selftest)",
                     ok: JITBootstrap.prewarmed && JITBootstrap.isLive,
                     detail: (JITBootstrap.prewarmed && JITBootstrap.isLive) ? "Doğrulandı (1 GB çift eşlemeli bölge aktif)" : (JITBootstrap.debuggedFlag ? "Debugger bağlı, selftest bekleniyor" : "Henüz çalışmadı"))
        }
        .padding(14)
        .hengeCard()
    }

    private func checkRow(_ title: String, ok: Bool, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ok ? .green : .orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textDim)
            }
            Spacer(minLength: 0)
        }
    }

    private var choose: some View {
        page(symbol: "bolt.fill", title: "JIT Kurulumu ve Doğrulama",
             subtitle: "macOS emülasyonu için yazılabilir ve çalıştırılabilir (RX/RW) bellek gerekir. iPadOS 27'de bunu yalnızca 'get-task-allow' iznine sahip bir hata ayıklayıcı (debugger) verebilir.") {
            preflightChecklist
            if let problem = jit.connectionProblem {
                outcome("\(problem.categoryTitle): \(problem.message)", ok: false)
            }
            VStack(spacing: 10) {
                let builtIn = HengeBuiltInJIT.unavailableReason
                let canAttach = Entitlements.getTaskAllow || JITBootstrap.isJailbroken || JITBootstrap.isInstalledWithTrollStore
                way("Bu \(device) üzerinde eşleştir", symbol: "iphone.radiowaves.left.and.right",
                    detail: !canAttach ? "İmzada 'get-task-allow' kapalı olduğu için kullanılamaz."
                        : builtIn ?? (!OnDevicePairing.isSupported ? "iOS 27 veya üzeri gerekir."
                        : jit.pairingSource == .onDevice ? "Bu \(device) üzerinde eşleştirildi."
                        : "Bilgisayar gerekmez. Ayarlar › Geliştirici Modu üzerinden eşleştirir."),
                    done: jit.pairingSource == .onDevice,
                    enabled: canAttach && builtIn == nil && OnDevicePairing.isSupported) { path.append(.pairOnDevice) }
                way("Eşleştirme dosyası kullan (Önerilen)", symbol: "doc.badge.plus",
                    detail: !canAttach ? "İmzada 'get-task-allow' kapalı olduğu için kullanılamaz."
                        : builtIn ?? (jit.pairingSource == .imported ? "Eşleştirme dosyası içe aktarıldı."
                        : "Bilgisayarda oluşturulan pairingFile.plist dosyasını içe aktarın."),
                    done: jit.pairingSource == .imported,
                    enabled: canAttach && builtIn == nil) { path.append(.importFile) }
                way("StikDebug kullan", symbol: "ant",
                    detail: !canAttach ? "İmzada 'get-task-allow' kapalı olduğu için StikDebug bağlanamaz."
                        : JITBootstrap.isStikDebugInstalled ? "StikDebug yüklü."
                        : "Harici StikDebug uygulaması üzerinden JIT açın.",
                    done: jit.method == .stikDebug,
                    enabled: canAttach) { path.append(.stikDebug) }
                way("TrollStore kullan", symbol: "sparkles",
                    detail: JITBootstrap.isTrollStoreInstalled ? "TrollStore yüklü."
                        : "TrollStore ile kurulmuş Henge için (iOS 14.0–17.0).",
                    done: jit.method == .trollStore) { path.append(.trollStore) }
                way("Jailbreak kullan", symbol: "lock.open",
                    detail: JITBootstrap.debuggedAtLaunch ? "Henge açıldığında JIT zaten aktifti."
                        : JITBootstrap.isJailbroken ? "Jailbreak algılandı. Allow JIT in Apps ayarını açın."
                        : "Dopamine üzerinden tek ayarla JIT sağlar.",
                    done: jit.method == .jailbreak || JITBootstrap.debuggedAtLaunch) { path.append(.jailbreak) }
            }
            if jit.hasPairing && HengeBuiltInJIT.isAvailable && Entitlements.getTaskAllow {
                Button { path.append(.connect) } label: {
                    Label("Mevcut eşleştirmeyle devam et", systemImage: "arrow.right")
                        .font(.system(size: 14, weight: .semibold))
                }
                .padding(.top, 4)
            }
        } actions: {
            Button("Şimdi değil") { close() }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textDim)
        }
    }

    private func way(_ title: String, symbol: String, detail: String, done: Bool,
                     enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 34, height: 34)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(detail).font(.system(size: 13)).foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: done ? "checkmark.circle.fill" : "chevron.right")
                    .font(.system(size: done ? 18 : 13, weight: .semibold))
                    .foregroundStyle(done ? .green : Theme.textDim.opacity(0.7))
            }
            .padding(14)
            .contentShape(Rectangle())
            .hengeCard()
        }
        .buttonStyle(CardButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    // MARK: Pair on this device

    private var pairedOnDevice: Bool {
        if case .paired = pairing.phase { return true }
        return false
    }

    private var pairOnDevice: some View {
        page(symbol: "iphone.radiowaves.left.and.right", title: "Bu \(device) Üzerinde Eşleştir",
             subtitle: "Henge Wi-Fi ağınızda bir bilgisayar gibi davranır ve \(device) cihazınız tıpkı bir Mac ile eşleşir gibi eşleşir.") {
            VStack(alignment: .leading, spacing: 14) {
                point(1, "Wi-Fi'yi açın, aşağıdaki **Eşleştirmeyi Başlat** düğmesine dokunun ve Yerel Ağ erişimine izin verin.",
                      done: pairing.phase != .idle)
                point(2, "**Ayarlar › Gizlilik ve Güvenlik › Geliştirici Modu** bölümünü açın, aşağı kaydırıp **\(OnDevicePairing.hostName) ile Eşleştir** seçeneğine dokunun.",
                      done: pairing.isShowingPin || pairedOnDevice)
                point(3, "Henge'in gösterdiği eşleştirme kodunu girin (bildirim olarak da gösterilir).",
                      done: pairedOnDevice)
                point(4, "Henge uygulamasına geri dönün.", done: pairedOnDevice)
            }
            .padding(16).hengeCard()
            pairingStatus
        } actions: {
            switch pairing.phase {
            case .idle, .failed:
                Button { pairing.start() } label: {
                    Label("Eşleştirmeyi Başlat", systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(PrimaryButtonStyle())
            case .waiting, .pin:
                Button("Eşleştirmeyi İptal Et", role: .cancel) { pairing.cancel() }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textDim)
            case .paired:
                Button("Devam Et") { path.append(.connect) }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    @ViewBuilder private var pairingStatus: some View {
        switch pairing.phase {
        case .idle:
            EmptyView()
        case .waiting:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    ProgressView().tint(Theme.accent)
                    Text("\(device) bekleniyor…").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                }
                Button("Ayarlar'ı Aç") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .font(.system(size: 14, weight: .semibold))
                if pairing.backgroundLimited {
                    Text("Bu kurulum arka planda yalnızca ~30 saniye bekleyebilir; hemen Ayarlar'a geçin.")
                        .font(.system(size: 13)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16).hengeCard()
        case .pin(let pin):
            VStack(spacing: 8) {
                Text("Bu kodu \(device) ekranında girin").font(.system(size: 14))
                    .foregroundStyle(Theme.textDim)
                Text(pin).font(.system(size: 40, weight: .bold, design: .monospaced)).tracking(6)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .accessibilityLabel("Eşleştirme kodu \(pin.map(String.init).joined(separator: " "))")
            }
            .frame(maxWidth: .infinity)
            .padding(18).hengeCard(high: true)
        case .paired(let name):
            outcome("\(name) ile eşleştirildi", ok: true)
        case .failed(let message):
            outcome(message, ok: false)
        }
    }

    // MARK: Import a pairing file

    private var importFile: some View {
        page(symbol: "doc.badge.plus", title: "Eşleştirme Dosyası Kullan",
             subtitle: "Bilgisayarda oluşturulan eşleştirme dosyası (pairingFile.plist), Henge'in yerleşik StikJIT yardımcısının bu \(device) ile konuşmasını sağlar.") {
            VStack(alignment: .leading, spacing: 14) {
                point(1, "Bilgisayarınızda [StikDebug eşleştirme rehberi](https://github.com/StikDebug/StikDebug-Guide/blob/main/pairing_file.md) ile bu \(device) için eşleştirme dosyası oluşturun.",
                      done: jit.pairingSource == .imported)
                point(2, "Dosyayı Dosyalar (Files) uygulamasına kaydedin.",
                      done: jit.pairingSource == .imported)
                point(3, "**Eşleştirme Dosyası Seç** düğmesine dokunup dosyayı içe aktarın.", done: jit.pairingSource == .imported)
            }
            .padding(16).hengeCard()
            Label("Eşleştirme dosyası yalnızca Henge'in kendi belgeler klasöründe tutulur ve tanılama raporlarında otomatik temizlenir.",
                  systemImage: "lock.fill")
                .font(.system(size: 13)).foregroundStyle(Theme.textDim)
            if let error = jit.error { outcome(error, ok: false) }
        } actions: {
            if jit.pairingSource == .imported {
                Button("Devam Et") { path.append(.connect) }.buttonStyle(PrimaryButtonStyle())
                Button("Başka bir dosya seç") { importing = true }
                    .font(.system(size: 15, weight: .medium))
            } else {
                Button { importing = true } label: { Label("Eşleştirme Dosyası Seç", systemImage: "folder") }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    // MARK: LocalDevVPN

    private var connect: some View {
        page(symbol: "network.badge.shield.half.filled", title: "LocalDevVPN'i Bağla",
             subtitle: "Henge'in JIT yardımcısı, cihazın hata ayıklama servisine yerel bir tünel (LocalDevVPN) üzerinden ulaşır. Cihaz dışına hiçbir veri çıkmaz.") {
            VStack(alignment: .leading, spacing: 14) {
                point(1, "App Store'dan [LocalDevVPN](\(LocalDevVPN.appStore.absoluteString)) uygulamasını yükleyin.",
                      done: LocalDevVPN.isInstalled)
                point(2, "**LocalDevVPN'i Bağla** düğmesine dokunun. VPN açılır ve otomatik olarak Henge'e döner.")
                point(3, "JIT açılırken VPN bağlantısını açık tutun.")
            }
            .padding(16).hengeCard()
        } actions: {
            Button(LocalDevVPN.actionTitle) { LocalDevVPN.open() }
                .buttonStyle(PrimaryButtonStyle())
            Button("VPN Bağlandı, Devam Et") { path.append(.enable) }
                .font(.system(size: 15, weight: .medium))
        }
    }

    // MARK: Enable

    /// Strictly requires both `ready` and `isLive` (native RX selftest == 42) before reporting JIT as active.
    private var attached: Bool { JITBootstrap.ready && JITBootstrap.isLive }

    private var enable: some View {
        page(symbol: "bolt.badge.checkmark", title: "JIT'i Etkinleştir ve Doğrula",
             subtitle: "İlk kontrolde Apple'ın Geliştirici Disk Görüntüsü (DDI) hazırlanır; ardından 1 GB JIT bölgesi ayrılıp gerçek kod çalıştırma testi (RX Selftest) doğrulanır.") {
            preflightChecklist
            VStack(alignment: .leading, spacing: 14) {
                point(1, "**Kurulumu Kontrol Et** düğmesine dokunun. LocalDevVPN ve Geliştirici Disk Görüntüsü doğrulanır.",
                      done: jit.prepared || attached)
                point(2, "**JIT'i Etkinleştir** düğmesine dokunun. Yardımcı bağlanır ve gerçek kod çalıştırma testi yapılır.", done: attached)
            }
            .padding(16).hengeCard()

            if jit.busy {
                HStack(spacing: 11) {
                    ProgressView().tint(Theme.accent)
                    Text(jit.status ?? "İşlem yapılıyor…").font(.system(size: 14)).foregroundStyle(Theme.text)
                    Spacer(minLength: 0)
                }
                .padding(16).hengeCard(high: true)
            } else if attached {
                outcome("JIT Açık (Kod çalıştırma testi doğrulandı). Sanal Mac başlatılabilir.", ok: true)
            } else if let error = jit.error {
                VStack(alignment: .leading, spacing: 10) {
                    if let problem = jit.connectionProblem {
                        Text(problem.categoryTitle)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.red)
                    }
                    outcome(error, ok: false)
                    if jit.connectionProblem == .pairing {
                        Button(OnDevicePairing.isSupported ? "Yeniden Eşleştir" : "Yeni Eşleştirme Dosyası İçe Aktar") {
                            path = [OnDevicePairing.isSupported ? .pairOnDevice : .importFile]
                        }
                        .font(.system(size: 14, weight: .semibold))
                    }
                    if jit.connectionProblem == .vpn || jit.connectionProblem == .pairing {
                        Button(LocalDevVPN.actionTitle) { LocalDevVPN.open() }
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
            } else if let status = jit.status {
                outcome(status, ok: true)
            }

            if !attached {
                Button("Geliştirici Disk Görüntüsünü (DDI) Sıfırla", role: .destructive) { jit.resetDDI() }
                    .font(.system(size: 13, weight: .medium))
                    .disabled(jit.busy)
                    .padding(.top, 4)
            }
        } actions: {
            if attached {
                Button("Tamam") { close() }.buttonStyle(PrimaryButtonStyle())
            } else if jit.prepared {
                Button { jit.enableBuiltIn() } label: { Label("JIT'i Etkinleştir", systemImage: "bolt.fill") }
                    .buttonStyle(PrimaryButtonStyle(enabled: !jit.busy))
                    .disabled(jit.busy)
            } else {
                Button("Kurulumu Kontrol Et") { jit.prepareBuiltIn() }
                    .buttonStyle(PrimaryButtonStyle(enabled: !jit.busy))
                    .disabled(jit.busy)
            }
        }
    }

    // MARK: StikDebug

    private var stikDebug: some View {
        page(symbol: "ant", title: "StikDebug Kullan",
             subtitle: "StikDebug, Henge'e dışarıdan bağlanan ayrı bir uygulamadır. Henge gerekli JIT betiğini otomatik gönderir.") {
            VStack(alignment: .leading, spacing: 14) {
                point(1, "[StikDebug](https://github.com/StikDebug/StikDebug/releases/latest) uygulamasını yükleyin.",
                      done: JITBootstrap.isStikDebugInstalled)
                point(2, "Bu \(device) cihazının eşleştirme dosyasını StikDebug içine aktarın.")
                point(3, "[LocalDevVPN](\(LocalDevVPN.appStore.absoluteString)) uygulamasını yükleyip bağlayın.")
                point(4, "Bir Mac başlattığınızda Henge StikDebug'ı açar, JIT bölgesini alır ve geri döner.")
            }
            .padding(16).hengeCard()
        } actions: {
            Button("StikDebug Kullan") {
                jit.method = .stikDebug
                HengeLog.log("ui", "JIT method set to StikDebug")
                close()
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    // MARK: TrollStore

    private var trollStore: some View {
        page(symbol: "sparkles", title: "TrollStore Kullan",
             subtitle: "TrollStore (iOS 14.0–17.0), kurduğu uygulamalara VPN veya eşleştirme dosyası gerekmeden JIT verebilir.") {
            VStack(alignment: .leading, spacing: 14) {
                point(1, "Henge.ipa dosyasını TrollStore üzerinden yükleyin.",
                      done: JITBootstrap.isInstalledWithTrollStore)
                point(2, "TrollStore Ayarları'nda 'URL Scheme' seçeneğini açın.")
                point(3, "Bir Mac başlatıldığında Henge otomatik olarak TrollStore'dan JIT ister.")
            }
            .padding(16).hengeCard()
            if !JITBootstrap.isTrollStoreInstalled {
                Label("Bu \(device) üzerinde TrollStore bulunamadı (yalnızca iOS 14.0–17.0 sürümlerini destekler).", systemImage: "info.circle")
                    .font(.system(size: 13)).foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            Button("TrollStore Kullan") {
                jit.method = .trollStore
                HengeLog.log("ui", "JIT method set to TrollStore")
                close()
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    // MARK: Jailbreak

    private var jailbreak: some View {
        page(symbol: "lock.open", title: "Jailbreak Kullan",
             subtitle: "Dopamine ile jailbreak yapılmış cihazlarda 'Allow JIT in Apps' ayarı açıldığında Henge doğrudan JIT ile başlar.") {
            VStack(alignment: .leading, spacing: 14) {
                point(1, "Dopamine uygulamasını açıp Ayarlar'a girin.", done: JITBootstrap.isJailbroken)
                point(2, "'Allow JIT in Apps' seçeneğini etkinleştirin.")
                point(3, "Henge'i tamamen kapatıp yeniden açın.",
                      done: JITBootstrap.debuggedAtLaunch)
            }
            .padding(16).hengeCard()
            if JITBootstrap.debuggedAtLaunch {
                Label("Henge açıldığında hata ayıklama izni aktifti.", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13)).foregroundStyle(.green)
            } else if !JITBootstrap.isJailbroken {
                Label("Bu \(device) üzerinde Jailbreak bulunamadı.", systemImage: "info.circle")
                    .font(.system(size: 13)).foregroundStyle(Theme.textDim)
            }
        } actions: {
            Button("Jailbreak Kullan") {
                jit.method = .jailbreak
                HengeLog.log("ui", "JIT method set to jailbreak")
                close()
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    // MARK: Pieces

    private func page<Content: View, Actions: View>(
        symbol: String, title: String, subtitle: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions) -> some View {
        ZStack {
            Theme.backdrop
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: symbol)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 56, height: 56)
                        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    Text(title).font(.system(size: 28, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(subtitle).font(.system(size: 15)).foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                    content()
                }
                .padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 24)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) { actions() }
                .padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 16)
                .background(Theme.backdrop)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Kapat") { close() }
            }
        }
    }

    private func point(_ number: Int, _ text: String, done: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green.opacity(0.18) : Theme.accentSoft)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.green)
                } else {
                    Text("\(number)").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.accent)
                }
            }
            .frame(width: 26, height: 26)
            Text(.init(text))
                .font(.system(size: 15))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func outcome(_ text: String, ok: Bool) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(ok ? .green : .red)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14).hengeCard()
    }
}
