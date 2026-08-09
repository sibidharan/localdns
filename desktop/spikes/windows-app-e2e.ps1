# LocalDNS full-app E2E on Windows: seed rule, launch the installed app in the
# interactive session, verify server bindings, sync NRPT via the helper pipe,
# resolve through the OS path against the app's real server.

$ErrorActionPreference = "Continue"
$failures = 0
function Check($name, $ok) {
    if ($ok) { Write-Host "PASS: $name" } else { Write-Host "FAIL: $name"; $script:failures++ }
}

Write-Host "== Seed rules.json"
New-Item -ItemType Directory -Force -Path "$env:APPDATA\LocalDNS" | Out-Null
$rules = '[{"enabled":true,"group":"Demo","id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","ipv4":"172.30.0.99","pattern":"*.demo.test","ttl":60}]'
Set-Content -Path "$env:APPDATA\LocalDNS\rules.json" -Encoding ascii -Value $rules

Write-Host "== Launch app in interactive session"
Stop-Process -Name localdns-app -Force -ErrorAction SilentlyContinue
Start-Sleep 1
schtasks /create /tn LocalDNSLaunch /tr C:\PROGRA~1\LocalDNS\localdns-app.exe /sc once /st 00:00 /it /f | Out-Null
schtasks /run /tn LocalDNSLaunch | Out-Null
Start-Sleep 8
$proc = Get-Process localdns-app -ErrorAction SilentlyContinue
Check "app process running" ($null -ne $proc)

Write-Host "== Server bindings"
$p53 = Get-NetUDPEndpoint -LocalPort 53 -ErrorAction SilentlyContinue | Where-Object LocalAddress -eq "127.65.43.53"
Check "app bound 127.65.43.53:53" ($null -ne $p53 -and ($p53.OwningProcess -contains $proc.Id -or $p53.OwningProcess -eq $proc.Id))
$p15353 = Get-NetUDPEndpoint -LocalPort 15353 -ErrorAction SilentlyContinue
Check "app bound 127.0.0.1:15353" ($null -ne $p15353)

Write-Host "== Direct query to the app's own server"
$direct = Resolve-DnsName -Name web.demo.test -Server 127.65.43.53 -Type A -DnsOnly -ErrorAction SilentlyContinue
Check "app answers directly (172.30.0.99)" ($direct.IPAddress -contains "172.30.0.99")

Write-Host "== Sync zone via helper pipe (the app's own privileged path)"
sc.exe start localdns-helper 2>$null | Out-Null
Start-Sleep 2
function Invoke-Helper($json) {
    $pipe = New-Object System.IO.Pipes.NamedPipeClientStream(".", "LocalDNSHelper", [System.IO.Pipes.PipeDirection]::InOut)
    try {
        $pipe.Connect(5000)
        $writer = New-Object System.IO.StreamWriter($pipe); $writer.AutoFlush = $true
        $writer.WriteLine($json)
        $reader = New-Object System.IO.StreamReader($pipe)
        return $reader.ReadLine()
    } finally { $pipe.Dispose() }
}
$reply = Invoke-Helper '{"op":"sync","zones":["demo.test"],"nameserver":"127.65.43.53"}'
Write-Host "helper reply: $reply"
Check "helper sync ok" ($reply -match '"ok":true')
Start-Sleep 1

Write-Host "== Resolution through the OS (NRPT -> app server)"
$os = Resolve-DnsName -Name app.demo.test -Type A -ErrorAction SilentlyContinue
Check "app.demo.test resolves via OS to 172.30.0.99" ($os.IPAddress -contains "172.30.0.99")

Write-Host ""
if ($failures -eq 0) { Write-Host "WINDOWS APP E2E: ALL PASS" } else { Write-Host "WINDOWS APP E2E: $failures FAILURE(S)" }
exit $failures
