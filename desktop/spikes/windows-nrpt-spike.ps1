# LocalDNS Windows spike - validates the riskiest Windows assumptions.
# Run in an ELEVATED PowerShell:
#   1. An unprivileged-bindable 127.65.43.53:53 listener coexists with
#      anything squatting 0.0.0.0:53 (Docker/ICS/WSL2).
#   2. dnscache actually delivers NRPT-matched queries to that loopback
#      nameserver on current Windows 11.
#   3. Apex semantics: does ".zone" match the apex, or is the "zone" (apex)
#      namespace entry required?
# Prints PASS/FAIL per step; cleans up after itself.

$ErrorActionPreference = "Continue"
$failures = 0
function Check($name, $ok) {
    if ($ok) { Write-Host "PASS: $name" -ForegroundColor Green }
    else { Write-Host "FAIL: $name" -ForegroundColor Red; $script:failures++ }
}

Write-Host "== Start dummy DNS responder on 127.65.43.53:53 (answers A 172.30.0.99)"
$listener = Start-Job -ScriptBlock {
    $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse("127.65.43.53"), 53)
    $udp = New-Object System.Net.Sockets.UdpClient
    $udp.Client.Bind($ep)
    while ($true) {
        $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $data = $udp.Receive([ref]$remote)
        if ($data.Length -lt 12) { continue }
        $i = 12
        while ($i -lt $data.Length -and $data[$i] -ne 0) { $i += $data[$i] + 1 }
        $qend = $i + 5
        if ($qend -gt $data.Length) { continue }
        $resp = New-Object System.Collections.Generic.List[byte]
        $resp.AddRange([byte[]]$data[0..1])
        $resp.AddRange([byte[]]@(0x81, 0x80, 0, 1, 0, 1, 0, 0, 0, 0))
        $resp.AddRange([byte[]]$data[12..($qend - 1)])
        $resp.AddRange([byte[]]@(0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 172, 30, 0, 99))
        [void]$udp.Send($resp.ToArray(), $resp.Count, $remote)
    }
}
Start-Sleep 2
Check "listener bound (job running)" ($listener.State -eq "Running")

Write-Host "== Direct query to the listener (bypasses NRPT - proves the bind works)"
$direct = Resolve-DnsName -Name direct.spike.test -Server 127.65.43.53 -Type A -DnsOnly -ErrorAction SilentlyContinue
Check "direct query answered 172.30.0.99" ($direct.IPAddress -contains "172.30.0.99")

Write-Host "== Add NRPT rule (suffix + apex namespaces) and flush cache"
Add-DnsClientNrptRule -Namespace ".spike.test", "spike.test" -NameServers "127.65.43.53" `
    -Comment "LocalDNS" -DisplayName "LocalDNS: spike.test"
Clear-DnsClientCache
Start-Sleep 1

Write-Host "== NRPT-routed queries (no -Server: the OS resolver path decides)"
$sub = Resolve-DnsName -Name app.spike.test -Type A -ErrorAction SilentlyContinue
Check "subdomain via NRPT answered 172.30.0.99" ($sub.IPAddress -contains "172.30.0.99")
$apex = Resolve-DnsName -Name spike.test -Type A -ErrorAction SilentlyContinue
Check "apex via NRPT answered 172.30.0.99" ($apex.IPAddress -contains "172.30.0.99")

Write-Host "== Apex-semantics probe: suffix-only rule"
Get-DnsClientNrptRule | Where-Object Comment -eq "LocalDNS" | Remove-DnsClientNrptRule -Force
Add-DnsClientNrptRule -Namespace ".apexprobe.test" -NameServers "127.65.43.53" -Comment "LocalDNS"
Clear-DnsClientCache
Start-Sleep 1
$sub2 = Resolve-DnsName -Name sub.apexprobe.test -Type A -ErrorAction SilentlyContinue
Check "suffix-only: subdomain matched" ($sub2.IPAddress -contains "172.30.0.99")
$apex2 = Resolve-DnsName -Name apexprobe.test -Type A -ErrorAction SilentlyContinue
if ($apex2.IPAddress -contains "172.30.0.99") {
    Write-Host "INFO: '.zone' alone DOES match the apex on this build"
} else {
    Write-Host "INFO: '.zone' alone does NOT match the apex - the apex namespace entry is required (as shipped)"
}

Write-Host "== Registry ownership marker round-trip"
$reg = Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters\DnsPolicyConfig" -ErrorAction SilentlyContinue |
    Get-ItemProperty | Where-Object Comment -eq "LocalDNS"
Check "Comment=LocalDNS visible in registry" ($null -ne $reg)

Write-Host "== Port-53 coexistence snapshot"
Get-NetUDPEndpoint -LocalPort 53 -ErrorAction SilentlyContinue |
    Select-Object LocalAddress, LocalPort, OwningProcess | Format-Table | Out-String | Write-Host

Write-Host "== Cleanup"
Get-DnsClientNrptRule | Where-Object Comment -eq "LocalDNS" | Remove-DnsClientNrptRule -Force
Clear-DnsClientCache
Stop-Job $listener; Remove-Job $listener -Force

Write-Host ""
if ($failures -eq 0) { Write-Host "SPIKE RESULT: ALL PASS" -ForegroundColor Green }
else { Write-Host "SPIKE RESULT: $failures FAILURE(S)" -ForegroundColor Red }
exit $failures
