#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT
bash -n install.sh uninstall.sh
clang -fmodules -Wall -Wextra -Werror -framework Foundation -framework CoreGraphics -framework IOKit -framework AppKit -o "$build_dir/edid_override" edid_override.m
clang -fmodules -Wall -Wextra -Werror -framework Foundation -framework CoreGraphics -o "$build_dir/edid_check" edid_check.m
"$build_dir/edid_override" --self-test
# Synthetic profiles exist only in the temporary build directory.
python3 - "$build_dir" <<'FIXTURES'
import pathlib, struct, sys
out = pathlib.Path(sys.argv[1])

def checksum(block):
    block[127] = (-sum(block[:127])) % 256

base = bytearray(128)
base[:8] = bytes.fromhex('00ffffffffffff00')
base[8:16] = struct.pack('>H', 0x5274) + struct.pack('<HI', 1, 0x12345678)  # TST, dummy product/serial
base[18:21] = bytes([1, 4, 0x80])
base[90:108] = b'\0\0\0\xfc\0TEST DISPLAY\n'
base[108:126] = b'\0\0\0\xff\0DUMMY0001\n   '
checksum(base)
(out/'valid-base.bin').write_bytes(base)

# Synthetic 640x480 timing in a DisplayID extension; never use on a monitor.
ext = bytearray(128)
ext[:8] = bytes([0x70, 0x12, 23, 3, 0, 3, 1, 20])
ext[8:28] = (2517).to_bytes(3, 'little') + bytes([0]) + struct.pack('<8H', 639, 159, 15, 95, 479, 44, 9, 1)
ext[28] = (-sum(ext[1:28])) % 256
checksum(ext)
base[126] = 1
checksum(base)
valid = base + ext
assert len(valid) == 256
assert all(sum(valid[i:i+128]) % 256 == 0 for i in range(0, len(valid), 128))
(out/'valid-displayid.bin').write_bytes(valid)
(out/'empty.bin').write_bytes(b'')
(out/'truncated.bin').write_bytes(valid[:-1])
bad = valid.copy()
bad[20] ^= 1
(out/'checksum.bin').write_bytes(bad)
bad = valid.copy()
bad[12:16] = b'\0' * 4
bad[113:126] = b' ' * 13
checksum(bad)
(out/'no-serial.bin').write_bytes(bad)
bad = valid.copy()
bad[136] ^= 1
block = bad[128:]
checksum(block)
bad[128:] = block
(out/'displayid-checksum.bin').write_bytes(bad)
FIXTURES
for fixture in valid-base valid-displayid; do
    "$build_dir/edid_override" --validate "$build_dir/$fixture.bin"
done
for fixture in empty truncated checksum no-serial displayid-checksum; do
    if "$build_dir/edid_override" --validate "$build_dir/$fixture.bin"; then
        echo "Malformed fixture accepted: $fixture" >&2; exit 1
    fi
done
if "$build_dir/edid_override" --test "$build_dir/valid-displayid.bin" </dev/null; then
    echo 'Non-interactive test unexpectedly accepted' >&2; exit 1
fi
echo 'Offline checks passed. Live display tests have not been run.'
