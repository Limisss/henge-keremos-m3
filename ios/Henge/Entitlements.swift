import Foundation

/// What this install was actually signed with: the entitlements in the project are only a
/// request, and a signing certificate without them leaves them out.
enum Entitlements {
    static let getTaskAllow = has("get-task-allow")
    static let increasedMemory = has("com.apple.developer.kernel.increased-memory-limit")
    static let extendedAddressing = has("com.apple.developer.kernel.extended-virtual-addressing")
    /// What iOS allowed when the app opened, before the JIT region took its share.
    static let memoryLimitAtLaunch = henge_available_memory()

    static var signingDiagnosticSummary: String {
        let limitMB = memoryLimitAtLaunch >> 20
        let gta = getTaskAllow ? "Açık" : "Kapalı"
        let iml = increasedMemory ? "Açık" : "Kapalı"
        let eva = extendedAddressing ? "Açık" : "Kapalı"
        return "get-task-allow: \(gta) · Yüksek Bellek İzni: \(iml) · Geniş Adres Alanı: \(eva) · Başlangıç Sınırı: \(limitMB) MB"
    }

    private typealias CreateFromSelf = @convention(c) (CFAllocator?) -> CFTypeRef?
    private typealias CopyValue = @convention(c) (CFTypeRef, CFString, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> CFTypeRef?

    static func has(_ name: String) -> Bool {
        let handle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let create = dlsym(handle, "SecTaskCreateFromSelf"), let copy = dlsym(handle, "SecTaskCopyValueForEntitlement") else { return false }
        guard let task = unsafeBitCast(create, to: CreateFromSelf.self)(nil) else { return false }
        return (unsafeBitCast(copy, to: CopyValue.self)(task, name as CFString, nil) as? NSNumber)?.boolValue ?? false
    }
}
