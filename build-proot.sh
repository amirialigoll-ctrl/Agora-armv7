#!/usr/bin/env bash
set -euo pipefail
# build-proot.sh - Build proot native binaries for the Agora Android app.
# Invoked from build.ps1 / build-googleplay.ps1 / build_fdroid.ps1.
# Must run inside WSL Arch (or any Linux with NDK 28.2.13676358).
#
# Builds for every ABI in $ABIS (both arm64-v8a and armeabi-v7a by default).
# Pass a single ABI as $2 to build only that one, e.g.:
#   ./build-proot.sh --force armeabi-v7a

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORCE="${1:-}"
ONLY_ABI="${2:-}"

if [ -n "$ONLY_ABI" ]; then
    ABIS=("$ONLY_ABI")
else
    ABIS=("arm64-v8a" "armeabi-v7a")
fi

# ── NDK auto-detection ────────────────────────────────────────
if [ -n "${ANDROID_NDK_HOME:-}" ] && [ -d "$ANDROID_NDK_HOME" ]; then
    NDK="$ANDROID_NDK_HOME"
elif [ -d "/home/newoether/android-sdk/ndk/28.2.13676358" ]; then
    NDK="/home/newoether/android-sdk/ndk/28.2.13676358"
elif [ -n "${ANDROID_HOME:-}" ] && [ -d "$ANDROID_HOME/ndk" ]; then
    NDK=$(ls -d "$ANDROID_HOME/ndk/"*/ 2>/dev/null | sort -V | tail -1)
    NDK="${NDK%/}"
else
    echo "ERROR: NDK not found. Set ANDROID_NDK_HOME or install NDK 28.2.13676358."
    exit 1
fi

TC_PREFIX="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
export PATH="${TC_PREFIX}:$PATH"

echo "=== build-proot.sh: NDK=$NDK ==="
echo "=== build-proot.sh: ABIs=${ABIS[*]} ==="

# ── Per-ABI cross-compiler triple ──────────────────────────────
# arm64-v8a keeps its original API level (26); armeabi-v7a targets the
# project's minSdk (24) via the armv7a-linux-androideabi<API> triple.
cross_prefix_for_abi() {
    case "$1" in
        arm64-v8a)     echo "aarch64-linux-android26" ;;
        armeabi-v7a)   echo "armv7a-linux-androideabi24" ;;
        *) echo "ERROR: unknown ABI '$1'" >&2; exit 1 ;;
    esac
}

if ! command -v readelf &>/dev/null; then
    if command -v llvm-readelf &>/dev/null; then
        READELF_DIR="$SCRIPT_DIR/.build-proot/.tmp-bin"
        mkdir -p "$READELF_DIR"
        ln -sf "$(command -v llvm-readelf)" "$READELF_DIR/readelf"
        export PATH="$READELF_DIR:$PATH"
    fi
fi

TALLOC_SRC="$SCRIPT_DIR/thirdparty/talloc"
PROOT_SRC="$SCRIPT_DIR/thirdparty/proot/src"
BLD="$SCRIPT_DIR/.build-proot"

build_one_abi() {
    local ABI="$1"
    local CROSS_PREFIX
    CROSS_PREFIX="$(cross_prefix_for_abi "$ABI")"
    local CC="${TC_PREFIX}/${CROSS_PREFIX}-clang"
    local STRIP="${TC_PREFIX}/llvm-strip"

    if [ ! -x "$CC" ]; then
        echo "ERROR: cross compiler not found for $ABI: $CC"
        echo "       Check that NDK $NDK provides the $CROSS_PREFIX triple."
        exit 1
    fi

    local SYSROOT="$BLD/sysroot/$ABI"
    local SYSROOT_LIB="$SYSROOT/lib"
    local SYSROOT_INC="$SYSROOT/include"
    local BLD_DIR="$BLD/build-proot-$ABI"
    local JNILIBS="$SCRIPT_DIR/app/src/main/jniLibs/$ABI"
    local FDROID_JNILIBS="$SCRIPT_DIR/app/src/fdroid/jniLibs/$ABI"

    local HASH_FILE="$BLD_DIR/.source_hashes"
    local need_rebuild=false

    calc_hashes() {
        local hash=""
        hash+=$(md5sum "$TALLOC_SRC/talloc.c" 2>/dev/null | cut -d' ' -f1)
        hash+="-"
        hash+=$(md5sum "$TALLOC_SRC/talloc.h" 2>/dev/null | cut -d' ' -f1)
        hash+="-"
        hash+=$(md5sum "$TALLOC_SRC/config.h" 2>/dev/null | cut -d' ' -f1)
        hash+="-"
        hash+=$(md5sum "$TALLOC_SRC/replace.h" 2>/dev/null | cut -d' ' -f1)
        hash+="-"
        hash+=$(md5sum "$PROOT_SRC/GNUmakefile" 2>/dev/null | cut -d' ' -f1)
        hash+="-"
        hash+=$(echo "$NDK-$ABI" | md5sum | cut -d' ' -f1)
        echo "$hash"
    }

    if [ "$FORCE" = "--force" ]; then
        need_rebuild=true
        echo "  [$ABI] (forced rebuild)"
    elif [ ! -f "$HASH_FILE" ]; then
        need_rebuild=true
        echo "  [$ABI] (first build, no hash file)"
    elif [ ! -f "$JNILIBS/libproot_exec.so" ] || \
         [ ! -f "$JNILIBS/libproot_loader.so" ] || \
         [ ! -f "$JNILIBS/libtalloc.so" ]; then
        need_rebuild=true
        echo "  [$ABI] (missing jniLibs output)"
    else
        local new_hash old_hash
        new_hash=$(calc_hashes)
        old_hash=$(cat "$HASH_FILE")
        if [ "$new_hash" != "$old_hash" ]; then
            need_rebuild=true
            echo "  [$ABI] (source changed)"
        else
            echo "  [$ABI] (up to date, skipping)"
        fi
    fi

    if [ "$need_rebuild" = false ]; then
        return 0
    fi

    echo "=== build-proot.sh: Building proot binaries for $ABI ==="
    mkdir -p "$SYSROOT_LIB" "$SYSROOT_INC" \
             "$JNILIBS" "$FDROID_JNILIBS" "$BLD_DIR/loader"

    echo "  [1/4] Building libtalloc.so ($ABI)..."
    (
        cd "$TALLOC_SRC"
        "$CC" -fPIC -O2 -shared \
            -Wl,-soname,libtalloc.so \
            -o "$SYSROOT_LIB/libtalloc.so" \
            talloc.c \
            -DHAVE_CONFIG_H \
            -I.
    )
    cp "$TALLOC_SRC/talloc.h" "$SYSROOT_INC/"
    echo "  [1/4] Done: $(stat -c%s "$SYSROOT_LIB/libtalloc.so") bytes"

    echo "  [2/4] Building proot ($ABI, GNUmakefile)..."
    local PROOT_BLD="$BLD_DIR/src"
    rm -rf "$PROOT_BLD"
    mkdir -p "$PROOT_BLD"
    cp -r "$PROOT_SRC/." "$PROOT_BLD/"
    find "$PROOT_BLD" -name '*.o' -delete
    find "$PROOT_BLD" -name '*.d' -delete
    find "$PROOT_BLD" -name '*.res' -delete
    rm -f "$PROOT_BLD/build.h" "$PROOT_BLD/proot" "$PROOT_BLD/loader/loader" \
          "$PROOT_BLD/.check_process_vm" "$PROOT_BLD/.check_seccomp_filter"
    printf 'int main(void){return 0;}\n' > "$PROOT_BLD/.check_process_vm.c"
    printf 'int main(void){return 0;}\n' > "$PROOT_BLD/.check_seccomp_filter.c"
    local ASHMEM_C="$PROOT_BLD/extension/ashmem_memfd/ashmem_memfd.c"
    if [ -f "$ASHMEM_C" ] && ! grep -q '#include <string.h>' "$ASHMEM_C"; then
        sed -i '1i #include <string.h>' "$ASHMEM_C"
    fi
    cat > "$PROOT_BLD/loader/loader-info.awk" <<'ENDAWK'
function hextonum(hex,   i, n, c, idx) {
    hex = tolower(hex)
    n = 0
    for (i = 1; i <= length(hex); i++) {
        c = substr(hex, i, 1)
        idx = index("0123456789abcdef", c)
        if (idx == 0) break
        n = n * 16 + (idx - 1)
    }
    return n
}
$NF == "pokedata_workaround" { pokedata_workaround = hextonum($2) }
$NF == "_start" { start = hextonum($2) }
END {
    print "#include <unistd.h>"
    print "const ssize_t offset_to_pokedata_workaround=" (pokedata_workaround - start) ";"
}
ENDAWK
    (
        cd "$PROOT_BLD"
        export SOURCE_DATE_EPOCH=0
        export CPPFLAGS="-I${SYSROOT_INC} -DSYS_SECCOMP=1"
        export LDFLAGS="-L${SYSROOT_LIB}"
        export CC="${TC_PREFIX}/${CROSS_PREFIX}-clang"
        make CROSS_COMPILE="${CROSS_PREFIX}-" \
            PROOT_UNBUNDLE_LOADER="loader-out" \
            GIT=/bin/true \
            proot
    )
    echo "  [2/4] Done: $(stat -c%s "$PROOT_BLD/proot") bytes"

    echo "  [3/4] Stripping and deploying ($ABI)..."
    "$STRIP" --strip-all \
        "$BLD_DIR/src/proot" \
        -o "$JNILIBS/libproot_exec.so"

    local LOADER_SRC="$BLD_DIR/src/loader/loader"
    if [ ! -f "$LOADER_SRC" ]; then
        echo "ERROR: loader binary not found at $LOADER_SRC"
        exit 1
    fi
    cp "$LOADER_SRC" "$JNILIBS/libproot_loader.so"

    "$STRIP" --strip-all \
        "$SYSROOT_LIB/libtalloc.so" \
        -o "$JNILIBS/libtalloc.so"

    echo "  [3/4] Binaries deployed ($ABI):"
    echo "    $(stat -c%s "$JNILIBS/libproot_exec.so") bytes  libproot_exec.so"
    echo "    $(stat -c%s "$JNILIBS/libproot_loader.so") bytes  libproot_loader.so"
    echo "    $(stat -c%s "$JNILIBS/libtalloc.so") bytes  libtalloc.so"

    echo "  [4/4] Syncing to fdroid jniLibs ($ABI)..."
    cp "$JNILIBS/libproot_exec.so" "$FDROID_JNILIBS/libproot_exec.so"
    cp "$JNILIBS/libproot_loader.so" "$FDROID_JNILIBS/libproot_loader.so"
    cp "$JNILIBS/libtalloc.so" "$FDROID_JNILIBS/libtalloc.so"

    calc_hashes > "$HASH_FILE"
    echo "=== build-proot.sh: $ABI complete ==="
}

for abi in "${ABIS[@]}"; do
    build_one_abi "$abi"
done

echo "=== build-proot.sh: All ABIs (${ABIS[*]}) up to date ==="
