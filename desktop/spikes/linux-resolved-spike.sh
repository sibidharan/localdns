#!/bin/bash
# LocalDNS Linux spike — validates the three riskiest assumptions on a real
# Ubuntu/systemd-resolved system (run as root):
#   1. resolved activates a DNS scope on a dummy link (it never does on lo).
#   2. `resolvectl dns` accepts address:port (SetLinkDNSEx) and resolved
#      actually delivers zone queries to 127.0.0.1:15353.
#   3. NetworkManager leaves an externally created localdns0 alone.
# Prints PASS/FAIL per step; cleans up after itself.

set -u
FAILURES=0
step() { echo; echo "== $1"; }
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; FAILURES=$((FAILURES+1)); fi; }

step "Start dummy DNS responder on 127.0.0.1:15353 (answers A 172.30.0.99)"
python3 - <<'PY' &
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("127.0.0.1", 15353))
while True:
    data, peer = s.recvfrom(4096)
    if len(data) < 12:
        continue
    i = 12
    while i < len(data) and data[i] != 0:
        i += data[i] + 1
    qend = i + 5
    if qend > len(data):
        continue
    resp = data[:2] + b'\x81\x80\x00\x01\x00\x01\x00\x00\x00\x00' + data[12:qend]
    resp += b'\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04' + bytes([172, 30, 0, 99])
    s.sendto(resp, peer)
PY
RESPONDER=$!
sleep 1

step "Create dummy link localdns0 (with address — resolved only allocates a"
step "DNS scope for links that carry one; verified on systemd 255/Ubuntu 24.04)"
ip link add localdns0 type dummy 2>/dev/null || true
ip addr replace 198.51.100.53/32 dev localdns0
ip link set up dev localdns0
check "link exists and is up" "ip link show localdns0 | grep -q 'state \(UNKNOWN\|UP\)'"

step "Configure resolved: port syntax + routing domain + no default route"
resolvectl dns localdns0 127.0.0.1:15353; check "resolvectl dns accepts address:port" "[ $? -eq 0 ]"
resolvectl domain localdns0 '~spike.test'
resolvectl default-route localdns0 false
resolvectl status localdns0 || true

step "Scope activation (the systemd#23656 failure mode is 'Current Scopes: none')"
check "DNS scope active on localdns0" "resolvectl status localdns0 | grep -q 'Current Scopes:.*DNS'"

step "End-to-end query through resolved"
resolvectl query app.spike.test || true
check "resolvectl query resolves via our responder" "resolvectl query app.spike.test 2>/dev/null | grep -q '172.30.0.99'"
check "getent (NSS path) resolves too" "getent hosts app.spike.test | grep -q '172.30.0.99'"
check "apex resolves as well" "resolvectl query spike.test 2>/dev/null | grep -q '172.30.0.99'"

step "NetworkManager interference (10s grace)"
sleep 10
check "localdns0 still exists after grace period" "ip link show localdns0 >/dev/null 2>&1"
check "routing domain still applied" "resolvectl status localdns0 | grep -q 'spike.test'"

step "Cleanup"
kill "$RESPONDER" 2>/dev/null
ip link del localdns0 2>/dev/null
resolvectl flush-caches 2>/dev/null || true

echo
if [ "$FAILURES" -eq 0 ]; then echo "SPIKE RESULT: ALL PASS"; else echo "SPIKE RESULT: $FAILURES FAILURE(S)"; fi
exit "$FAILURES"
