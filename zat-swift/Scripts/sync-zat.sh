#!/bin/sh
# Vendor the zat Zig core and sync its C ABI artifacts into this package.
#
#   Scripts/sync-zat.sh
#
# The core is vendored as upstream zat (hash-pinned via the Zig package
# manager) + this repo's overlay (zat-swift/Vendor/zat-overlay), which carries
# our additions: the Explorer facade / CAR iterator / C ABI sources and the
# build wiring (C ABI library, header install, macOS 13.0 minimum-version
# pin).
#
# The fetch ref is an immutable upstream TAG, never a branch. `archive/main`
# moves whenever upstream does, and the hash pin then rejects the new tarball
# — which is exactly how CI broke on 2026-09-30 when zat `main` rolled from
# 0.4.5 to 0.5.2. Tag archives are content-addressed and permanent, so the
# pin stays true until *we* decide to move.
#
# Environment overrides:
#   ZAT_REF       upstream git ref to fetch (default v0.4.5)
#   ZAT_URL       upstream tarball URL (default
#                 https://tangled.org/zat.dev/zat/archive/$ZAT_REF)
#   ZAT_PIN       expected package name+version+hash as printed by `zig fetch`
#                 (default zat-0.4.5-5PuC7l6sDADAZQOBW-yKi6qnk67spfoYMRNoVpCUkvoC;
#                 regenerate with `zig fetch --save <url>`)
#   ZAT_SRC_DIR   use an existing local checkout instead of fetching (useful
#                 when restoring the old DEVKITS/zat-main tree from a backup)
#   ZAT_OVERLAY   overlay directory    (default <pkg_root>/Vendor/zat-overlay)
#
# The overlay NEVER clobbers existing source files (only fills gaps), so a
# restored full checkout keeps its own explorer/c_api/c_root implementations;
# build.zig and include/zat.h always come from the overlay (our canonical
# wiring and contract).
set -eu

pkg_root="$(cd "$(dirname "$0")/.." && pwd)"
overlay="${ZAT_OVERLAY:-$pkg_root/Vendor/zat-overlay}"
cache_dir="$pkg_root/.vendor"
src_dir="${ZAT_SRC_DIR:-$cache_dir/zat-src}"

if ! command -v zig >/dev/null 2>&1; then
    echo "error: 'zig' not found on PATH (the vendored core is built with Zig 0.16+)" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. obtain the source: hash-verified `zig fetch` of the pinned upstream
#    tarball (or a provided local checkout)
# ---------------------------------------------------------------------------
if [ -n "${ZAT_SRC_DIR:-}" ]; then
    if [ -f "$src_dir/build.zig.zon" ]; then
        echo "==> using local zat source at $src_dir"
    else
        echo "warning: ZAT_SRC_DIR ($src_dir) has no build.zig.zon; falling back to zig fetch" >&2
        unset ZAT_SRC_DIR
        src_dir="$cache_dir/zat-src"
    fi
fi
if [ -z "${ZAT_SRC_DIR:-}" ]; then
    ref="${ZAT_REF:-v0.4.5}"
    url="${ZAT_URL:-https://tangled.org/zat.dev/zat/archive/$ref}"
    pin="${ZAT_PIN:-zat-0.4.5-5PuC7l6sDADAZQOBW-yKi6qnk67spfoYMRNoVpCUkvoC}"
    mkdir -p "$cache_dir"

    # The ref and the pin are two names for one decision: a bump that updates
    # only one of them makes the next fetch "fail" with a hash mismatch that
    # reads like a supply-chain attack. Check they agree before the network.
    # Skipped when the caller supplies a whole custom ZAT_URL.
    if [ -z "${ZAT_URL:-}" ]; then
        case "$pin" in
            "zat-${ref#v}-"*) ;;
            *)
                echo "error: fetching ref '$ref' but the pin says '$pin'." >&2
                echo "       ZAT_REF and ZAT_PIN must name the same zat version - bump both," >&2
                echo "       or override ZAT_URL/ZAT_PIN together." >&2
                exit 1
                ;;
        esac
    fi

    # `zig fetch` needs a build.zig to run in; a throwaway init project works.
    # Tangled rate-limits (429s) are transient, so retry with backoff - but
    # ONLY on transport errors. A fetch that succeeds and prints some other
    # package name is a definitive answer (upstream moved, or the pin is
    # stale); re-asking five times just hides it for a minute.
    fetched=""
    attempt=1
    while [ "$attempt" -le 5 ]; do
        fetch_dir="$(mktemp -d)"
        echo "==> zig fetch $url (attempt $attempt/5)"
        fetched=$(cd "$fetch_dir" && zig init >/dev/null 2>&1 && zig fetch "$url" 2>&1 | tail -1)
        rm -rf "$fetch_dir"
        case "$fetched" in
            "$pin") break ;;
            zat-*)
                # A real package name, just not ours: definitive, don't retry.
                break
                ;;
        esac
        if [ "$attempt" -lt 5 ]; then
            sleep $((attempt * 5))
        fi
        attempt=$((attempt + 1))
    done
    case "$fetched" in
        "$pin") ;;
        zat-*)
            {
                echo "error: zig fetch of '$url' returned '$fetched', expected '$pin'."
                echo "       That URL is not the content we pinned. If it is a branch or a moved"
                echo "       ref, pin an immutable tag instead (ZAT_REF=vX.Y.Z). To bump"
                echo "       deliberately: 'zig fetch --save <url>', then update ZAT_REF, ZAT_PIN"
                echo "       and the docs together."
            } >&2
            exit 1
            ;;
        *)
            echo "error: zig fetch of '$url' failed after 5 attempts: $fetched" >&2
            exit 1
            ;;
    esac

    global_cache=$(zig env | sed -n 's/.*\.global_cache_dir = "\([^"]*\)".*/\1/p')
    tarball="$global_cache/p/$pin.tar.gz"
    if [ ! -f "$tarball" ]; then
        echo "error: fetched package not found at $tarball (zig cache layout changed?)" >&2
        exit 1
    fi

    rm -rf "$src_dir"
    mkdir -p "$src_dir"
    tar xzf "$tarball" -C "$src_dir" --strip-components=1
fi

# ---------------------------------------------------------------------------
# 2. layer the overlay on top
#    - src/ + include/ fill gaps only (never clobber a restored real file)
#    - build.zig always comes from the overlay (our wiring + min-version pin)
# ---------------------------------------------------------------------------
echo "==> overlaying $overlay onto $src_dir"
mkdir -p "$src_dir/src"
mkdir -p "$src_dir/include"
# Fill gaps only: -n never overwrites an existing file. macOS cp exits 1 when
# -n skips files, so re-running over an already-overlaid source (e.g. a cached
# checkout) would otherwise be misread as a failure — treat skips as success.
# The preflight below still fails loudly if a required overlay file is truly
# missing.
cp -Rn "$overlay/src/." "$src_dir/src/" || true
cp -Rn "$overlay/include/." "$src_dir/include/" || true
cp "$overlay/build.zig" "$src_dir/build.zig"

# ---------------------------------------------------------------------------
# 3. preflight: everything the vendored build needs must be present, with a
#    readable message instead of a cryptic Zig error when it isn't
# ---------------------------------------------------------------------------
require() { # path label
    if [ ! -f "$1" ]; then
        echo "error: $2 is missing — cannot build the vendored core." >&2
        echo "       See $overlay/README.md for what's required and how to restore it." >&2
        exit 1
    fi
}
require "$src_dir/build.zig.zon"    "upstream build.zig.zon"
require "$src_dir/src/root.zig"     "upstream src/root.zig"
require "$src_dir/include/zat.h"    "overlay include/zat.h"
require "$src_dir/src/c_root.zig"   "src/c_root.zig"
require "$src_dir/src/c_api.zig"    "src/c_api.zig"
require "$src_dir/src/explorer.zig" "src/explorer.zig"

# ---------------------------------------------------------------------------
# 4. build the C ABI static library + header
# ---------------------------------------------------------------------------
echo "==> zig build (in $src_dir)"
(cd "$src_dir" && zig build)

mkdir -p "$pkg_root/Vendor" "$pkg_root/Sources/Czat/include"
cp "$src_dir/zig-out/include/zat.h" "$pkg_root/Sources/Czat/include/zat.h"

# Apple's ld rejects Zig-written archives whose members aren't 8-byte
# aligned ("64-bit mach-o not 8-byte aligned"); repack with Apple's ar+libtool.
echo "==> repacking archive for Apple ld"
repack="$(mktemp -d)"
trap 'rm -rf "$repack"' EXIT
(cd "$repack" && ar x "$src_dir/zig-out/lib/libzat_c.a" \
    && chmod 644 *.o \
    && libtool -static -o "$src_dir/zig-out/lib/libzat_c_aligned.a" *.o)

# SPM binary targets accept xcframework/zip/artifactbundle, not raw .a files,
# so package the static library into an xcframework (headers stay in
# Sources/Czat; declarations are already compiled into the wrapper).
#
# The xcframework is only touched after every earlier step succeeded, so a
# failed sync never clobbers the last good Vendored build.
echo "==> packaging Vendor/ZatC.xcframework"
rm -rf "$pkg_root/Vendor/ZatC.xcframework"
xcodebuild -create-xcframework \
    -library "$src_dir/zig-out/lib/libzat_c_aligned.a" \
    -output "$pkg_root/Vendor/ZatC.xcframework" >/dev/null

echo "==> synced Sources/Czat/include/zat.h and Vendor/ZatC.xcframework"
