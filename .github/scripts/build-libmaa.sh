#!/bin/sh
# Build libmaa as a static library without its native mk-configure/bmake
# toolchain (unavailable on MSYS2 and not preinstalled on CI runners), so the
# dictd binaries carry no libmaa runtime dependency.
#
# usage: build-libmaa.sh <prefix>
# env:   LIBMAA_VERSION, LIBMAA_SHA256, CC, AR, RANLIB

set -eu

prefix=${1:?usage: $0 <prefix>}
version=${LIBMAA_VERSION:-1.5.1}
sha256=${LIBMAA_SHA256:-3a30e25f038e99c4715125545516490d991fe3a505825cc832b1a956e31bf669}
url="https://downloads.sourceforge.net/project/dict/libmaa/libmaa-${version}/libmaa-${version}.tar.gz"
cc=${CC:-cc}
ar=${AR:-ar}
ranlib=${RANLIB:-ranlib}

work=$(mktemp -d 2>/dev/null || mktemp -d -t libmaa)
trap 'rm -rf "$work"' EXIT INT TERM
cd "$work"

curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors -o libmaa.tar.gz "$url"

if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum libmaa.tar.gz | cut -d' ' -f1)
else
    actual=$(shasum -a 256 libmaa.tar.gz | cut -d' ' -f1)
fi
if [ "$actual" != "$sha256" ]; then
    echo "libmaa checksum mismatch: expected $sha256, got $actual" >&2
    exit 1
fi

tar -xzf libmaa.tar.gz
cd "libmaa-${version}/maa"

# Replicate the mk-configure probes (MKC_CHECK_SIZEOF / MKC_CHECK_HEADERS).
have_header() {
    printf '#include <%s>\nint main(void){return 0;}\n' "$1" > probe.c
    "$cc" -c probe.c -o probe.o >/dev/null 2>&1 && echo 1 || echo 0
}
printf '#include <stdio.h>\nint main(void){printf("%%u",(unsigned)sizeof(long));return 0;}\n' > probe.c
"$cc" probe.c -o probe
sizeof_long=$(./probe)
rm -f probe probe.c probe.o probe.exe

# Parse version and source list from the upstream build files so a version
# bump does not silently drop sources.
major=$(sed -n 's/^MAA_MAJOR[[:space:]]*=[[:space:]]*//p' ../Makefile.common)
minor=$(sed -n 's/^MAA_MINOR[[:space:]]*=[[:space:]]*//p' ../Makefile.common)
teeny=$(sed -n 's/^MAA_TEENY[[:space:]]*=[[:space:]]*//p' ../Makefile.common)
srcs=$(awk '/^SRCS[[:space:]]*=/{f=1; sub(/^SRCS[[:space:]]*=/, "")} f{c=sub(/\\[[:space:]]*$/, ""); printf "%s ", $0; if(!c) exit}' Makefile)
[ -n "$srcs" ] && [ -n "$major" ] || { echo 'failed to parse libmaa Makefile' >&2; exit 1; }

awk -f arggram2c < arggram.txt > arggram.c

cflags="-O2 -fPIC -I. \
 -DMAA_MAJOR=$major -DMAA_MINOR=$minor -DMAA_TEENY=$teeny \
 -DSIZEOF_LONG=$sizeof_long \
 -DHAVE_HEADER_ALLOCA_H=$(have_header alloca.h) \
 -DHAVE_HEADER_SYS_RESOURCE_H=$(have_header sys/resource.h)"

objs=
for s in $srcs; do
    o=${s%.c}.o
    # shellcheck disable=SC2086
    "$cc" $cflags -c "$s" -o "$o"
    objs="$objs $o"
done

mkdir -p "$prefix/lib" "$prefix/include"
rm -f "$prefix/lib/libmaa.a"
# shellcheck disable=SC2086
"$ar" rc "$prefix/lib/libmaa.a" $objs
"$ranlib" "$prefix/lib/libmaa.a"
cp maa.h "$prefix/include/maa.h"
echo "libmaa $version (static) installed to $prefix"
