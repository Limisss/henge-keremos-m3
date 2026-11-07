import SwiftUI

/// One Mac: what it has, and what can be done with it.
struct MacSettingsView: View {
    @ObservedObject private var machines = Machines.shared
    @Environment(\.dismiss) private var dismiss
    @State private var mac: VirtualMac
    @State private var confirmDelete = false
    @State private var movingExport = false
    @AppStorage("henge.cpus") private var cpus = 4

    init(mac: VirtualMac) { _mac = State(initialValue: mac) }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                DeskHeading("Mac Adı")
                TextField("Ad", text: $mac.name)
                    .font(.system(size: 16))
                    .submitLabel(.done)
                    .padding(.horizontal, 17)
                    .padding(.vertical, 14)
                    .deskCard()
                    .onSubmit(save)

                DeskHeading("Bellek (RAM)")
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(mac.ramMB / 1024) GB").font(.system(size: 26, weight: .bold))
                        Spacer()
                        Text("Fiziksel: \(Device.physicalMemoryMB) MB · Sınır: \(Device.processMemoryLimitMB) MB")
                            .font(.system(size: 12)).foregroundStyle(Desk.dim).multilineTextAlignment(.trailing)
                    }
                    Picker("Bellek", selection: Binding(get: { mac.ramMB / 1024 }, set: { mac.ramMB = $0 * 1024; save() })) {
                        ForEach(Device.ramOptionsGB, id: \.self) { Text("\($0) GB").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    let adv = Device.ramAdvisory(forGB: mac.ramMB / 1024)
                    Text(adv.message)
                        .font(.system(size: 12))
                        .foregroundStyle(adv.level == .recommended ? Desk.good : adv.level == .caution ? .orange : Desk.bad)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(17)
                .deskCard()

                DeskHeading("İşlemci Çekirdeği")
                Stepper(value: $cpus, in: 1...6) {
                    HStack {
                        Text("Sanal CPU").font(.system(size: 16))
                        Spacer()
                        Text("\(cpus)").font(.system(size: 16, weight: .semibold))
                    }
                }
                .padding(.horizontal, 17)
                .padding(.vertical, 10)
                .deskCard()

                if Device.fittingScreen.height != 1080 {
                    DeskHeading("Ekran Oranı")
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Ekran", selection: Binding(get: { mac.screen.height == 1080 }, set: { wide in
                            (mac.screenWidth, mac.screenHeight) = wide ? (1920, 1080) : Device.fittingScreen
                            save()
                        })) {
                            Text("\(Device.name) Ekranına Tam Sığdır").tag(false)
                            Text("16:9 Geniş").tag(true)
                        }
                        .pickerStyle(.segmented)
                        Text("\(mac.screen.width) × \(mac.screen.height). Değişiklik bu Mac bir sonraki başlatıldığında uygulanır.")
                            .font(.system(size: 13)).foregroundStyle(Desk.dim)
                    }
                    .padding(17)
                    .deskCard()
                }

                DeskHeading("Depolama")
                VStack(spacing: 11) {
                    HStack {
                        Text("\(ByteText.string(UInt64(max(mac.bytesUsed, 0)))) kullanılan").font(.system(size: 16))
                        Spacer()
                        Text("/ toplam \(ByteText.string(UInt64(max(mac.diskBytes, 0))))").font(.system(size: 16)).foregroundStyle(Desk.dim)
                    }
                    DeskBar(fraction: Double(mac.bytesUsed) / Double(max(mac.diskBytes, 1)))
                }
                .padding(17)
                .deskCard()

                DeskHeading("Yedekleme ve Yönetim")
                manage
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .deskColumn()
        }
        .background(Desk.page)
        .navigationTitle(mac.name)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear(perform: save)
        .fileMover(isPresented: $movingExport, file: machines.lastExport) { result in
            switch result {
            case .success: machines.lastExport = nil
            case .failure(let error): machines.lastError = error.localizedDescription
            }
        }
        .confirmationDialog("'\(mac.name)' silinsin mi?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Sanal Mac'i Sil", role: .destructive) {
                machines.delete(mac.id)
                dismiss()
            }
        } message: {
            Text("Bu sanal Mac'in diski bu \(Device.name)'dan kalıcı olarak silinir.")
        }
    }

    private var manage: some View {
        VStack(spacing: 0) {
            if let name = machines.exporting {
                VStack(alignment: .leading, spacing: 9) {
                    Text("\(name) dışa aktarılıyor… Henge'i açık tutun").font(.system(size: 15))
                    DeskBar(fraction: machines.exported)
                }
                .padding(17)
            } else {
                row("Sanal Mac'i Dışa Aktar / Yedekle", symbol: "square.and.arrow.up", tint: Desk.accentLight) { machines.export(mac) }
            }
            if let folder = machines.lastExport {
                divider
                VStack(alignment: .leading, spacing: 8) {
                    Text("Dosyalar (Files) › Henge › Exports › \(folder.lastPathComponent) altına kaydedildi. Uygulamayı silmeden veya yeniden yüklemeden önce başka bir klasöre taşıyın.")
                        .font(.system(size: 13)).foregroundStyle(Desk.dim)
                    Button("Yedeği Başka Klasöre Taşı…") { movingExport = true }
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Desk.accentLight)
                }
                .padding(17)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            divider
            row("Bu Sanal Mac'i Sil", symbol: nil, tint: Desk.bad) { confirmDelete = true }
        }
        .deskCard()
    }

    private var divider: some View { Rectangle().fill(Desk.hairline).frame(height: 0.5) }

    private func row(_ title: String, symbol: String?, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 16)).foregroundStyle(tint)
                Spacer()
                if let symbol { Image(systemName: symbol).foregroundStyle(tint) }
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
    }

    private func save() {
        if mac.name.isEmpty { mac.name = "Mac" }
        machines.update(mac)
    }
}
