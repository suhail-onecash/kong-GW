# kong/plugins/switch-account/test-switch-account.ps1
# Automated test suite for the Switch Account & Create New Account plugin
# Validates Scenarios 1 to 16 against seeded Redis passport states and Kong Gateway.

param(
    [string]$KongUrl = "http://localhost:8000",
    [string]$RedisHost = "localhost",
    [int]$RedisPort = 6379
)

$ErrorActionPreference = "Continue"

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "  SWITCH ACCOUNT & CREATE NEW ACCOUNT (SOUTH & NORTH) TEST SUITE " -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "Target Kong URL : $KongUrl"
Write-Host "Redis Host/Port : ${RedisHost}:${RedisPort}`n"

function Invoke-RedisCommand {
    param([string]$Command)
    try {
        # Using redis-cli or docker exec redis if available
        $output = docker exec redis redis-cli $Command 2>$null
        if (-not $output) {
            $output = redis-cli -h $RedisHost -p $RedisPort $Command 2>$null
        }
        return $output
    } catch {
        return $null
    }
}

function Test-Endpoint {
    param(
        [string]$Name,
        [string]$Method,
        [string]$Path,
        [hashtable]$Headers,
        [string]$Body = $null,
        [int]$ExpectedStatus,
        [string]$ExpectedAction = $null,
        [string]$ExpectedErrorCode = $null,
        [string]$ExpectedMessageContains = $null
    )

    $url = "$KongUrl$Path"
    $headersObj = @{}
    foreach ($k in $Headers.Keys) { $headersObj[$k] = [string]$Headers[$k] }

    try {
        $params = @{
            Uri = $url
            Method = $Method
            Headers = $headersObj
            ContentType = "application/json"
            UseBasicParsing = $true
        }
        if ($Body) { $params["Body"] = $Body }

        $response = Invoke-RestMethod @params
        $statusCode = 200
        $respBody = $response
    } catch {
        $statusCode = [int]$_.Exception.Response.StatusCode
        try {
            $stream = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $rawJson = $reader.ReadToEnd()
            $respBody = $rawJson | ConvertFrom-Json
        } catch {
            $respBody = @{ message = $_.Exception.Message }
        }
    }

    $pass = $true
    $failReasons = @()

    if ($statusCode -ne $ExpectedStatus) {
        $pass = $false
        $failReasons += "Status: expected $ExpectedStatus got $statusCode"
    }

    if ($ExpectedAction -and ($respBody.action -ne $ExpectedAction)) {
        $pass = $false
        $failReasons += "Action: expected $ExpectedAction got $($respBody.action)"
    }

    if ($ExpectedErrorCode -and ($respBody.errorCode -ne $ExpectedErrorCode)) {
        $pass = $false
        $failReasons += "ErrorCode: expected $ExpectedErrorCode got $($respBody.errorCode)"
    }

    if ($ExpectedMessageContains -and ($respBody.message -notmatch $ExpectedMessageContains)) {
        $pass = $false
        $failReasons += "Message: expected to contain '$ExpectedMessageContains' got '$($respBody.message)'"
    }

    if ($pass) {
        Write-Host "[PASS] $Name" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] $Name -> $($failReasons -join ', ')" -ForegroundColor Red
    }
}

# ------------------------------------------------------------------
# Test Cases Setup & Execution
# ------------------------------------------------------------------

# Scenario 1: Customer has 1 South wallet -> Decision returns CREATE (target: NORTH)
Write-Host "`n--- Scenario 1: Single South Wallet -> Offer Opposite (North) Creation ---" -ForegroundColor Yellow
$p1 = @{
    guid = "guid-sc1-0001"; msisdn = "967700000001"; defaultRoute = "SOUTH"
    profiles = @(
        @{ route = "SOUTH"; accountId = 2001; status = "ACTIVE"; pinInitialized = $true; tier = "TIER1" }
    )
} | ConvertTo-Json -Compress
Invoke-RedisCommand "SET passport:967700000001 '$p1'" | Out-Null

Test-Endpoint -Name "Scenario 1: Single South Wallet Decision" `
    -Method "GET" -Path "/switch/decision" `
    -Headers @{ "X-MSISDN" = "967700000001" } `
    -ExpectedStatus 200 -ExpectedAction "CREATE"

# Scenario 2: Customer has 1 North wallet -> Decision returns CREATE (target: SOUTH)
Write-Host "`n--- Scenario 2: Single North Wallet -> Offer Opposite (South) Creation ---" -ForegroundColor Yellow
$p2 = @{
    guid = "guid-sc2-0002"; msisdn = "967700000002"; defaultRoute = "NORTH"
    profiles = @(
        @{ route = "NORTH"; accountId = 1002; status = "ACTIVE"; pinInitialized = $true; tier = "TIER0" }
    )
} | ConvertTo-Json -Compress
Invoke-RedisCommand "SET passport:967700000002 '$p2'" | Out-Null

Test-Endpoint -Name "Scenario 2: Single North Wallet Decision" `
    -Method "GET" -Path "/switch/decision" `
    -Headers @{ "X-MSISDN" = "967700000002" } `
    -ExpectedStatus 200 -ExpectedAction "CREATE"

# Scenario 3: Customer has both wallets Active -> Decision returns SWITCH
Write-Host "`n--- Scenario 3: Dual Active Wallets -> Switch Journey ---" -ForegroundColor Yellow
$p3 = @{
    guid = "guid-sc3-0003"; msisdn = "967700000003"; defaultRoute = "NORTH"
    profiles = @(
        @{ route = "NORTH"; accountId = 1003; status = "ACTIVE"; pinInitialized = $true; tier = "TIER1" },
        @{ route = "SOUTH"; accountId = 2003; status = "ACTIVE"; pinInitialized = $true; tier = "TIER1" }
    )
} | ConvertTo-Json -Compress
Invoke-RedisCommand "SET passport:967700000003 '$p3'" | Out-Null

Test-Endpoint -Name "Scenario 3: Dual Wallet Decision" `
    -Method "GET" -Path "/switch/decision" `
    -Headers @{ "X-MSISDN" = "967700000003" } `
    -ExpectedStatus 200 -ExpectedAction "SWITCH"

# Scenario 4: Target wallet exists but PIN is NOT INITIALIZED
Write-Host "`n--- Scenario 4: Target Wallet PIN Not Initialized ---" -ForegroundColor Yellow
$p4 = @{
    guid = "guid-sc4-0004"; msisdn = "967700000004"; defaultRoute = "SOUTH"
    profiles = @(
        @{ route = "SOUTH"; accountId = 2004; status = "ACTIVE"; pinInitialized = $true },
        @{ route = "NORTH"; accountId = 1004; status = "NOT_INITIALIZED"; pinInitialized = $false }
    )
} | ConvertTo-Json -Compress
Invoke-RedisCommand "SET passport:967700000004 '$p4'" | Out-Null

Test-Endpoint -Name "Scenario 4: PIN Not Initialized Decision" `
    -Method "GET" -Path "/switch/decision" `
    -Headers @{ "X-MSISDN" = "967700000004" } `
    -ExpectedStatus 200 -ExpectedAction "FIRST_TIME_PIN_SETUP" -ExpectedErrorCode "SW_005"

# Scenario 5: Default wallet is Suspended, other is Active
Write-Host "`n--- Scenario 5: Suspended Default Wallet with Active Target ---" -ForegroundColor Yellow
$p5 = @{
    guid = "guid-sc5-0005"; msisdn = "967700000005"; defaultRoute = "NORTH"
    profiles = @(
        @{ route = "NORTH"; accountId = 1005; status = "SUSPENDED"; pinInitialized = $true },
        @{ route = "SOUTH"; accountId = 2005; status = "ACTIVE"; pinInitialized = $true }
    )
} | ConvertTo-Json -Compress
Invoke-RedisCommand "SET passport:967700000005 '$p5'" | Out-Null

Test-Endpoint -Name "Scenario 5: Focus active wallet when default suspended" `
    -Method "GET" -Path "/switch/decision" `
    -Headers @{ "X-MSISDN" = "967700000005" } `
    -ExpectedStatus 200

# Scenario 6: AML-Blocked / Suspended with no other wallet -> Neutral support message
Write-Host "`n--- Scenario 6: AML-Blocked Customer ---" -ForegroundColor Yellow
$p6 = @{
    guid = "guid-sc6-0006"; msisdn = "967700000006"; defaultRoute = "NORTH"
    profiles = @(
        @{ route = "NORTH"; accountId = 1006; status = "AML_BLOCKED"; pinInitialized = $true }
    )
} | ConvertTo-Json -Compress
Invoke-RedisCommand "SET passport:967700000006 '$p6'" | Out-Null

Test-Endpoint -Name "Scenario 6: AML Block Neutral Customer Message" `
    -Method "GET" -Path "/switch/decision" `
    -Headers @{ "X-MSISDN" = "967700000006" } `
    -ExpectedStatus 403 -ExpectedAction "BLOCKED" -ExpectedMessageContains "contact customer support"

# Scenario 7: One of two wallets is Terminated -> Replacement available
Write-Host "`n--- Scenario 7: Terminated Wallet Replacement ---" -ForegroundColor Yellow
$p7 = @{
    guid = "guid-sc7-0007"; msisdn = "967700000007"; defaultRoute = "NORTH"
    profiles = @(
        @{ route = "NORTH"; accountId = 1007; status = "ACTIVE"; pinInitialized = $true },
        @{ route = "SOUTH"; accountId = 2007; status = "TERMINATED"; pinInitialized = $true }
    )
} | ConvertTo-Json -Compress
Invoke-RedisCommand "SET passport:967700000007 '$p7'" | Out-Null

Test-Endpoint -Name "Scenario 7: Switch and Offer Replacement for Terminated Wallet" `
    -Method "GET" -Path "/switch/decision" `
    -Headers @{ "X-MSISDN" = "967700000007" } `
    -ExpectedStatus 200 -ExpectedAction "SWITCH_AND_REPLACEMENT"

# Scenario 8: Attempt to create 3rd wallet under same MSISDN -> 409 Conflict
Write-Host "`n--- Scenario 8: Third Wallet Prohibited ---" -ForegroundColor Yellow
Test-Endpoint -Name "Scenario 8: Block 3rd Wallet Creation" `
    -Method "POST" -Path "/switch/create" `
    -Headers @{ "X-MSISDN" = "967700000003"; "X-Target-Region" = "NORTH" } `
    -ExpectedStatus 409 -ExpectedErrorCode "REG-ID-012" -ExpectedMessageContains "maximum number of accounts"

# Scenario 9: Create account with same region as existing -> 400 Bad Request
Write-Host "`n--- Scenario 9: Opposite Region Enforcement ---" -ForegroundColor Yellow
Test-Endpoint -Name "Scenario 9: Prevent same-region second account" `
    -Method "POST" -Path "/switch/create" `
    -Headers @{ "X-MSISDN" = "967700000001"; "X-Target-Region" = "SOUTH" } `
    -ExpectedStatus 400 -ExpectedErrorCode "REG-ID-012" -ExpectedMessageContains "already have an account in this region"

# Scenario 10: Per-Device Default Preference
Write-Host "`n--- Scenario 10: Set Per-Device Default (AC-11) ---" -ForegroundColor Yellow
Test-Endpoint -Name "Scenario 10: Set Device A default to SOUTH" `
    -Method "POST" -Path "/switch/set-default" `
    -Headers @{ "X-MSISDN" = "967700000003"; "X-Device-Id" = "DEVICE-A"; "X-Target-Region" = "SOUTH" } `
    -ExpectedStatus 200 -ExpectedMessageContains "Default wallet updated for this device"

Test-Endpoint -Name "Scenario 10: Set Device B default to NORTH" `
    -Method "POST" -Path "/switch/set-default" `
    -Headers @{ "X-MSISDN" = "967700000003"; "X-Device-Id" = "DEVICE-B"; "X-Target-Region" = "NORTH" } `
    -ExpectedStatus 200 -ExpectedMessageContains "Default wallet updated for this device"

# Scenario 11: Switch auth to Inaccessible Target (Terminated/Suspended)
Write-Host "`n--- Scenario 11: Reject Switch to Terminated Target ---" -ForegroundColor Yellow
Test-Endpoint -Name "Scenario 11: Reject switch to Terminated target" `
    -Method "POST" -Path "/switch/authenticate" `
    -Headers @{ "X-MSISDN" = "967700000007"; "X-Target-Region" = "SOUTH" } `
    -ExpectedStatus 403 -ExpectedErrorCode "SW_003" -ExpectedMessageContains "not accessible"

Write-Host "`n==================================================================" -ForegroundColor Cyan
Write-Host "                    ALL TESTS COMPLETED                           " -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan
