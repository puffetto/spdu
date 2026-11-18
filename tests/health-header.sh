#!/bin/sh
# File: tests/health-header.sh
# Created by Andrea "Nemesi" Cocito on 18/11/2026
# Exercise the actual header parser against independent wire-format cases.
set -eu
base=$(CDPATH='' cd -P "$(dirname "$0")/.." && pwd)
runtime=$(mktemp -d "${TMPDIR:-/tmp}/spdu-health.XXXXXXXX")
trap 'rm -rf "$runtime"' EXIT
trap 'exit 130' HUP INT TERM
awk '/^healthHeader\(\)/ {copy=1} /^probe\(\)/ {copy=0} copy {print}' "$base/spdu" > "$runtime/parser"
. "$runtime/parser"
check() {
    expected=$1; shift
    printf 'HTTP/1.1 200 OK\r\n%s\r\n\r\n' "$*" > "$runtime/http-headers"
    actual=0; healthHeader || actual=$?
    if [ "$expected" = error ]; then [ "$actual" = 65 ]
    else [ "$actual" = 0 ] && [ "$(cat "$runtime/health-score")" = "$expected" ]; fi
}
check legacy 'Content-Length: 0'
check error "$(printf 'X-SPDU-Health:\r\nX-SPDU-Health: 5')"
check 0 'X-SPDU-Health: 0'
check 1 'X-SPDU-Health: 00000001'
check 2000000001 'x-spdu-health: 2000000001'
check 4294967295 'X-SPDU-Health: 4294967295'
check legacy 'X-SPDU-Health: 4294967296'
check legacy 'X-SPDU-Health: +1'
check legacy 'X-SPDU-Health: -1'
check legacy 'X-SPDU-Health: 0x10'
check legacy 'X-SPDU-Health: 1 0'
check legacy 'X-SPDU-Health: 9999999999999999999999999999'
check 3500000000 "X-SPDU-Health: $(printf '\t')3500000000$(printf '\t')"
check 1 'X-SPDU-Health: 01, 1'
check error 'X-SPDU-Health: 1, 2'
check error 'X-SPDU-Health: 1, invalid'
check error 'X-SPDU-Health: 1,'
check 3000000000 "$(printf 'X-SPDU-Health: 3000000000\r\nX-SPDU-Health: 03000000000')"
check error "$(printf 'X-SPDU-Health: 1\r\nX-SPDU-Health: 2')"
printf 'HTTP/1.1 103 Early Hints\r\nX-SPDU-Health: 0\r\n\r\nHTTP/1.1 200 OK\r\nX-SPDU-Health: 7\r\n\r\nX-SPDU-Health: 0\r\n' > "$runtime/http-headers"
healthHeader
[ "$(cat "$runtime/health-score")" = 7 ]
echo 'PASS SPDU actual header parser: 20 uint32/legacy/coherent/conflicting/OWS/interim/trailer cases'
# END File: tests/health-header.sh
