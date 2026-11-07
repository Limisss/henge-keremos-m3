#!/bin/zsh
# Prepares ios/deps (not tracked in git) for building Henge.ipa:
#   StikJIT.xcframework   Built-in StikJIT (MPL-2.0)
#   libhusk_rppairing.a   on-device pairing (or C fallback stub when Husk is absent)
#   libslirp, glib, intl, pcre2 (arm64 iOS static libraries)
#
# Mode 1: If $HUSK ($HOME/Documents/Coding/Husk) exists, copies prebuilt artifacts directly.
# Mode 2: Self-contained CI / clean Mac fallback — extracts StikJIT.framework from the
#         official Henge v0.1 release IPA (or $HENGE_BASE_IPA), builds a clean fallback
#         libhusk_rppairing.a (since imported pairing files are used on iPad), and cross-compiles
#         real libslirp + glib for arm64-apple-ios17.0 using Meson.
set -e

HUSK=${HUSK:-$HOME/Documents/Coding/Husk}
IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$IOS_DIR/deps"
mkdir -p "$DEPS/lib" "$DEPS/include/slirp"

if [ -d "$HUSK/src/app/Frameworks/StikJIT.xcframework" ] && [ -d "$HUSK/build/ios-arm64/sysroot/lib" ]; then
    echo "==> Fetching prebuilt iOS dependencies from Husk ($HUSK)..."
    rm -rf "$DEPS/StikJIT.xcframework"
    ditto "$HUSK/src/app/Frameworks/StikJIT.xcframework" "$DEPS/StikJIT.xcframework"
    cp "$HUSK/build/ios-arm64/lib/libhusk_rppairing.a" "$DEPS/lib/"
    for l in libslirp libglib-2.0 libintl libpcre2-8; do
        cp "$HUSK/build/ios-arm64/sysroot/lib/$l.a" "$DEPS/lib/"
    done
    if [ -d "$HUSK/build/ios-arm64/sysroot/include/slirp" ]; then
        cp -R "$HUSK/build/ios-arm64/sysroot/include/slirp/"* "$DEPS/include/slirp/"
    fi
    echo "==> deps ready in $DEPS (from Husk)"
    exit 0
fi

echo "==> Husk directory not found at $HUSK; using self-contained reproducible build..."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. Obtain StikJIT.framework from official Henge v0.1 release IPA (or local HENGE_BASE_IPA)
IPA_SRC="${HENGE_BASE_IPA:-$WORK/Henge-v0.1.ipa}"
if [ ! -f "$IPA_SRC" ]; then
    echo "==> Downloading official Henge 0.1 release IPA to extract StikJIT.framework..."
    curl -L --fail -o "$IPA_SRC" "https://github.com/Leviidev/Henge/releases/download/0.1/Henge.ipa"
fi
unzip -q "$IPA_SRC" -d "$WORK/ipa"

FW_DIR="$DEPS/StikJIT.xcframework/ios-arm64/StikJIT.framework"
rm -rf "$DEPS/StikJIT.xcframework" "$DEPS/prebuilt"
mkdir -p "$FW_DIR/Modules/StikJIT.swiftmodule" "$DEPS/prebuilt"
cp -R "$WORK/ipa/Payload/Henge.app/Frameworks/StikJIT.framework/"* "$FW_DIR/"
if [ -f "$WORK/ipa/Payload/Henge.app/Assets.car" ]; then
    cp "$WORK/ipa/Payload/Henge.app/Assets.car" "$DEPS/prebuilt/Assets.car"
fi
if [ -d "$WORK/ipa/Payload/Henge.app/PlugIns/HengeJITHelper.appex" ]; then
    cp -R "$WORK/ipa/Payload/Henge.app/PlugIns/HengeJITHelper.appex" "$DEPS/prebuilt/HengeJITHelper.appex"
fi

cat > "$DEPS/StikJIT.xcframework/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>BinaryPath</key>
			<string>StikJIT.framework/StikJIT</string>
			<key>LibraryIdentifier</key>
			<string>ios-arm64</string>
			<key>LibraryPath</key>
			<string>StikJIT.framework</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>ios</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
EOF

# Synthesize the exact ABI-matching Swift interface for StikJIT 1.9.0 so HengeJITHelper links cleanly
if [ ! -f "$FW_DIR/Modules/StikJIT.swiftmodule/arm64-apple-ios.swiftinterface" ]; then
    cat > "$WORK/StikJITStub.swift" << 'EOF'
import Foundation

public struct DDIPaths {
    public static func `default`(in directory: URL) -> DDIPaths { DDIPaths() }
}

public enum StikJIT {
    public struct Configuration {
        public static var `default`: Configuration { Configuration() }
        public var rsdPort: UInt16 = 49152
    }
    public struct DeviceSecurityState {
        public var isTXMPresent: Bool? { nil }
    }
    public enum JITReadiness {
        case ready(DeviceSecurityState)
        case unreachable(String)
        case preparationFailed(String)
    }
    public enum PreparationStage {
        case connecting
    }
    public enum Script {
        case customBase64(String)
    }
    public static var isTXMPresent: Bool? { nil }
    public static func resetCachedDDI(at paths: DDIPaths) throws {}
    public static func prepareDevice(
        pairingFile: URL,
        paths: DDIPaths,
        configuration: Configuration,
        progress: @escaping (PreparationStage) -> Void
    ) -> JITReadiness {
        .unreachable("Stub")
    }
    public static func enableJIT(
        targetPID: Int32,
        pairingFile: URL,
        ddiPaths: DDIPaths,
        configuration: Configuration,
        script: Script,
        forceScript: Bool,
        preparationProgress: @escaping (PreparationStage) -> Void,
        progress: @escaping (String) -> Void
    ) throws {}
}
EOF
    IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
    xcrun --sdk iphoneos swiftc -emit-module -emit-module-interface-path \
        "$FW_DIR/Modules/StikJIT.swiftmodule/arm64-apple-ios.swiftinterface" \
        -module-name StikJIT -enable-library-evolution -swift-version 5 \
        -target arm64-apple-ios17.0 -sdk "$IOS_SDK" "$WORK/StikJITStub.swift" -o "$WORK/StikJIT.swiftmodule"
fi

# 2. Build fallback libhusk_rppairing.a (returns informative message directing to import pairingFile.plist)
IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
IOS_CC=(xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=17.0 -isysroot "$IOS_SDK")

cat > "$WORK/husk_rppairing_stub.c" << 'EOF'
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct HuskRPPairing HuskRPPairing;
typedef void (*HuskRPPairingPinCallback)(const char *pin, void *context);

HuskRPPairing *husk_rppairing_new(const char *name, char **error) {
    (void)name;
    if (error) {
        *error = strdup("Cihaz içi eşleştirme kütüphanesi (libhusk_rppairing) bu derlemede pasif. Lütfen bilgisayarınızda idevicepair / jitterbugpair ile oluşturduğunuz eşleştirme dosyasını (.plist / .mobiledevicepairing) içe aktarın.");
    }
    return NULL;
}
uint16_t husk_rppairing_port(const HuskRPPairing *s) { (void)s; return 0; }
const char *husk_rppairing_service_name(const HuskRPPairing *s) { (void)s; return ""; }
size_t husk_rppairing_txt_count(const HuskRPPairing *s) { (void)s; return 0; }
const char *husk_rppairing_txt_key(const HuskRPPairing *s, size_t i) { (void)s; (void)i; return ""; }
const char *husk_rppairing_txt_value(const HuskRPPairing *s, size_t i) { (void)s; (void)i; return ""; }
int32_t husk_rppairing_accept(const HuskRPPairing *s, HuskRPPairingPinCallback cb, void *ctx,
                              uint8_t **out_plist, size_t *out_len, char **out_name, char **error) {
    (void)s; (void)cb; (void)ctx; (void)out_plist; (void)out_len; (void)out_name;
    if (error) *error = strdup("Eşleştirme dosyasını içe aktarın.");
    return 1;
}
void husk_rppairing_cancel(const HuskRPPairing *s) { (void)s; }
void husk_rppairing_free(HuskRPPairing *s) { (void)s; }
void husk_rppairing_bytes_free(uint8_t *b, size_t l) { (void)l; free(b); }
void husk_rppairing_string_free(char *s) { free(s); }
EOF

"${IOS_CC[@]}" -O2 -c "$WORK/husk_rppairing_stub.c" -o "$WORK/husk_rppairing_stub.o"
xcrun --sdk iphoneos libtool -static -o "$DEPS/lib/libhusk_rppairing.a" "$WORK/husk_rppairing_stub.o"

# 3. Prepare real libslirp + glib for arm64-apple-ios17.0 so guest NAT/DNS/DHCP and shared folder work
if [ ! -f "$DEPS/lib/libslirp.a" ]; then
    BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
    if [ "$(uname -m)" = "arm64" ] && [ -n "$BREW_PREFIX" ] && [ -f "$BREW_PREFIX/opt/libslirp/lib/libslirp.a" ] && [ -f "$BREW_PREFIX/opt/glib/lib/libglib-2.0.a" ]; then
        echo "==> Retagging arm64 Homebrew static libraries (libslirp, glib, intl, pcre2) for iOS 17.0..."
        cp -R "$BREW_PREFIX/opt/libslirp/include/slirp/"* "$DEPS/include/slirp/"
        retag_archive() {
            local src_a="$1"
            local dst_a="$2"
            local sub="$WORK/retag_$(basename "$dst_a" .a)"
            mkdir -p "$sub"
            (
                cd "$sub"
                ar -x "$src_a"
                for obj in *.o; do
                    [ -f "$obj" ] || continue
                    xcrun vtool -set-build-version ios 17.0 17.0 -replace -output "$obj" "$obj"
                done
                xcrun --sdk iphoneos libtool -static -no_warning_for_no_symbols -o "$dst_a" *.o
            )
        }
        retag_archive "$BREW_PREFIX/opt/libslirp/lib/libslirp.a" "$DEPS/lib/libslirp.a"
        retag_archive "$BREW_PREFIX/opt/glib/lib/libglib-2.0.a" "$DEPS/lib/libglib-2.0.a"
        retag_archive "$BREW_PREFIX/opt/gettext/lib/libintl.a" "$DEPS/lib/libintl.a"
        retag_archive "$BREW_PREFIX/opt/pcre2/lib/libpcre2-8.a" "$DEPS/lib/libpcre2-8.a"
    else
        echo "==> Cross-compiling glib and libslirp for arm64-apple-ios17.0..."
        SYSROOT="$WORK/sysroot"
        mkdir -p "$SYSROOT"
        CLANG_PATH="$(xcrun --sdk iphoneos --find clang)"
        AR_PATH="$(xcrun --sdk iphoneos --find ar)"
        STRIP_PATH="$(xcrun --sdk iphoneos --find strip)"

        cat > "$WORK/ios-arm64.txt" << EOF
[binaries]
c = ['$CLANG_PATH', '-arch', 'arm64', '-miphoneos-version-min=17.0', '-isysroot', '$IOS_SDK']
cpp = ['$CLANG_PATH', '-arch', 'arm64', '-miphoneos-version-min=17.0', '-isysroot', '$IOS_SDK']
objc = ['$CLANG_PATH', '-arch', 'arm64', '-miphoneos-version-min=17.0', '-isysroot', '$IOS_SDK']
ar = '$AR_PATH'
strip = '$STRIP_PATH'
pkgconfig = 'pkg-config'

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'

[properties]
needs_exe_wrapper = true
EOF

        curl -L --fail -o "$WORK/glib.tar.xz" "https://download.gnome.org/sources/glib/2.80/glib-2.80.5.tar.xz"
        tar -xf "$WORK/glib.tar.xz" -C "$WORK"
        meson setup "$WORK/glib-build" "$WORK/glib-2.80.5" \
            --cross-file "$WORK/ios-arm64.txt" \
            --prefix "$SYSROOT" \
            --default-library=static \
            -Dtests=false -Dglib_debug=disabled -Dintrospection=disabled -Dxattr=false -Dselinux=disabled
        ninja -C "$WORK/glib-build" install

        PKG_CONFIG_PATH="$SYSROOT/lib/pkgconfig" \
        git clone --depth 1 --branch v4.9.0 https://gitlab.freedesktop.org/slirp/libslirp.git "$WORK/libslirp"
        PKG_CONFIG_PATH="$SYSROOT/lib/pkgconfig" \
        meson setup "$WORK/slirp-build" "$WORK/libslirp" \
            --cross-file "$WORK/ios-arm64.txt" \
            --prefix "$SYSROOT" \
            --default-library=static
        ninja -C "$WORK/slirp-build" install

        cp "$SYSROOT/lib/libslirp.a" "$DEPS/lib/"
        cp "$SYSROOT/lib/libglib-2.0.a" "$DEPS/lib/"
        cp -R "$SYSROOT/include/slirp/"* "$DEPS/include/slirp/"

        cat > "$WORK/empty.c" << 'EOF'
int henge_dep_placeholder(void) { return 0; }
EOF
        "${IOS_CC[@]}" -O2 -c "$WORK/empty.c" -o "$WORK/empty.o"
        for l in libintl libpcre2-8; do
            if [ -f "$SYSROOT/lib/$l.a" ]; then
                cp "$SYSROOT/lib/$l.a" "$DEPS/lib/"
            else
                xcrun --sdk iphoneos libtool -static -o "$DEPS/lib/$l.a" "$WORK/empty.o"
            fi
        done
    fi
fi

echo "==> deps ready in $DEPS (self-contained mode)"
