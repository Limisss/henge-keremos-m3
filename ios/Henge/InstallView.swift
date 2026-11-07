import SwiftUI

/// Download macOS (or use a copy already on this device) and install it on a new Mac.
struct InstallView: View {
    @ObservedObject private var installer = Installer.shared
    @StateObject private var display = DisplayRouter()
    @State private var release = MacOSRelease.all.first(where: Installer.haveImage) ?? MacOSRelease.all[0]
    @State private var name = "Mac"
    @State private var ramGB = Device.suggestedRAMGB
    @State private var deleteAfter = false
    @State private var refresh = 0 // redraws the list when a download is deleted
    @State private var details = false
    @State private var stageStarted = Date()
    @State private var stageSeen = -1
    @State private var confirmDeleteDownload: MacOSRelease?
    @AppStorage("henge.cpus") private var cpus = 4

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    switch installer.phase {
                    case .idle: chooser
                    case .downloading, .preparing, .installing: progress
                    case .done(let text): finished(text)
                    case .failed(let text): failed(text)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .deskColumn()
            }
            .background(Desk.page)
            .navigationTitle(installer.busy ? "macOS Kuruluyor" : "macOS Kur")
        }
    }

    // MARK: Choosing

    @ViewBuilder private var chooser: some View {
        DeskHeading("macOS Sürümü")
        VStack(spacing: 0) {
            ForEach(MacOSRelease.all) { r in
                Button { release = r } label: { versionRow(r) }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if Installer.haveImage(r) {
                            Button("İndirilen Dosyayı Sil", role: .destructive) { confirmDeleteDownload = r }
                        }
                    }
                if r.id != MacOSRelease.all.last?.id { Rectangle().fill(Desk.hairline).frame(height: 0.5) }
            }
        }
        .deskCard()
        .id(refresh)
        .confirmationDialog("Bu indirilen IPSW silinsin mi?", isPresented: Binding(get: { confirmDeleteDownload != nil }, set: { if !$0 { confirmDeleteDownload = nil } }),
                            titleVisibility: .visible) {
            Button("İndirilen Dosyayı Sil", role: .destructive) {
                if let r = confirmDeleteDownload { Installer.deleteImage(r) }
                refresh += 1
            }
        }

        DeskHeading("Yeni Sanal Mac")
        VStack(spacing: 0) {
            TextField("Mac Adı", text: $name)
                .font(.system(size: 16))
                .padding(.horizontal, 17)
                .padding(.vertical, 14)
            Rectangle().fill(Desk.hairline).frame(height: 0.5)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Bellek (RAM)").font(.system(size: 16))
                    Spacer()
                    Picker("Bellek", selection: $ramGB) {
                        ForEach(Device.ramOptionsGB, id: \.self) { Text("\($0) GB").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }
                let adv = Device.ramAdvisory(forGB: ramGB)
                Text(adv.message)
                    .font(.system(size: 12))
                    .foregroundStyle(adv.level == .recommended ? Desk.good : adv.level == .caution ? .orange : Desk.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 10)
            Rectangle().fill(Desk.hairline).frame(height: 0.5)
            Toggle("Kurulum bittikten sonra IPSW dosyasını sil", isOn: $deleteAfter)
                .font(.system(size: 16))
                .padding(.horizontal, 17)
                .padding(.vertical, 10)
        }
        .deskCard()

        Button(Installer.haveImage(release) ? "Kurulumu Başlat (İndirilen IPSW ile)" : "İndir ve Kur") {
            installer.start(release, name: name.isEmpty ? "Mac" : name, ramMB: ramGB * 1024, cpus: cpus, keepImage: !deleteAfter)
        }
        .buttonStyle(DeskButtonStyle(enabled: JITBootstrap.ready && !Device.chipTooOld))
        .disabled(!JITBootstrap.ready || Device.chipTooOld)
        .padding(.top, 20)
        Text(Device.chipTooOld ? Device.chipTooOldText : JITBootstrap.ready ? "Henge'i açık tutun ve \(Device.name) cihazınızı şarja takın. Yaklaşık \(ByteText.string(UInt64(Installer.spaceNeeded(release)))) boş alan gerekir."
                                : "Kuruluma başlamadan önce JIT'i etkinleştirip doğrulayın.")
            .font(.system(size: 13))
            .foregroundStyle(Desk.dim)
            .multilineTextAlignment(.center)
            .padding(.top, 10)
    }

    private func versionRow(_ r: MacOSRelease) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name).font(.system(size: 16, weight: .medium)).foregroundStyle(Desk.text)
                if let size = Installer.imageSize(r) {
                    Text("İndirildi (Hazır), \(ByteText.string(UInt64(size)))").font(.system(size: 13)).foregroundStyle(Desk.good)
                } else {
                    Text("\(ByteText.string(UInt64(r.bytes))) indirme").font(.system(size: 13)).foregroundStyle(Desk.dim)
                }
                Text(r.note).font(.system(size: 13)).foregroundStyle(Desk.dim)
            }
            Spacer()
            if release == r { Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Desk.accentLight) }
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    // MARK: Going

    private static let stages = ["İndir", "Kurulumu Başlat", "macOS Yaz", "Doğrula", "Tamamla"]

    private var stage: Int {
        switch installer.phase {
        case .downloading: return 0
        case .preparing: return 1
        default:
            switch installer.step {
            case 0, 1: return 1
            case 2: return 2
            case 3: return 3
            default: return 4
            }
        }
    }

    private var fraction: Double {
        if case .downloading = installer.phase {
            return installer.expected > 0 ? Double(installer.received) / Double(installer.expected) : 0
        }
        return installer.stepProgress
    }

    /// From how this step has gone so far; nothing until there is enough to go on.
    private var timeLeft: String? {
        let elapsed = Date().timeIntervalSince(stageStarted)
        guard stageSeen == stage, fraction > 0.03, fraction < 1, elapsed > 10 else { return nil }
        let minutes = Int((elapsed / fraction * (1 - fraction) / 60).rounded(.up))
        return minutes <= 1 ? "Bu adımda yaklaşık 1 dakika kaldı" : "Bu adımda yaklaşık \(minutes) dakika kaldı"
    }

    @ViewBuilder private var progress: some View {
        Text("Bu \(Device.name) üzerine \(release.name) kuruluyor. Henge'i açık tutun.")
            .font(.system(size: 16))
            .foregroundStyle(Desk.dim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.bottom, 16)

        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 0) {
                Text("%\(Int(fraction * 100))")
                    .font(.system(size: 66, weight: .bold))
                    .monospacedDigit()
                Text(timeLeft ?? "Adım \(stage + 1) / \(Self.stages.count)")
                    .font(.system(size: 15))
                    .foregroundStyle(Desk.dim)
                    .padding(.top, 2)
                    .padding(.bottom, 16)
                DeskBar(fraction: fraction, height: 11)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .deskCard(radius: 30)
        }
        .onChange(of: stage) { value in
            stageSeen = value
            stageStarted = Date()
        }
        .onAppear {
            stageSeen = stage
            stageStarted = Date()
        }

        DeskHeading("Adımlar")
        VStack(spacing: 0) {
            ForEach(Array(Self.stages.enumerated()), id: \.offset) { i, title in
                HStack {
                    Text(title)
                        .font(.system(size: 16, weight: i == stage ? .semibold : .regular))
                        .foregroundStyle(i > stage ? Desk.faint : Desk.text)
                    Spacer()
                    if i < stage {
                        Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Desk.good)
                    } else if i == stage {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, 17)
                .padding(.vertical, 13)
                if i < Self.stages.count - 1 { Rectangle().fill(Desk.hairline).frame(height: 0.5) }
            }
        }
        .deskCard()

        Button(details ? "Detayları Gizle" : "Detayları Göster") { withAnimation { details.toggle() } }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Desk.accentLight)
            .padding(.top, 14)
        if details {
            VStack(spacing: 12) {
                if case .installing = installer.phase {
                    BootDisplay(display: display, role: .device)
                        .aspectRatio(16.0 / 10.0, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
                LogTail()
            }
            .padding(14)
            .deskCard()
            .padding(.top, 10)
        }
    }

    private func finished(_ text: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(Desk.good).padding(.top, 8)
            Text("Kurulum Tamamlandı").font(.system(size: 24, weight: .bold))
            Text(text).font(.system(size: 15)).foregroundStyle(Desk.dim).multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .deskCard(radius: 30)
        .padding(.top, 8)
    }

    @ViewBuilder private func failed(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Kurulum Tamamlanamadı").font(.system(size: 22, weight: .bold))
            Text(text).font(.system(size: 15))
            if Installer.haveImage(installer.retryContext?.release ?? release) {
                Text("İndirilen macOS kurulum dosyası (IPSW) cihazda korundu; yeniden indirme yapılmaz.")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Desk.good)
            }
            if installer.canRetryInProcessWith3GB {
                Text("Başarısız bellek ayırma kaynakları temizlendi. Uygulamayı kapatmadan doğrudan 3 GB RAM ile tekrar deneyebilirsiniz:")
                    .font(.system(size: 13)).foregroundStyle(Desk.dim)
                Button("3 GB RAM ile Hemen Tekrar Dene (İndirmeden)") {
                    ramGB = 3
                    installer.retryWith3GB()
                }
                .buttonStyle(DeskButtonStyle())
                .padding(.top, 4)
            } else if installer.requiresAppRestartBeforeRetry {
                Text("Bu oturumda sanal makine motoru başlatılıp durduğu için tekrar denemeden önce Henge'i tamamen kapatıp (yukarı kaydırarak) yeniden açın.")
                    .font(.system(size: 13)).foregroundStyle(.orange)
            }
            Button("Kurulum Seçeneklerine Dön") { installer.reset() }
                .buttonStyle(DeskButtonStyle(enabled: true))
                .padding(.top, 4)
        }
        .padding(18)
        .deskCard(radius: 30)
        .padding(.top, 8)
        DeskHeading("Günlük (Log)")
        LogTail().padding(14).frame(maxWidth: .infinity, alignment: .leading).deskCard()
    }
}

/// The last lines of Henge's log.
private struct LogTail: View {
    @State private var lines: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            while !Task.isCancelled {
                lines = Array(HengeLog.recentLines(14))
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}
