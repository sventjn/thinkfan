#!/usr/bin/env bash
# Package and self test: build the tarball, unpack it, run it
set -uo pipefail
cd "$(dirname -- "$0")" || exit 1
bash -n thinkfan && bash -n thinkfan-root && bash -n install-thinkfan.sh || exit 1
chmod 755 thinkfan thinkfan-root install-thinkfan.sh selftest.sh
chmod 644 thinkfan.conf README.md LICENSE

rm -f thinkfan-1.0.0.tar.gz
tar czf thinkfan-1.0.0.tar.gz --owner=0 --group=0 \
    thinkfan thinkfan-root thinkfan.conf install-thinkfan.sh README.md LICENSE

echo "=== Contents ==="
tar tzvf thinkfan-1.0.0.tar.gz
echo "=== sha256 ==="
sha256sum thinkfan-1.0.0.tar.gz
echo
echo "=== Cross check: unpack and run ==="
rm -rf /tmp/fmentpack && mkdir -p /tmp/fmentpack && tar xzf thinkfan-1.0.0.tar.gz -C /tmp/fmentpack
cd /tmp/fmentpack || exit 1
ls -l
./thinkfan --version
./thinkfan --check
./thinkfan --probe | head -6
./thinkfan-root fan 9 2>&1 | head -1
echo "Helper still refuses (rc=1 above) and cannot run as a non-root user:"
./thinkfan-root selftest 2>&1 | head -1
