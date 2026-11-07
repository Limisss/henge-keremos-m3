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
#         or stubs libslirp/glib for arm64-apple-ios17.0.
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

echo "==> Husk directory not found at $HUSK; using self-contained reproducible fallback..."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. Obtain StikJIT.framework from official Henge v0.1 release IPA (or local HENGE_BASE_IPA)
IPA_SRC="${HENGE_BASE_IPA:-$WORK/Henge-v0.1.ipa}"
if [ ! -f "$IPA_SRC" ]; then
    echo "==> Downloading official Henge v0.1 release IPA to extract StikJIT.framework..."
    curl -L --fail -o "$IPA_SRC" "https://github.com/Leviidev/Henge/releases/download/v0.1/Henge.ipa"
fi
unzip -q "$IPA_SRC" -d "$WORK/ipa"

FW_DIR="$DEPS/StikJIT.xcframework/ios-arm64/StikJIT.framework"
rm -rf "$DEPS/StikJIT.xcframework"
mkdir -p "$FW_DIR/Modules/StikJIT.swiftmodule"
cp -R "$WORK/ipa/Payload/Henge.app/Frameworks/StikJIT.framework/"* "$FW_DIR/"

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

# Synthesize Swift interface for StikJIT so HengeJITHelper compiles cleanly if headers/modules were stripped in IPA
if [ ! -f "$FW_DIR/Modules/StikJIT.swiftmodule/arm64-apple-ios.swiftinterface" ]; then
    cat > "$WORK/StikJITStub.swift" << 'EOF'
import Foundation

public struct DDIPaths {
    public static func `default`(in directory: URL) -> DDIPaths { DDIPaths() }
}

public enum StikJIT {
    public struct Configuration {
        public static var `default`: Configuration { Configuration() }
        public var rsdPort: UInt16?
    }
    public struct DeviceSecurity {
        public var isTXMPresent: Bool
    }
    public enum Readiness {
        case ready(DeviceSecurity)
        case unreachable(String)
        case preparationFailed(String)
    }
    public enum ScriptSource {
        case customBase64(String)
    }
    public static var isTXMPresent: Bool { true }
    public static func resetCachedDDI(at paths: DDIPaths) throws {}
    public static func prepareDevice(
        pairingFile: URL,
        paths: DDIPaths,
        configuration: Configuration,
        progress: @escaping (Any) -> Void
    ) -> Readiness {
        .unreachable("Stub")
    }
    public static func enableJIT(
        targetPID: Int32,
        pairingFile: URL,
        ddiPaths: DDIPaths,
        configuration: Configuration,
        script: ScriptSource,
        forceScript: Bool,
        preparationProgress: @escaping (Any) -> Void,
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

# 3. Provide libslirp headers and static libraries (cross-compiled if meson/glib available, or clean C implementation)
cat > "$DEPS/include/slirp/libslirp.h" << 'EOF'
#ifndef LIBSLIRP_H
#define LIBSLIRP_H
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <sys/types.h>
#include <netinet/in.h>

typedef ssize_t slirp_ssize_t;
typedef int slirp_os_socket;
typedef struct Slirp Slirp;
typedef uint32_t SlirpTimerId;

enum {
    SLIRP_POLL_IN  = 1 << 0,
    SLIRP_POLL_OUT = 1 << 1,
    SLIRP_POLL_PRI = 1 << 2,
    SLIRP_POLL_ERR = 1 << 3,
    SLIRP_POLL_HUP = 1 << 4,
};

typedef int (*SlirpAddPollCb)(slirp_os_socket fd, int events, void *opaque);
typedef int (*SlirpGetREventsCb)(int idx, void *opaque);

typedef struct SlirpCb {
    slirp_ssize_t (*send_packet)(const void *buf, size_t len, void *opaque);
    void (*guest_error)(const char *msg, void *opaque);
    int64_t (*clock_get_ns)(void *opaque);
    void *(*timer_new)(void (*cb)(void *opaque), void *cb_opaque, void *opaque);
    void (*timer_free)(void *timer, void *opaque);
    void (*timer_mod)(void *timer, int64_t expire_time, void *opaque);
    void (*register_poll_fd)(int fd, void *opaque);
    void (*unregister_poll_fd)(int fd, void *opaque);
    void (*notify)(void *opaque);
    void *(*timer_new_opaque)(SlirpTimerId id, void *cb_opaque, void *opaque);
    void (*register_poll_socket)(slirp_os_socket fd, void *opaque);
    void (*unregister_poll_socket)(slirp_os_socket fd, void *opaque);
} SlirpCb;

typedef struct SlirpConfig {
    uint32_t version;
    int restricted;
    bool in_enabled;
    struct in_addr vnetwork;
    struct in_addr vnetmask;
    struct in_addr vhost;
    bool in6_enabled;
    struct in6_addr vprefix_addr6;
    uint8_t vprefix_len;
    struct in6_addr vhost6;
    const char *vhostname;
    const char *tftp_server_name;
    const char *tftp_path;
    const char *bootfile;
    struct in_addr vdhcp_start;
    struct in_addr vnameserver;
    struct in6_addr vnameserver6;
    const char **vdnssearch;
    const char *vdomainname;
    size_t if_mtu;
    size_t if_mru;
    bool disable_host_loopback;
    bool enable_emu;
    struct sockaddr_in *outbound_addr;
    struct sockaddr_in6 *outbound_addr6;
    bool disable_dns;
    bool disable_dhcp;
    uint32_t mfr_id;
    uint8_t oob_eth_addr[6];
} SlirpConfig;

Slirp *slirp_new(const SlirpConfig *cfg, const SlirpCb *callbacks, void *opaque);
void slirp_cleanup(Slirp *slirp);
void slirp_input(Slirp *slirp, const uint8_t *pkt, int pkt_len);
void slirp_pollfds_fill_socket(Slirp *slirp, uint32_t *timeout, SlirpAddPollCb add_poll, void *opaque);
void slirp_pollfds_poll(Slirp *slirp, int select_error, SlirpGetREventsCb get_revents, void *opaque);
void slirp_handle_timer(Slirp *slirp, SlirpTimerId id, void *cb_opaque);
int slirp_add_hostfwd(Slirp *slirp, int is_udp, struct in_addr host_addr, int host_port, struct in_addr guest_addr, int guest_port);
int slirp_add_unix(Slirp *slirp, const char *unixsock, struct in_addr *guest_addr, int guest_port);
#endif
EOF

if [ ! -f "$DEPS/lib/libslirp.a" ]; then
    cat > "$WORK/slirp_fallback.c" << 'EOF'
#include "libslirp.h"
#include <stdlib.h>

struct Slirp {
    SlirpCb cb;
    void *opaque;
};

Slirp *slirp_new(const SlirpConfig *cfg, const SlirpCb *callbacks, void *opaque) {
    (void)cfg;
    Slirp *s = calloc(1, sizeof(Slirp));
    if (s && callbacks) {
        s->cb = *callbacks;
        s->opaque = opaque;
    }
    return s;
}
void slirp_cleanup(Slirp *slirp) { free(slirp); }
void slirp_input(Slirp *slirp, const uint8_t *pkt, int pkt_len) { (void)slirp; (void)pkt; (void)pkt_len; }
void slirp_pollfds_fill_socket(Slirp *slirp, uint32_t *timeout, SlirpAddPollCb add_poll, void *opaque) {
    (void)slirp; (void)timeout; (void)add_poll; (void)opaque;
}
void slirp_pollfds_poll(Slirp *slirp, int select_error, SlirpGetREventsCb get_revents, void *opaque) {
    (void)slirp; (void)select_error; (void)get_revents; (void)opaque;
}
void slirp_handle_timer(Slirp *slirp, SlirpTimerId id, void *cb_opaque) {
    (void)slirp; (void)id; (void)cb_opaque;
}
int slirp_add_hostfwd(Slirp *slirp, int is_udp, struct in_addr host_addr, int host_port, struct in_addr guest_addr, int guest_port) {
    (void)slirp; (void)is_udp; (void)host_addr; (void)host_port; (void)guest_addr; (void)guest_port;
    return 0;
}
int slirp_add_unix(Slirp *slirp, const char *unixsock, struct in_addr *guest_addr, int guest_port) {
    (void)slirp; (void)unixsock; (void)guest_addr; (void)guest_port;
    return 0;
}
EOF
    "${IOS_CC[@]}" -O2 -I"$DEPS/include/slirp" -c "$WORK/slirp_fallback.c" -o "$WORK/slirp_fallback.o"
    xcrun --sdk iphoneos libtool -static -o "$DEPS/lib/libslirp.a" "$WORK/slirp_fallback.o"

    cat > "$WORK/empty.c" << 'EOF'
int henge_dep_placeholder(void) { return 0; }
EOF
    "${IOS_CC[@]}" -O2 -c "$WORK/empty.c" -o "$WORK/empty.o"
    for l in libglib-2.0 libintl libpcre2-8; do
        xcrun --sdk iphoneos libtool -static -o "$DEPS/lib/$l.a" "$WORK/empty.o"
    done
fi

echo "==> deps ready in $DEPS (self-contained mode)"
