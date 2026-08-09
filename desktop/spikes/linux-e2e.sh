#!/bin/bash
# LocalDNS Linux end-to-end: installs the REAL localdns-agentd (built from
# this workspace) with its unit/D-Bus/polkit files, then exercises the exact
# flow the GUI uses — D-Bus Sync → resolved routing → query → resolved
# restart resilience → UnregisterAll. Run as root on the VM; expects the
# workspace at $SRC (default /root/localdns-src/desktop).

set -u
SRC="${SRC:-/root/localdns-src/desktop}"
FAILURES=0
step() { echo; echo "== $1"; }
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; FAILURES=$((FAILURES+1)); fi; }

step "Install agent binary + unit + D-Bus policy + polkit action"
install -D -m755 "$SRC/target/release/localdns-agentd" /usr/lib/localdns/localdns-agentd
install -D -m644 "$SRC/app/src-tauri/linux/localdns-agentd.service" /usr/lib/systemd/system/localdns-agentd.service
install -D -m644 "$SRC/app/src-tauri/linux/org.localdns.Agent1.conf" /usr/share/dbus-1/system.d/org.localdns.Agent1.conf
install -D -m644 "$SRC/app/src-tauri/linux/org.localdns.agent.policy" /usr/share/polkit-1/actions/org.localdns.agent.policy
systemctl daemon-reload
# D-Bus reads system.d policies on the fly for new files; reload to be sure.
systemctl reload dbus 2>/dev/null || true

step "Start the agent"
systemctl restart localdns-agentd.service
sleep 2
systemctl is-active localdns-agentd.service
check "agent service active" "systemctl is-active --quiet localdns-agentd.service"
check "bus name owned" "busctl status org.localdns.LocalDNS >/dev/null 2>&1"

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

step "Sync via D-Bus exactly like the GUI (zones: e2e.test, spike.test)"
busctl call org.localdns.LocalDNS /org/localdns/Agent1 org.localdns.Agent1 Sync asq 2 e2e.test spike.test 15353
# busctl escapes quotes in its string rendering (\"ok\":true), so match loosely.
check "Sync returned ok" "busctl call org.localdns.LocalDNS /org/localdns/Agent1 org.localdns.Agent1 Sync asq 2 e2e.test spike.test 15353 | grep -qE 'ok.{1,2}:true'"
check "state persisted" "grep -q e2e.test /var/lib/localdns/state.json"

step "Routing live?"
resolvectl status localdns0 2>/dev/null | sed -n '1,8p'
check "scope active" "resolvectl status localdns0 | grep -q 'Current Scopes:.*DNS'"
check "query resolves through resolved" "resolvectl query app.e2e.test 2>/dev/null | grep -q 172.30.0.99"
check "second zone resolves too" "getent hosts web.spike.test | grep -q 172.30.0.99"

step "Resolved restart resilience (the agent watches NameOwnerChanged)"
systemctl restart systemd-resolved
sleep 4
check "routing survives resolved restart" "resolvectl query again.e2e.test 2>/dev/null | grep -q 172.30.0.99"

step "Status call"
busctl call org.localdns.LocalDNS /org/localdns/Agent1 org.localdns.Agent1 Status

step "UnregisterAll reverts routing"
busctl call org.localdns.LocalDNS /org/localdns/Agent1 org.localdns.Agent1 UnregisterAll
sleep 1
check "zones no longer resolve" "! resolvectl query app.e2e.test >/dev/null 2>&1"

step "Cleanup responder (agent + files stay installed)"
kill "$RESPONDER" 2>/dev/null

echo
if [ "$FAILURES" -eq 0 ]; then echo "E2E RESULT: ALL PASS"; else echo "E2E RESULT: $FAILURES FAILURE(S)"; fi
exit "$FAILURES"
