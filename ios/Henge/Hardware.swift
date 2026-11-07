import SwiftUI
import UIKit
import GameController

/// What this device is, for what the app says and suggests.
enum Device {
    static let isPad = UIDevice.current.userInterfaceIdiom == .pad
    static let name = isPad ? "iPad" : "iPhone"

    /// A Mac's screen that fills this device on its side: 1920 wide, as tall as the shape asks. iPads and
    /// squarer phones (iPhone Duo, about 1.46:1) would get bars above and below at 16:9. Phones wider
    /// than 16:9 come out at 1920×1080, as before.
    static var fittingScreen: (width: Int, height: Int) {
        let size = UIScreen.main.bounds.size
        let shape = max(size.width, size.height) / max(min(size.width, size.height), 1)
        return (1920, min(max(Int((1920 / shape / 8).rounded()) * 8, 1080), 1440))
    }

    /// Physical RAM reported by the kernel, in MB.
    static let physicalMemoryMB = Int(ProcessInfo.processInfo.physicalMemory >> 20)
    /// Process memory limit at launch (before JIT allocation), in MB.
    static var processMemoryLimitMB: Int { Int(Entitlements.memoryLimitAtLaunch >> 20) }
    /// Remaining memory headroom before iOS jetsam right now, in MB.
    static var currentAvailableMemoryMB: Int { Int(henge_available_memory() >> 20) }
    /// Current physical footprint charged to Henge right now, in MB.
    static var currentFootprintMB: Int { Int(henge_phys_footprint() >> 20) }
    /// Largest single contiguous virtual address mapping possible right now, in MB.
    static var largestContiguousMappingMB: Int { Int(henge_largest_mapping_mb()) }

    /// Supported RAM options in GB: 3, 4, 5, 6, and 8 GB.
    static let ramOptionsGB: [Int] = [3, 4, 5, 6, 8]

    /// Safe default RAM suggestion (in GB) taking physical RAM and virtual address layout into account.
    /// Because both RX+RW JIT mappings (512 MB + 512 MB) and compacted HvMachine tables (~190 MB) now fit inside
    /// the low VA window (`0x100000000–0x180000000`) and Guest RAM is pre-allocated first with `LEDGER_NO_FOOTPRINT`
    /// in the 6144 MB high VA window (`0x7000000000–0x7180000000`), 4 GB is the optimal default on 8 GB devices,
    /// while 5 GB and 6 GB are also selectable without extended entitlements.
    static var suggestedRAMGB: Int {
        return physicalMemoryMB >= 7_000 ? 4 : 3
    }

    enum RAMRiskLevel {
        case recommended
        case caution
        case unsupported
    }

    /// Evaluates a guest RAM selection (in GB) against the four distinct memory dimensions:
    /// 1) Physical RAM, 2) Process jetsam limit (`LEDGER_NO_FOOTPRINT` exemption), 3) Contiguous VA space (`6144 MB` high window), 4) Host iPadOS headroom.
    static func ramAdvisory(forGB gb: Int) -> (level: RAMRiskLevel, message: String) {
        let limitMB = processMemoryLimitMB
        let physMB = physicalMemoryMB
        switch gb {
        case 3:
            return (
                .recommended,
                "Güvenli seçim (3 GB = 3072 MB). Fiziksel RAM: \(physMB) MB. iPadOS arka plan uygulamaları için en geniş fiziksel bellek payını bırakır."
            )
        case 4:
            return (
                .recommended,
                "Önerilen dengeli seçim (4 GB = 4096 MB). JIT (512 MB RX+RW) ve emülatör tabloları alt adres penceresine taşındığı ve Guest RAM 'LEDGER_NO_FOOTPRINT' ile üst 6144 MB penceresinden ayrıldığı için Sideloadly imzasında (\(limitMB) MB sınır) doğrudan çalışır."
            )
        case 5:
            return (
                .recommended,
                "Yüksek kapasite (5 GB = 5120 MB). Üst sanal adres penceresine (6144 MB) tam sığar ve 'LEDGER_NO_FOOTPRINT' sayesinde uygulama sınırına (\(limitMB) MB) takılmaz. 8 GB cihazda (\(physMB) MB) iPadOS ve JIT için ~2.5 GB fiziksel pay kalır; arka plandaki ağır iPad uygulamalarını kapatmanız önerilir."
            )
        case 6:
            return (
                .caution,
                "Maksimum sanal pencere sınırı (6 GB = 6144 MB). Üst adres penceresinin tamamını kullanır (gerekirse 128 MB adımlarla otomatik kırpılır). 8 GB iPad'de (\(physMB) MB) tüm sayfalar dolduğunda fiziksel RAM baskısı oluşabileceği için macOS içinde ağır yük altında dikkatli kullanın."
            )
        default:
            return (
                .unsupported,
                "Desteklenmiyor / Deneysel (\(gb) GB = \(gb * 1024) MB): 'extended-virtual-addressing' izni olmadan 6144 MB üst sanal adres penceresini aşar ve 8 GB fiziksel RAM (\(physMB) MB) sınırını geçer."
            )
        }
    }

    /// The virtual CPU offers Armv8.5 instructions (core/sysreg.c), and macOS uses them. They run as
    /// they are, so the chip needs them too: A14, M1 and later, which is iPhone13,x and iPad13,x up.
    static let chipTooOld: Bool = {
        let model = HengeLog.deviceModel
        guard model.hasPrefix("iPhone") || model.hasPrefix("iPad"),
              let major = Int(model.drop { !$0.isNumber }.prefix { $0.isNumber }) else { return false }
        return major < 13
    }()

    static let chipTooOldText = "macOS bu \(name) modelinde çalışmaz. Henge için A14, M1 veya daha yeni bir işlemci gerekir."
}

/// A keyboard attached to the device. iOS reports each key going down and coming up by its HID usage,
/// which is what the Mac's USB keyboard sends, so every key and modifier goes straight across.
enum HardwareKeys {
    private static var held: Set<UInt8> = []
    private static var lastKey: CFTimeInterval = 0

    /// With the on-screen keyboard's view holding the keyboard, iOS may also offer a hardware key as
    /// text, and again as it repeats. The Mac has the key already, and repeats it itself.
    static var keyJustPressed: Bool {
        held.contains { $0 < 0xe0 } || CACurrentMediaTime() - lastKey < 0.1
    }

    /// Sends the presses that are keys, and returns the rest.
    static func send(_ presses: Set<UIPress>, down: Bool) -> Set<UIPress> {
        var rest = Set<UIPress>()
        for press in presses {
            guard let raw = press.key?.keyCode.rawValue, raw >= 0x04, raw <= 0xe7 else {
                rest.insert(press)
                continue
            }
            let usage = UInt8(raw)
            henge_vm_key_hid(usage, down ? 1 : 0)
            if usage < 0xe0 { lastKey = CACurrentMediaTime() }
            if down {
                held.insert(usage)
            } else {
                held.remove(usage)
                if usage < 0xe0 { StickyKeys.shared.releaseAll() } // one key after a tap on ⌃, ⌥ or ⌘
            }
        }
        return rest
    }

    /// iPadOS can keep a key's release when it takes over, as it does for ⌘-Tab: the Mac must not
    /// go on thinking the key is down.
    static func releaseAll() {
        for usage in held { henge_vm_key_hid(usage, 0) }
        held.removeAll()
    }
}

/// Asks iPadOS to hand the pointer over, so a trackpad or mouse drives only the Mac's pointer. It does
/// that only for an app filling the screen. SwiftUI has no way to ask, so the answer is added to the
/// class of the window's root view controller, which is who iPadOS asks.
enum PointerLock {
    private static var wanted = false
    private static var patched: Set<ObjectIdentifier> = []

    static func set(_ on: Bool) {
        wanted = on
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for window in windows {
            guard let root = window.rootViewController else { continue }
            let kind: AnyClass = type(of: root)
            if patched.insert(ObjectIdentifier(kind)).inserted {
                let answer: @convention(block) (UIViewController) -> Bool = { _ in wanted }
                class_replaceMethod(kind, #selector(getter: UIViewController.prefersPointerLocked), imp_implementationWithBlock(answer), "B@:")
            }
            root.setNeedsUpdateOfPrefersPointerLocked()
        }
    }
}

/// A Magic Keyboard's trackpad or a mouse, while a Mac is running. GameController gives the raw motion,
/// which macOS then accelerates as it would for its own mouse.
final class HardwareMouse {
    static let shared = HardwareMouse()
    static let speedKey = "henge.mouse.speed"
    static let reverseKey = "henge.mouse.reverse"

    private var observers: [NSObjectProtocol] = []
    private var mice: [GCMouse] = []
    private var buttonsDown: Set<Int32> = []
    private var restX: Float = 0, restY: Float = 0
    private var speed: Float = 1
    private var reverse = false
    private var scrollsLogged = 0 // the first few, to see what a device's raw values look like

    func reloadSettings() {
        let defaults = UserDefaults.standard
        speed = defaults.object(forKey: Self.speedKey) == nil ? 1 : Float(defaults.double(forKey: Self.speedKey))
        reverse = defaults.bool(forKey: Self.reverseKey)
    }

    func start() {
        reloadSettings()
        GCMouse.mice().forEach(attach)
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reloadSettings()
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.releaseButtons()
            HardwareKeys.releaseAll()
        })
        observers.append(NotificationCenter.default.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] note in
            if let mouse = note.object as? GCMouse { self?.attach(mouse) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .GCMouseDidDisconnect, object: nil, queue: .main) { [weak self] note in
            guard let self, let mouse = note.object as? GCMouse else { return }
            self.releaseButtons()
            self.mice.removeAll { $0 === mouse }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIPointerLockState.didChangeNotification, object: nil, queue: .main) { note in
            let locked = (note.object as? UIScene)?.pointerLockState?.isLocked ?? false
            HengeLog.log("input", "pointer lock: \(locked ? "on" : "off")")
        })
        PointerLock.set(true)
    }

    func stop() {
        PointerLock.set(false)
        releaseButtons()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        for mouse in mice {
            guard let input = mouse.mouseInput else { continue }
            input.mouseMovedHandler = nil
            input.leftButton.pressedChangedHandler = nil
            input.rightButton?.pressedChangedHandler = nil
            input.middleButton?.pressedChangedHandler = nil
            input.scroll.valueChangedHandler = nil
        }
        mice.removeAll()
    }

    func releaseButtons() {
        for button in buttonsDown { henge_vm_mouse_button(button, 0) }
        buttonsDown.removeAll()
    }

    private func attach(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput, !mice.contains(where: { $0 === mouse }) else { return }
        mice.append(mouse)
        HengeLog.log("input", "mouse: \(mouse.vendorName ?? "?"), right button \(input.rightButton != nil), middle \(input.middleButton != nil)")
        input.mouseMovedHandler = { [weak self] _, dx, dy in self?.moved(dx, dy) }
        input.leftButton.pressedChangedHandler = { [weak self] _, _, pressed in self?.button(0, pressed) }
        input.rightButton?.pressedChangedHandler = { [weak self] _, _, pressed in self?.button(1, pressed) }
        input.middleButton?.pressedChangedHandler = { [weak self] _, _, pressed in self?.button(2, pressed) }
        input.scroll.valueChangedHandler = { [weak self] _, first, second in self?.scrolled(first, second) }
    }

    /// GameController's Y runs upward. What doesn't make a whole step yet waits for the next move.
    private func moved(_ dx: Float, _ dy: Float) {
        restX += dx * speed
        restY -= dy * speed
        let x = restX.rounded(), y = restY.rounded()
        guard x != 0 || y != 0 else { return }
        restX -= x
        restY -= y
        henge_vm_mouse_move(Int32(x), Int32(y))
    }

    private func button(_ button: Int32, _ pressed: Bool) {
        henge_vm_mouse_button(button, pressed ? 1 : 0)
        if pressed {
            buttonsDown.insert(button)
        } else {
            buttonsDown.remove(button)
            StickyKeys.shared.releaseAll()
        }
    }

    /// GameController puts the wheel's vertical motion on the pad's first axis, negative going up, and
    /// its horizontal motion on the second. macOS accelerates the wheel by about the square of what it
    /// is sent (see Trackpad's scroll), so this sends the root: one notch, a value of 1, is about 40 pixels.
    private func scrolled(_ first: Float, _ second: Float) {
        if scrollsLogged < 24 {
            scrollsLogged += 1
            HengeLog.log("input", "scroll raw: \(first), \(second)")
        }
        let way: Int32 = reverse ? -1 : 1
        henge_vm_mouse_scroll(way * Self.wheelUnits(second), way * Self.wheelUnits(-first))
    }

    private static func wheelUnits(_ value: Float) -> Int32 {
        let units = Int32((22 * abs(value).squareRoot()).rounded())
        return value < 0 ? -units : units
    }
}
