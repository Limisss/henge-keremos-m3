import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject private var jit = JITCoordinator.shared
    @AppStorage(JITCoordinator.autoEnableKey) private var jitAtLaunch = false
    @AppStorage(HardwareMouse.speedKey) private var mouseSpeed = 1.0
    @AppStorage(HardwareMouse.reverseKey) private var reverseScrolling = false
    @State private var showDiagnosticPreview = false

    var body: some View {
        NavigationStack {
            Form {
                Section("JIT ve İmza Durumu") {
                    LabeledContent("JIT Durumu", value: JITBootstrap.ready && JITBootstrap.isLive ? "Açık (Kod Testi Doğrulandı)" : "Kapalı")
                    LabeledContent("get-task-allow İzni", value: Entitlements.getTaskAllow ? "Açık" : "Kapalı")
                    Picker("JIT Yöntemi", selection: $jit.method) {
                        ForEach(JITMethod.allCases) { Text($0.title).tag($0) }
                    }
                    Text(jit.method == .automatic ? jit.automaticDescription : "Henge \(jit.method.title) yöntemini kullanır.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("JIT Kurulumu ve Ön Kontrol…") { jit.showSetup = true }
                    Toggle("Henge açıldığında JIT'i otomatik etkinleştir", isOn: $jitAtLaunch)
                    LabeledContent("JIT Kod Bölgesi", value: "\(JITBootstrap.jitBytes >> 20) MB (RX/RW çift eşlemeli)")
                }
                .listRowBackground(Desk.card)
                Section("Bellek Yönetimi (4 Boyutlu Değerlendirme)") {
                    LabeledContent("Fiziksel RAM (Cihaz)", value: "\(Device.physicalMemoryMB) MB")
                    LabeledContent("Uygulama Bellek Sınırı", value: ByteText.string(UInt64(Entitlements.memoryLimitAtLaunch)))
                    LabeledContent("Anlık Tüketim (phys_footprint)", value: "\(Device.currentFootprintMB) MB")
                    LabeledContent("Kalan Güvenli Pay", value: ByteText.string(UInt64(henge_available_memory())))
                    LabeledContent("Yüksek Bellek İzni", value: Entitlements.increasedMemory ? "Açık" : "Kapalı")
                    LabeledContent("Geniş Sanal Adres Alanı", value: Entitlements.extendedAddressing ? "Açık" : "Kapalı")
                    LabeledContent("Önerilen Sanal Mac RAM", value: "\(Device.suggestedRAMGB) GB")
                    Text(Entitlements.increasedMemory && Entitlements.extendedAddressing
                         ? "Yüksek bellek ve geniş sanal adres alanı izinleri aktif. Sanal Mac için 3 GB veya 4 GB güvenle kullanılabilir."
                         : "Bu kurulumda (örn. Sideloadly ücretsiz Apple hesabı) yüksek bellek ve geniş adres alanı izinleri Apple tarafından kırpılmıştır (~5.1 GB sınır). 1 GB JIT bölgesi ve emülatör tabloları sonrasında en kararlı seçenek 3 GB RAM'dir.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                if Device.isPad {
                    Section("Magic Keyboard, Fare ve İzleme Dörtgeni") {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("İmleç Hızı")
                                Spacer()
                                Text(String(format: "%.1fx", mouseSpeed)).foregroundStyle(.secondary)
                            }
                            Slider(value: $mouseSpeed, in: 0.5...3.0)
                        }
                        Toggle("Ters (Doğal) Kaydırma", isOn: $reverseScrolling)
                        Text("Magic Keyboard izleme dörtgeni ve Bluetooth fare ayarları sanal Mac çalışırken anında uygulanır.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .listRowBackground(Desk.card)
                }
                Section("Tanılama Raporu ve Günlük") {
                    Button {
                        HengeLog.writeSanitizedReportFile()
                        showDiagnosticPreview = true
                    } label: {
                        Label("Temizlenmiş Tanılama Raporunu İncele ve Paylaş…", systemImage: "doc.text.magnifyingglass")
                    }
                    ShareLink(item: HengeLog.logFileURL) {
                        Label("Ham Günlüğü Paylaş (henge.log)", systemImage: "square.and.arrow.up")
                    }
                    Text("Temizlenmiş tanılama raporu; eşleştirme anahtarlarını, ECID kimliklerini, uygulama dizini UUID'lerini ve geliştirici takım kimliğini otomatik olarak gizler.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
            }
            .scrollContentBackground(.hidden)
            .background(Desk.page)
            .navigationTitle("Ayarlar")
            .sheet(isPresented: $showDiagnosticPreview) {
                DiagnosticReportPreviewSheet()
            }
        }
    }
}

private struct DiagnosticReportPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var reportText = HengeLog.sanitizedDiagnosticReport()
    @State private var reportURL = HengeLog.writeSanitizedReportFile()
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Paylaşmadan önce raporu aşağıdan inceleyebilirsiniz. Eşleştirme anahtarları, ECID ve kişisel dosya yolları temizlenmiştir.")
                    .font(.system(size: 13))
                    .foregroundStyle(Desk.dim)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                ScrollView {
                    Text(reportText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Desk.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .textSelection(.enabled)
                }
                .background(Desk.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 16)
                HStack(spacing: 12) {
                    Button {
                        UIPasteboard.general.string = reportText
                        copied = true
                    } label: {
                        Label(copied ? "Kopyalandı" : "Panoya Kopyala", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(DeskButtonStyle())
                    ShareLink(item: reportURL) {
                        Label("Dosya Olarak Paylaş", systemImage: "square.and.arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .background(Desk.card, in: Capsule())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .background(Desk.page)
            .navigationTitle("Tanılama Raporu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kapat") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
