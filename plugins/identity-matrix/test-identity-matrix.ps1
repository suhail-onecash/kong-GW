# PowerShell Test Suite for identity-matrix plugin v2.0
param(
    [string]$KongUrl = "http://localhost:8000",
    [string]$RedisHost = "127.0.0.1",
    [int]$RedisPort = 6379
)

function Set-RedisKey([string]$Key, [string]$Value) {
    try {
        $client = New-Object Net.Sockets.TcpClient
        $client.Connect($RedisHost, $RedisPort)
        $stream = $client.GetStream()
        
        $keyBytes = [Text.Encoding]::UTF8.GetBytes($Key)
        $valBytes = [Text.Encoding]::UTF8.GetBytes($Value)
        
        $head = [Text.Encoding]::ASCII.GetBytes("*3`r`n`$3`r`nSET`r`n`$" + $keyBytes.Length + "`r`n")
        $stream.Write($head, 0, $head.Length)
        $stream.Write($keyBytes, 0, $keyBytes.Length)
        $stream.Write([byte[]](13, 10), 0, 2)
        $mid = [Text.Encoding]::ASCII.GetBytes("`$" + $valBytes.Length + "`r`n")
        $stream.Write($mid, 0, $mid.Length)
        $stream.Write($valBytes, 0, $valBytes.Length)
        $stream.Write([byte[]](13, 10), 0, 2)
        
        $buf = [byte[]]::new(1024)
        $null = $stream.Read($buf, 0, $buf.Length)
        $client.Close()
    } catch {
        Write-Warning "Failed to set Redis key $Key : $_"
    }
}

function Remove-RedisKey([string]$Key) {
    try {
        $client = New-Object Net.Sockets.TcpClient
        $client.Connect($RedisHost, $RedisPort)
        $stream = $client.GetStream()
        
        $keyBytes = [Text.Encoding]::UTF8.GetBytes($Key)
        $cmd = [Text.Encoding]::ASCII.GetBytes("*2`r`n`$3`r`nDEL`r`n`$" + $keyBytes.Length + "`r`n")
        $stream.Write($cmd, 0, $cmd.Length)
        $stream.Write($keyBytes, 0, $keyBytes.Length)
        $stream.Write([byte[]](13, 10), 0, 2)
        
        $buf = [byte[]]::new(1024)
        $null = $stream.Read($buf, 0, $buf.Length)
        $client.Close()
    } catch {
        Write-Warning "Failed to remove Redis key $Key : $_"
    }
}

Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host " Testing Identity Matrix Kong Plugin v2.0 (Upgraded)     " -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan

# 1. No, No Test
$msisdn_none = "967700000000"
Remove-RedisKey "passport:$msisdn_none"

Write-Host "`n[Test 1] Login No/No: Account not in North, not in South" -ForegroundColor Yellow
try {
    $res = Invoke-RestMethod -Uri "$KongUrl/NWC/rest/Login" -Method Post `
        -Headers @{ "X-MSISDN" = $msisdn_none; "Content-Type" = "application/json" } `
        -Body '{}'
    Write-Host "Response: $($res | ConvertTo-Json -Compress)"
} catch {
    $stream = $_.Exception.Response.GetResponseStream()
    $reader = New-Object IO.StreamReader($stream)
    Write-Host "Result (Expected 404 Go To Sign Up):" $reader.ReadToEnd() -ForegroundColor Green
}

# 2. Yes, No Test - Attempt Same Region Registration
$msisdn_north = "967700000001"
$north_passport = @{
    msisdn = $msisdn_north
    defaultRoute = "NORTH"
    profiles = @(
        @{ route = "NORTH"; accountId = "1001"; status = "ACTIVE"; pinInitialized = $true; persona = @("customer"); personaId = @("1") }
    )
} | ConvertTo-Json -Depth 5
Set-RedisKey "passport:$msisdn_north" $north_passport

Write-Host "`n[Test 2] Register Yes/No with region=NORTH (Expected 400: You already have an account in this region)" -ForegroundColor Yellow
try {
    $res = Invoke-RestMethod -Uri "$KongUrl/NWC/rest/register" -Method Post `
        -Headers @{ "X-MSISDN" = $msisdn_north; "X-Target-Region" = "NORTH"; "Content-Type" = "application/json" } `
        -Body '{}'
    Write-Host "Response: $($res | ConvertTo-Json -Compress)"
} catch {
    $stream = $_.Exception.Response.GetResponseStream()
    $reader = New-Object IO.StreamReader($stream)
    Write-Host "Result:" $reader.ReadToEnd() -ForegroundColor Green
}

# 3. Yes, Yes Test - Attempt 3rd Account Registration
$msisdn_both = "967700000002"
$both_passport = @{
    msisdn = $msisdn_both
    defaultRoute = "NORTH"
    profiles = @(
        @{ route = "NORTH"; accountId = "1002"; status = "ACTIVE"; pinInitialized = $true; persona = @("customer"); personaId = @("1") },
        @{ route = "SOUTH"; accountId = "2002"; status = "ACTIVE"; pinInitialized = $true; persona = @("customer"); personaId = @("1") }
    )
} | ConvertTo-Json -Depth 5
Set-RedisKey "passport:$msisdn_both" $both_passport

Write-Host "`n[Test 3] Register Yes/Yes (Expected 409: Maximum number of accounts allowed)" -ForegroundColor Yellow
try {
    $res = Invoke-RestMethod -Uri "$KongUrl/NWC/rest/register" -Method Post `
        -Headers @{ "X-MSISDN" = $msisdn_both; "X-Target-Region" = "NORTH"; "Content-Type" = "application/json" } `
        -Body '{}'
    Write-Host "Response: $($res | ConvertTo-Json -Compress)"
} catch {
    $stream = $_.Exception.Response.GetResponseStream()
    $reader = New-Object IO.StreamReader($stream)
    Write-Host "Result:" $reader.ReadToEnd() -ForegroundColor Green
}

# 4. AML Blocked Customer Test
$msisdn_aml = "967700000003"
$aml_passport = @{
    msisdn = $msisdn_aml
    defaultRoute = "NORTH"
    profiles = @(
        @{ route = "NORTH"; accountId = "1003"; status = "AML_BLOCKED"; pinInitialized = $true; persona = @("customer"); personaId = @("1") }
    )
} | ConvertTo-Json -Depth 5
Set-RedisKey "passport:$msisdn_aml" $aml_passport

Write-Host "`n[Test 4] Login AML Blocked (Expected 403: Neutral Customer Support message)" -ForegroundColor Yellow
try {
    $res = Invoke-RestMethod -Uri "$KongUrl/NWC/rest/Login" -Method Post `
        -Headers @{ "X-MSISDN" = $msisdn_aml; "Content-Type" = "application/json" } `
        -Body '{}'
    Write-Host "Response: $($res | ConvertTo-Json -Compress)"
} catch {
    $stream = $_.Exception.Response.GetResponseStream()
    $reader = New-Object IO.StreamReader($stream)
    Write-Host "Result:" $reader.ReadToEnd() -ForegroundColor Green
}

# 5. Precheck Test
Write-Host "`n[Test 5] Precheck Status Call for Yes/No MSISDN" -ForegroundColor Yellow
try {
    $res = Invoke-RestMethod -Uri "$KongUrl/NWC/rest/identity/check" -Method Post `
        -Headers @{ "X-MSISDN" = $msisdn_north; "Content-Type" = "application/json" } `
        -Body '{}'
    Write-Host "Precheck Result:" ($res | ConvertTo-Json -Depth 5) -ForegroundColor Green
} catch {
    Write-Host "Precheck Error: $_" -ForegroundColor Red
}

Write-Host "`n=========================================================" -ForegroundColor Cyan
Write-Host " Identity Matrix Tests Completed                         " -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
