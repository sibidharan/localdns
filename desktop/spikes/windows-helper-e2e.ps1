# LocalDNS Windows helper end-to-end (run elevated / via admin SSH).
# Installs the REAL localdns-helper service the way the NSIS hooks do, then
# exercises the product flow: named-pipe declarative sync -> NRPT rules
# (Comment-tagged) -> queries delivered to the loopback listener -> unregister.
# Cleans up the DNS artifacts; leaves the service installed (like a real install).

$ErrorActionPreference = "Continue"
$failures = 0
function Check($name, $ok) {
    if ($ok) { Write-Host "PASS: $name" } else { Write-Host "FAIL: $name"; $script:failures++ }
}

$exe = "C:\Program Files\LocalDNS\localdns-helper.exe"

Write-Host "== Install service (as the NSIS hooks do)"
sc.exe stop localdns-helper 2>$null | Out-Null
sc.exe delete localdns-helper 2>$null | Out-Null
sc.exe create localdns-helper binPath= "$exe" start= demand DisplayName= "LocalDNS Helper" | Out-Null
sc.exe sdset localdns-helper "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWRPLOCRRC;;;IU)(A;;CCLCSWRPLOCRRC;;;SU)" | Out-Null
Check "service installed" ((Get-Service localdns-helper -ErrorAction SilentlyContinue) -ne $null)

Write-Host "== Start dummy DNS responder on 127.65.43.53:53"
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

Write-Host "== Demand-start service and talk over the pipe (product protocol)"
sc.exe start localdns-helper | Out-Null
Start-Sleep 2
Check "service running" ((Get-Service localdns-helper).Status -eq "Running")

function Invoke-Helper($json) {
    $pipe = New-Object System.IO.Pipes.NamedPipeClientStream(".", "LocalDNSHelper", [System.IO.Pipes.PipeDirection]::InOut)
    try {
        $pipe.Connect(5000)
        $writer = New-Object System.IO.StreamWriter($pipe)
        $writer.AutoFlush = $true
        $writer.WriteLine($json)
        $reader = New-Object System.IO.StreamReader($pipe)
        return $reader.ReadLine()
    } finally { $pipe.Dispose() }
}

$syncReply = Invoke-Helper '{"op":"sync","zones":["spike.test"],"nameserver":"127.65.43.53"}'
Write-Host "sync reply: $syncReply"
Check "sync ok" ($syncReply -match '"ok":true')

Write-Host "== NRPT rule written and tagged?"
$rule = Get-DnsClientNrptRule | Where-Object Comment -eq "LocalDNS"
Check "rule exists with Comment=LocalDNS" ($null -ne $rule)
Check "rule has both namespaces" (($rule.Namespace -contains ".spike.test") -and ($rule.Namespace -contains "spike.test"))

Write-Host "== Resolution through OS path"
Start-Sleep 1
$sub = Resolve-DnsName -Name app.spike.test -Type A -ErrorAction SilentlyContinue
Check "app.spike.test resolves via NRPT to listener" ($sub.IPAddress -contains "172.30.0.99")

Write-Host "== Idempotent sync reports no change"
$again = Invoke-Helper '{"op":"sync","zones":["spike.test"],"nameserver":"127.65.43.53"}'
Write-Host "second reply: $again"
Check "second sync unchanged" ($again -match '"changed":false')

Write-Host "== UnregisterAll cleans owned rules only"
$clear = Invoke-Helper '{"op":"unregister_all"}'
Write-Host "unregister reply: $clear"
Check "unregister ok" ($clear -match '"ok":true')
Start-Sleep 1
Check "no owned rules remain" ($null -eq (Get-DnsClientNrptRule | Where-Object Comment -eq "LocalDNS"))

Write-Host "== Cleanup listener (service stays installed, demand-start)"
Stop-Job $listener; Remove-Job $listener -Force

Write-Host ""
if ($failures -eq 0) { Write-Host "HELPER E2E RESULT: ALL PASS" } else { Write-Host "HELPER E2E RESULT: $failures FAILURE(S)" }
exit $failures
