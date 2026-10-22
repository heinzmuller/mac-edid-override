#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT
bash -n install.sh uninstall.sh
clang -fmodules -Wall -Wextra -Werror -framework Foundation -framework CoreGraphics -framework IOKit -framework AppKit -o "$build_dir/edid_override" edid_override.m
clang -fmodules -Wall -Wextra -Werror -framework Foundation -framework CoreGraphics -o "$build_dir/edid_check" edid_check.m
"$build_dir/edid_override" --self-test
for profile in edids/*.bin; do "$build_dir/edid_override" --validate "$profile"; done
python3 - "$build_dir" <<'PY'
import pathlib, sys
out=pathlib.Path(sys.argv[1])
valid=bytearray(pathlib.Path('edids/dell-u4025qw.bin').read_bytes())
(out/'empty.bin').write_bytes(b'')
(out/'truncated.bin').write_bytes(valid[:-1])
valid[20]^=1
(out/'checksum.bin').write_bytes(valid)
valid=bytearray(pathlib.Path('edids/dell-u4025qw.bin').read_bytes())
valid[12:16]=b'\x00'*4
for off in range(54,109,18):
    if valid[off:off+4]==b'\x00\x00\x00\xff': valid[off+5:off+18]=b' '*13
valid[127]=(-sum(valid[:127]))%256
(out/'no-serial.bin').write_bytes(valid)
valid=bytearray(pathlib.Path('edids/dell-u4025qw.bin').read_bytes())
for off in range(128,len(valid),128):
    if valid[off]==0x70:
        valid[off+8]^=1
        valid[off+127]=(-sum(valid[off:off+127]))%256
        break
(out/'displayid-checksum.bin').write_bytes(valid)
PY
for fixture in empty truncated checksum no-serial displayid-checksum; do
    if "$build_dir/edid_override" --validate "$build_dir/$fixture.bin"; then
        echo "Malformed fixture accepted: $fixture" >&2; exit 1
    fi
done
if "$build_dir/edid_override" --test edids/dell-u4025qw.bin </dev/null; then
    echo 'Non-interactive test unexpectedly accepted' >&2; exit 1
fi
echo 'Offline checks passed. Live display tests have not been run.'
