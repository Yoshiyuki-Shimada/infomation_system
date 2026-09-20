param(
    [Parameter(Mandatory = $true)]
    [string]$CredentialsPath,
    [string]$CalendarId = "primary"
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function ConvertTo-Base64Url {
    param([byte[]]$Bytes)
    return [Convert]::ToBase64String($Bytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
}

function Protect-PlainTextValue {
    param([Parameter(Mandatory = $true)][string]$Value)
    return ConvertTo-SecureString -String $Value -AsPlainText -Force | ConvertFrom-SecureString
}

$resolvedCredentialsPath = (Resolve-Path -LiteralPath $CredentialsPath).Path
$credentials = Get-Content -LiteralPath $resolvedCredentialsPath -Raw -Encoding UTF8 | ConvertFrom-Json
$installedProperty = $credentials.PSObject.Properties["installed"]
$webProperty = $credentials.PSObject.Properties["web"]
$client = if ($installedProperty) { $installedProperty.Value } elseif ($webProperty) { $webProperty.Value } else { $null }
if (-not $client.client_id -or -not $client.client_secret) {
    throw "Google Cloudのデスクトップアプリ用OAuthクライアントJSONを指定してください。"
}

$port = Get-Random -Minimum 49152 -Maximum 65535
$redirectUri = "http://127.0.0.1:$port/"
$stateBytes = New-Object byte[] 32
$verifierBytes = New-Object byte[] 48
$random = [Security.Cryptography.RandomNumberGenerator]::Create()
$random.GetBytes($stateBytes)
$random.GetBytes($verifierBytes)
$random.Dispose()
$state = ConvertTo-Base64Url $stateBytes
$codeVerifier = ConvertTo-Base64Url $verifierBytes
$sha256 = [Security.Cryptography.SHA256]::Create()
$codeChallenge = ConvertTo-Base64Url ($sha256.ComputeHash([Text.Encoding]::ASCII.GetBytes($codeVerifier)))
$sha256.Dispose()
$scope = "https://www.googleapis.com/auth/calendar.events.readonly"

$query = @{
    client_id              = [string]$client.client_id
    redirect_uri           = $redirectUri
    response_type          = "code"
    scope                  = $scope
    access_type            = "offline"
    prompt                 = "consent"
    include_granted_scopes = "true"
    state                  = $state
    code_challenge         = $codeChallenge
    code_challenge_method  = "S256"
}
$queryText = ($query.GetEnumerator() | ForEach-Object {
    "{0}={1}" -f [Uri]::EscapeDataString([string]$_.Key), [Uri]::EscapeDataString([string]$_.Value)
}) -join "&"
$authorizationUri = "https://accounts.google.com/o/oauth2/v2/auth?$queryText"

$listener = New-Object Net.HttpListener
$listener.Prefixes.Add($redirectUri)
$listener.Start()
try {
    Start-Process $authorizationUri
    Write-Host "ブラウザでGoogleカレンダーの読み取りを許可してください。" -ForegroundColor Cyan
    $context = $listener.GetContext()
    $request = $context.Request
    $response = $context.Response
    $responseText = "認証が完了しました。この画面を閉じてください。"
    $responseBytes = [Text.Encoding]::UTF8.GetBytes($responseText)
    $response.ContentType = "text/plain; charset=utf-8"
    $response.ContentLength64 = $responseBytes.Length
    $response.OutputStream.Write($responseBytes, 0, $responseBytes.Length)
    $response.OutputStream.Close()

    if ($request.QueryString["state"] -ne $state) {
        throw "OAuth応答のstateが一致しません。"
    }
    if ($request.QueryString["error"]) {
        throw "Google認証が拒否されました: $($request.QueryString['error'])"
    }
    $authorizationCode = $request.QueryString["code"]
    if (-not $authorizationCode) {
        throw "Google認証コードを取得できませんでした。"
    }

    $token = Invoke-RestMethod -Method Post -Uri "https://oauth2.googleapis.com/token" -ContentType "application/x-www-form-urlencoded" -Body @{
        client_id     = [string]$client.client_id
        client_secret = [string]$client.client_secret
        code          = $authorizationCode
        code_verifier = $codeVerifier
        grant_type    = "authorization_code"
        redirect_uri  = $redirectUri
    } -TimeoutSec 30
    if (-not $token.refresh_token) {
        throw "更新トークンを取得できませんでした。Googleアカウントの許可を取り消して再実行してください。"
    }

    $rootDir = Split-Path -Path $PSScriptRoot -Parent
    $runtimeDir = Join-Path $rootDir "database\runtime"
    $configPath = Join-Path $runtimeDir "google_calendar_auth.json"
    New-Item -Path $runtimeDir -ItemType Directory -Force | Out-Null
    $config = [ordered]@{
        clientId              = [string]$client.client_id
        clientSecretProtected = Protect-PlainTextValue ([string]$client.client_secret)
        refreshTokenProtected = Protect-PlainTextValue ([string]$token.refresh_token)
        calendarId            = $CalendarId
        scope                 = $scope
        configuredAt          = (Get-Date -Format "yyyy/MM/dd HH:mm:ss")
    }
    $config | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
    Write-Host "Google Calendarの認証設定を保存しました: $configPath" -ForegroundColor Green
}
finally {
    $listener.Stop()
    $listener.Close()
}
