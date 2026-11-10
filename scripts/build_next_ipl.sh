#!/usr/bin/env bash
# Build the ZX Spectrum Next boot loader (the IPL) from its GPL source.
#
# The IPL is the 8 KiB boot ROM that starts the SD card, finds TBBLUE.FW in its
# root and loads the firmware's boot module. Its C and assembly source ships in
# the official System/Next distribution under src/firmware/loader, released
# under GPL-3.0-or-later. MiSTer's rtl/rom/bootrom.vhd is a build of it with no
# notice and is not used; this script builds the same program from source.
#
# The source is fetched from the pinned distribution commit with a sparse clone
# and compiled with SDCC 4.0.0, the Debian bullseye package, inside Docker. The
# published source lags the release: main.c uses RESET_POWERON, which
# hardware.h no longer defines. It only stores the value, and the core puts
# the power-on flag in bit 2 of NextREG 0x02, so it is defined as 0x04 on the
# command line and the source stays untouched.
#
# Writes OUTPUT/loader.bin, OUTPUT/loader.bin.notice (for
# scripts/build_diagnostic_boot.py --notice-file) and OUTPUT/loader.map. The
# image is a private test article: NextTang does not distribute it.
#
# Usage: scripts/build_next_ipl.sh ABSOLUTE_OUTPUT_DIRECTORY
set -euo pipefail

distribution=https://gitlab.com/thesmog358/tbblue.git
revision=f287c48bf6af3528e32977b913bac2c589d9f973
# debian:bullseye, whose sdcc package is 4.0.0+dfsg-2.
image=debian@sha256:6f519a81440354a85eb592c5f32109ab80605f6b892455983a6f618bf87fabe9

output=${1:-}
if [[ "$output" != /* ]]; then
    printf '%s\n' 'usage: scripts/build_next_ipl.sh ABSOLUTE_OUTPUT_DIRECTORY' >&2
    exit 2
fi
command -v docker >/dev/null || { echo "build_next_ipl: docker is not installed" >&2; exit 2; }
mkdir -p "$output"

checkout="$output/tbblue"
if [[ ! -d "$checkout/.git" ]]; then
    git clone -q --filter=blob:none --no-checkout --sparse "$distribution" "$checkout"
    git -C "$checkout" sparse-checkout set src/firmware
fi
git -C "$checkout" checkout -q "$revision"
[[ $(git -C "$checkout" rev-parse HEAD) == "$revision" ]] || {
    echo "build_next_ipl: checkout is not at $revision" >&2
    exit 1
}

docker run --rm --network=bridge \
    -v "$checkout/src/firmware:/src:ro" -v "$output:/out" \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    "$image" bash -euo pipefail -c '
        apt-get update -qq >/dev/null
        apt-get install -y -qq sdcc >/dev/null 2>&1
        sdcc --version | head -n 1 | grep -q " 4\.0\.0 " || { sdcc --version >&2; exit 1; }
        cp -r /src /work
        cd /work/loader
        mkdir -p obj
        for source in crt0 mmc; do sdasz80 -o obj/$source.rel src/$source.s; done
        for source in main fat vdp; do
            sdcc -mz80 --opt-code-size --fomit-frame-pointer -DRESET_POWERON=0x04 \
                -Iinc -I.. -c -o obj/$source.rel src/$source.c
        done
        sdcc -mz80 --code-loc 0x0100 --data-loc 0xF800 --no-std-crt0 -o loader.ihx \
            obj/crt0.rel obj/main.rel obj/mmc.rel obj/fat.rel obj/vdp.rel
        makebin -p loader.ihx loader.bin
        cp loader.bin loader.map /out/
        chown "$HOST_UID:$HOST_GID" /out/loader.bin /out/loader.map
    '

size=$(stat -c %s "$output/loader.bin")
(( size <= 8192 )) || { echo "build_next_ipl: loader is $size bytes, over 8 KiB" >&2; exit 1; }

cat >"$output/loader.bin.notice" <<EOF
SPDX-License-Identifier: GPL-3.0-or-later
ZX Spectrum Next Firmware boot loader
Copyright 2020 Garry Lancaster, Fabio Belavenuto & Victor Trucco
Built by scripts/build_next_ipl.sh from src/firmware/loader of
$distribution at $revision
with SDCC 4.0.0 and -DRESET_POWERON=0x04.
EOF

sha256sum "$output/loader.bin"
