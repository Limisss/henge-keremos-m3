import SwiftUI

/// A running Mac. Upright, its screen sits above a trackpad; on its side the screen fills the device
/// and is its own trackpad. Zoomed in, the screen fills the device either way and follows the pointer.
/// A keyboard, trackpad or mouse attached to an iPad works throughout.
struct SessionView: View {
    let mac: VirtualMac
    let close: () -> Void

    @StateObject private var display = DisplayRouter()
    @State private var error: String?
    @State private var state: Int32 = 0
    @State private var cpusOn: Int32 = 0
    @State private var userCode = false
    @State private var blocksPerSecond: Double = 0
    @State private var framesOut: UInt64 = 0
    @State private var framesIn: UInt64 = 0
    @State private var gpuFrames: UInt64 = 0
    @State private var gpuFPS: Double = 0
    @State private var bootDurationSeconds: Double?
    @State private var activeRAMMB: Int = 0
    @State private var pillAtBottom = true
    @State private var log: [String] = []
    @State private var started = Date()
    @AppStorage("henge.cpus") private var cpus = 4

    @State private var typing = false
    @State private var zoomed = false
    @State private var showDetails = false
    @State private var confirmStop = false
    @State private var zoomCentre = CGPoint(x: 0.5, y: 0.5) // where the zoomed view is, 0...1 of the Mac's screen
    @State private var map: UIImage?
    @State private var zoomFollowing: Task<Void, Never>?
    @State private var helperRunning = false
    @State private var shown = CGSize(width: 0.5, height: 0.5) // how much of the Mac's screen the zoomed view shows
    @Environment(\.scenePhase) private var scenePhase


    var body: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            let full = CGSize(width: geo.size.width + insets.leading + insets.trailing,
                              height: geo.size.height + insets.top + insets.bottom)
            let landscape = full.width > full.height
            let layout = Layout(full: full, insets: insets, landscape: landscape, zoomed: zoomed, typing: typing, centre: zoomCentre, aspect: mac.aspect)
            ZStack(alignment: .topLeading) {
                (landscape || zoomed ? Color.black : Desk.page)
                // One view in every layout: it holds the layer the engine draws into.
                BootDisplay(display: display, role: .device)
                    .opacity(display.isExternal ? 0 : 1)
                    .overlay {
                        if display.isExternal {
                            VStack(spacing: 8) {
                                Image(systemName: "display").font(.largeTitle)
                                Text("Mac harici ekranda gösteriliyor").font(.headline)
                                Text("Magic Keyboard, izleme dörtgeni veya fareyi buradan kullanabilirsiniz.")
                                    .font(.subheadline)
                            }
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding()
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .frame(width: layout.screen.width, height: layout.screen.height)
                    .clipShape(RoundedRectangle(cornerRadius: layout.fillsPhone ? 0 : 15, style: .continuous))
                    .overlay {
                        if !layout.fillsPhone {
                            RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Color.white.opacity(0.16), lineWidth: 0.5)
                        }
                    }
                    .position(x: layout.screen.midX, y: layout.screen.midY)
                Trackpad()
                    .frame(width: layout.touch.width, height: layout.touch.height)
                    .position(x: layout.touch.midX, y: layout.touch.midY)
                if !layout.fillsPhone {
                    uprightControls(layout)
                } else {
                    floatingControls(layout)
                }
                if let error { errorCard(error, layout) }
                KeyboardCatcher(active: $typing).frame(width: 0, height: 0)
            }
            .frame(width: full.width, height: full.height)
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.25), value: zoomed)
            .animation(.easeInOut(duration: 0.25), value: typing)
            .onAppear { shown = layout.shown }
            .onChange(of: layout.shown) { shown = $0 }
        }
        .statusBarHidden(zoomed || Device.isPad)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showDetails) { details }
        .confirmationDialog("'\(mac.name)' kapatılsın mı?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Mac'i Kapat", role: .destructive) { finish() }
        } message: {
            Text("Sanal Mac hemen kapatılır. Kaydedilmemiş çalışmalar kaybolabilir.")
        }
        .onChange(of: zoomed) { on in
            zoomFollowing?.cancel()
            zoomFollowing = on ? Task { await followPointer() } : nil
        }
        .onChange(of: pointerNeeded) { PointerLock.set(!$0) }
        .onChange(of: scenePhase) { phase in
            guard phase != .active else {
                display.refresh()
                return
            }
            HardwareKeys.releaseAll()
            HardwareMouse.shared.releaseButtons()
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            HardwareMouse.shared.start()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            zoomFollowing?.cancel()
            StickyKeys.shared.releaseAll()
            HardwareKeys.releaseAll()
            HardwareMouse.shared.stop()
        }
        .modifier(ExternalMacDisplayModifier(display: display, aspect: mac.aspect))
        .task { await run() }
        .task { await Sharing.followMacClipboard() }
    }

    /// When there is something of the app's to point at, iPadOS gets its own pointer back.
    private var pointerNeeded: Bool { showDetails || confirmStop || error != nil }

    // MARK: Layout

    /// Where everything goes, in points from the device's top left corner.
    private struct Layout {
        let screen: CGRect
        let touch: CGRect     // what is a trackpad besides the pad itself
        let fillsPhone: Bool
        let toolsY: CGFloat
        let pad: CGRect
        let insets: EdgeInsets
        var barY: CGFloat?    // where the controls go in the space beside the screen, if it has room for them

        var shown: CGSize {
            CGSize(width: min(touch.width / max(screen.width, 1), 1), height: min(touch.height / max(screen.height, 1), 1))
        }

        init(full: CGSize, insets: EdgeInsets, landscape: Bool, zoomed: Bool, typing: Bool, centre: CGPoint, aspect: CGFloat) {
            self.insets = insets
            let big = full.height >= 600 // an iPad on its side, or a window on one
            if zoomed {
                // Upright, as tall as the device. On its side, bigger than it fits: a big screen needs less.
                let height = landscape ? full.height * (big ? 1.5 : 2) : max(full.height - insets.bottom, full.width / aspect)
                let width = height * aspect
                let x = min(0, max(full.width - width, full.width / 2 - centre.x * width))
                let y = min(0, max(full.height - height, full.height / 2 - centre.y * height))
                screen = CGRect(x: x, y: y, width: width, height: height)
                touch = CGRect(origin: .zero, size: full)
                fillsPhone = true
                toolsY = 0
                pad = .zero
            } else if landscape, big {
                // Room to keep the controls off the Mac's menu bar, and the Mac above the on-screen keyboard.
                let bar: CGFloat = 62
                let room = typing ? full.height - insets.bottom - insets.top - bar - 8 : full.height
                // An iPad keeps clear of its side insets; a big iPhone (iPhone Duo) fills edge to edge.
                let side = Device.isPad ? 2 * max(insets.leading, insets.trailing) : 0
                let height = max(min(room, (full.width - side) / aspect), 200)
                let width = height * aspect
                let y = typing ? insets.top + bar : (full.height - height) / 2
                screen = CGRect(x: (full.width - width) / 2, y: y, width: width, height: height)
                touch = CGRect(origin: .zero, size: full)
                fillsPhone = true
                toolsY = 0
                pad = .zero
                if y - insets.top >= 54 { barY = insets.top + (y - insets.top) / 2 }
            } else if landscape {
                // Edge to edge. Phones wider than the Mac fill the height with room to spare beside the
                // Dynamic Island; a squarer phone (iPhone Duo) fills all of it, island and corners included.
                let height = min(full.height, full.width / aspect)
                let width = height * aspect
                screen = CGRect(x: (full.width - width) / 2, y: (full.height - height) / 2, width: width, height: height)
                touch = CGRect(origin: .zero, size: full)
                fillsPhone = true
                toolsY = 0
                pad = .zero
            } else {
                let width = full.width - 16
                let height = width / aspect
                screen = CGRect(x: 8, y: insets.top + 6, width: width, height: height)
                touch = screen
                fillsPhone = false
                toolsY = screen.maxY + 10
                let top = typing ? screen.maxY + 8 : toolsY + 54 + 10
                let bottom = full.height - insets.bottom - (typing ? 8 : 0)
                pad = CGRect(x: 8, y: top, width: width, height: max(bottom - top, 60))
            }
        }
    }

    // MARK: Upright

    @ViewBuilder private func uprightControls(_ layout: Layout) -> some View {
        if !typing {
            HStack {
                tool("keyboard", "Klavye") { typing = true }
                Spacer()
                pasteTool
                Spacer()
                tool("plus.magnifyingglass", "Yakınlaştır") { zoomed = true }
                Spacer()
                tool("info.circle", "Detaylar ve Ölçüm") { showDetails = true }
                Spacer()
                tool("power", "Kapat", tint: Desk.bad) { stopTapped() }
            }
            .padding(.horizontal, 22)
            .frame(width: layout.pad.width, height: 54)
            .background(Desk.card, in: Capsule())
            .overlay(Capsule().stroke(Desk.hairline, lineWidth: 0.5))
            .position(x: layout.pad.midX, y: layout.toolsY + 27)
            .transition(.opacity)
        }
        trackpadPanel(layout)
    }

    private func trackpadPanel(_ layout: Layout) -> some View {
        let compact = layout.pad.height < 260
        return VStack(spacing: 0) {
            ZStack {
                Trackpad()
                if compact {
                    Text("İzleme Dörtgeni (Trackpad)").font(.system(size: 14)).foregroundStyle(Desk.faint).allowsHitTesting(false)
                } else {
                    VStack(spacing: 6) {
                        hint("Sürükle", "imleci hareket ettir")
                        hint("Dokun", "sol tıkla")
                        hint("Basılı tutup sürükle", "pencere taşı / seç")
                        hint("İki parmakla", "kaydır (scroll)")
                    }
                    .allowsHitTesting(false)
                }
            }
            Rectangle().fill(Desk.hairline).frame(height: 0.5)
            HStack(spacing: 0) {
                MouseButton(title: "Sol Tık", button: 0)
                Rectangle().fill(Desk.hairline).frame(width: 0.5)
                MouseButton(title: "Sağ Tık", button: 1)
            }
            .frame(height: compact ? 50 : 70)
        }
        .background(Desk.card)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(Desk.hairline, lineWidth: 0.5))
        .frame(width: layout.pad.width, height: layout.pad.height)
        .position(x: layout.pad.midX, y: layout.pad.midY)
    }

    private func hint(_ strong: String, _ rest: String) -> some View {
        (Text(strong).foregroundColor(Desk.dim).fontWeight(.semibold) + Text(" \(rest)").foregroundColor(Desk.faint))
            .font(.system(size: 15))
    }

    /// The system's paste button: iOS asks no permission for it, as it would if the app read the clipboard itself.
    private var pasteTool: some View {
        PasteButton(payloadType: String.self) { texts in
            if let text = texts.first { Sharing.paste(text) }
        }
        .labelStyle(.iconOnly)
        .buttonBorderShape(.circle)
        .tint(Desk.raised)
    }

    private func tool(_ symbol: String, _ label: String, tint: Color = Desk.text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    // MARK: Filling the phone / iPad

    @ViewBuilder private func floatingControls(_ layout: Layout) -> some View {
        let landscape = layout.touch.width > layout.touch.height
        let top = layout.insets.top + (landscape ? 8 : 6)
        let pill = HStack(spacing: 4) {
            tool("keyboard", "Ekran Klavyesi", tint: .white) { typing.toggle() }
            pasteTool
            tool(zoomed ? "minus.magnifyingglass" : "plus.magnifyingglass", zoomed ? "Uzaklaştır" : "Yakınlaştır", tint: zoomed ? Desk.accentLight : .white) { zoomed.toggle() }
            tool("info.circle", "Detaylar ve Ölçüm", tint: .white) { showDetails = true }
            tool(pillAtBottom ? "arrow.up.to.line" : "arrow.down.to.line", "Araç Çubuğu Konumu", tint: .white.opacity(0.8)) {
                withAnimation(.easeInOut(duration: 0.2)) { pillAtBottom.toggle() }
            }
            Rectangle().fill(Color.white.opacity(0.3)).frame(width: 1, height: 22).padding(.horizontal, 4)
            tool("power", "Mac'i Kapat", tint: Desk.bad) { stopTapped() }
        }
        .padding(.horizontal, 8)
        .frame(height: 50)
        .deskGlass(in: Capsule())
        if let barY = layout.barY, !pillAtBottom {
            pill.position(x: layout.touch.midX, y: barY)
        } else if typing || !pillAtBottom {
            pill.position(x: layout.touch.midX, y: top + 25)
        } else {
            pill.position(x: layout.touch.midX, y: layout.touch.height - layout.insets.bottom - 34)
        }
        if zoomed { zoomMap(layout) }
    }

    /// The whole screen, small, with where the zoomed view is on it.
    private func zoomMap(_ layout: Layout) -> some View {
        let width: CGFloat = 112, height = width / mac.aspect
        let viewW = min(layout.touch.width / layout.screen.width, 1) * width
        let viewH = min(layout.touch.height / layout.screen.height, 1) * height
        let left = (-layout.screen.minX / layout.screen.width) * width
        let top = (-layout.screen.minY / layout.screen.height) * height
        return ZStack(alignment: .topLeading) {
            Color.black
            if let map { Image(uiImage: map).resizable() }
            RoundedRectangle(cornerRadius: 3).stroke(Color.white, lineWidth: 1.5)
                .frame(width: viewW, height: viewH)
                .offset(x: left, y: top)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(3)
        .deskGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .position(x: layout.touch.width - width / 2 - 15, y: layout.insets.top + height / 2 + 20)
        .allowsHitTesting(false)
    }

    /// Keeps the pointer in view: the view moves when the pointer nears its edge.
    private func followPointer() async {
        var tick = 0
        while !Task.isCancelled {
            var x: Int32 = 0, y: Int32 = 0
            if henge_vm_pointer(&x, &y) == 0 {
                moveZoom(toward: CGPoint(x: CGFloat(x) / CGFloat(mac.screen.width), y: CGFloat(y) / CGFloat(mac.screen.height)))
            }
            if tick % 60 == 0, let image = MacPreview.capture(width: 224, height: Int(224 / mac.aspect)) { map = UIImage(cgImage: image) }
            tick += 1
            try? await Task.sleep(nanoseconds: 33_000_000)
        }
    }

    private func moveZoom(toward p: CGPoint) {
        // How much of the screen the view shows, and a margin inside that.
        let shownX = shown.width, shownY = shown.height
        let reachX = shownX * 0.3, reachY = shownY * 0.3
        var c = zoomCentre
        if p.x < c.x - reachX { c.x = p.x + reachX } else if p.x > c.x + reachX { c.x = p.x - reachX }
        if p.y < c.y - reachY { c.y = p.y + reachY } else if p.y > c.y + reachY { c.y = p.y - reachY }
        c.x = min(max(c.x, shownX / 2), 1 - shownX / 2)
        c.y = min(max(c.y, shownY / 2), 1 - shownY / 2)
        guard c != zoomCentre else { return }
        withAnimation(.linear(duration: 0.08)) { zoomCentre = c }
    }

    // MARK: Status

    private func errorCard(_ text: String, _ layout: Layout) -> some View {
        let canFallbackTo3GB = henge_vm_state() == 0 && (activeRAMMB > 3072 || mac.ramMB > 3072)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Sanal Mac Başlatılamadı").font(.system(size: 17, weight: .semibold))
            Text(text).font(.system(size: 14)).foregroundStyle(Desk.dim)
            if canFallbackTo3GB {
                Text("Başarısız bellek ayırma kaynakları temizlendi. Uygulamayı kapatmadan 3 GB (3072 MB) güvenli RAM ile hemen başlatabilirsiniz:")
                    .font(.system(size: 12)).foregroundStyle(Desk.good)
                Button("3 GB RAM ile Hemen Başlat") {
                    var updated = mac
                    updated.ramMB = 3072
                    Machines.shared.update(updated)
                    error = nil
                    Task { await run(overrideRAMMB: 3072) }
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Desk.good)
                .padding(.top, 2)
            } else if henge_vm_state() != 0 {
                Text("Not: Bu oturumda sanal makine motoru çalıştığı için yeniden başlatmadan önce Henge'i kapatıp tekrar açmanız gerekir.")
                    .font(.system(size: 12)).foregroundStyle(.orange)
            }
            Button("Kapat") { close() }.font(.system(size: 15, weight: .semibold)).foregroundStyle(Desk.accentLight)
        }
        .padding(18)
        .frame(width: min(layout.touch.width, 410) - 32, alignment: .leading)
        .background(Desk.raised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .position(x: (layout.fillsPhone ? layout.touch.midX : layout.pad.midX), y: layout.fillsPhone ? layout.touch.midY : layout.pad.midY)
    }

    private var phase: String {
        switch state {
        case 0: return error == nil ? "Başlatılıyor…" : "Başlatılamadı"
        case 1: return userCode ? "macOS Çalışıyor (EL0 Aktif)" : "macOS Önyükleniyor (Kernel)"
        default: return "Durdu (\(String(cString: henge_vm_exit_reason())))"
        }
    }

    private var details: some View {
        NavigationStack {
            List {
                Section(phase) {
                    LabeledContent("Aktif CPU", value: "\(cpusOn) / \(cpus)")
                    LabeledContent("Sanal Mac RAM", value: "\(activeRAMMB > 0 ? activeRAMMB : mac.ramMB) MB")
                    LabeledContent("Açılış Süresi (EL0)", value: bootDurationSeconds.map { String(format: "%.1f sn", $0) } ?? "Ölçülüyor…")
                    LabeledContent("Çevrilen Blok Hızı", value: String(format: "%.2f M/sn", blocksPerSecond / 1e6))
                    LabeledContent("GPU Kare Hızı", value: String(format: "%.1f kare/sn (toplam %llu)", gpuFPS, gpuFrames))
                    LabeledContent("Ağ Paketleri", value: "\(framesOut) giden, \(framesIn) gelen")
                    LabeledContent("Çalışma Süresi", value: "\(Int(Date().timeIntervalSince(started))) sn")
                }
                Section("Bellek Durumu (4 Boyutlu Tanılama)") {
                    LabeledContent("Cihaz Fiziksel RAM", value: "\(Device.physicalMemoryMB) MB")
                    LabeledContent("Uygulama Bellek Sınırı", value: "\(Device.processMemoryLimitMB) MB")
                    LabeledContent("Anlık Tüketim (phys_footprint)", value: "\(Device.currentFootprintMB) MB")
                    LabeledContent("Kalan Güvenli Pay (jetsam öncesi)", value: "\(Device.currentAvailableMemoryMB) MB")
                }
                Section("Klavye ve İzleme Dörtgeni (Magic Keyboard)") {
                    Button("Takılı Tuşları ve İmleç Kilidini Sıfırla") {
                        HardwareKeys.releaseAll()
                        HardwareMouse.shared.releaseButtons()
                        StickyKeys.shared.releaseAll()
                        HardwareMouse.shared.reloadSettings()
                        PointerLock.set(true)
                        showDetails = false
                    }
                    Text("iPadOS kısayolları (⌘-Tab, Dünya tuşu) sonrasında bir tuş basılı kalırsa veya imleç kilidi çıkarsa bu düğmeyle sıfırlayabilirsiniz.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Dosya ve Pano Paylaşımı") {
                    LabeledContent("Pano ve Klasör Paylaşımı", value: helperRunning ? "Açık" : "Kurulmadı")
                    if !helperRunning {
                        Button("Kurulum Komutunu Terminal'e Yaz") {
                            showDetails = false
                            Task {
                                try? await Task.sleep(nanoseconds: 600_000_000)
                                await Sharing.typeSetUpCommand()
                            }
                        }
                    }
                    Text(helperRunning
                         ? "Dosyalar (Files) › Henge › Shared klasörüne koyduğunuz dosyalar Mac'in ev dizinindeki Henge klasöründe görünür. Mac'te kopyaladığınız metinler iPad panosuna aktarılır."
                         : "Her Mac için bir kez: Mac içinde Terminal'i açın, bu düğmeye dokunun ve Return tuşuna basın. (Yazılacak komut: \(Sharing.setUpCommand), ABD klavye düzeni gerekir.)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Günlük (Son 30 Satır)") {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(log.suffix(30).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Performans ve Detaylar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kapat") { showDetails = false }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Running

    private func run(overrideRAMMB: Int? = nil) async {
        var targetMac = mac
        if let overrideRAMMB { targetMac.ramMB = overrideRAMMB }
        let ram = GuestMemory.prepare(targetMac)
        activeRAMMB = Int(ram)
        HengeLog.log("session", "available memory \(henge_available_memory() >> 20) MB, footprint \(henge_phys_footprint() >> 20) MB")
        guard ram >= 1024 else {
            error = "Bu sanal Mac'in belleği için yeterli boş depolama veya sanal adres alanı yok."
            return
        }
        var buffer = [CChar](repeating: 0, count: 256)
        Sharing.prepare()
        henge_vm_set_display(UInt32(targetMac.screen.width), UInt32(targetMac.screen.height))
        let rc = henge_vm_boot(targetMac.rom.path, targetMac.disk.path, targetMac.aux.path, targetMac.ecid, targetMac.seed, ram, Int32(cpus), &buffer, buffer.count)
        if rc != 0 {
            error = String(cString: buffer)
            return
        }
        started = Date()
        bootDurationSeconds = nil
        var used = targetMac
        used.lastUsed = started
        Machines.shared.update(used)
        var lastBlocks = henge_vm_blocks()
        var lastGPUFrames = henge_vm_gpu_frames()
        var lastTime = Date()
        var tick = 0
        while !Task.isCancelled {
            state = henge_vm_state()
            cpusOn = henge_vm_cpus_on()
            let nowEL0 = henge_vm_guest_el0() != 0
            if nowEL0 && !userCode {
                let dur = Date().timeIntervalSince(started)
                bootDurationSeconds = dur
                HengeLog.log("bench", String(format: "macOS user-space (EL0) reached in %.1f s (RAM %llu MB, CPUs %d, phys_footprint %zu MB, avail %zu MB)",
                                             dur, ram, cpus, henge_phys_footprint() >> 20, henge_available_memory() >> 20))
            }
            userCode = userCode || nowEL0
            let now = Date(), dt = max(now.timeIntervalSince(lastTime), 0.001)
            let blocks = henge_vm_blocks()
            let curGPU = henge_vm_gpu_frames()
            blocksPerSecond = Double(blocks &- lastBlocks) / dt
            gpuFPS = Double(curGPU &- lastGPUFrames) / dt
            gpuFrames = curGPU
            lastBlocks = blocks
            lastGPUFrames = curGPU
            lastTime = now
            framesOut = henge_vm_net_frames(1)
            framesIn = henge_vm_net_frames(0)
            helperRunning = Sharing.helperRunning
            log = Array(HengeLog.recentLines(200))
            if state == 2 { break }
            tick += 1
            if tick % 30 == 0 { HengeLog.logFootprint("session") } // how close to the limit, for a memory kill leaves no crash report
            if tick % 60 == 0 { MacPreview.save(for: targetMac) }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func stopTapped() {
        if state == 1 { confirmStop = true } else { close() }
    }

    private func finish() {
        if state == 1 {
            MacPreview.saveNow(for: mac)
            henge_vm_stop()
        }
        close()
    }
}
