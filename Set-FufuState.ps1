[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('idle','running','review','waiting','failed','jumping','waving','done','success','working','thinking','blocked')]
    [string]$State,
    [string]$Message = '',
    [int]$Port = 17862
)

$payload = @{ state = $State; message = $Message } | ConvertTo-Json -Compress
try {
    Invoke-RestMethod -Uri "http://127.0.0.1:$Port/state" -Method Post -ContentType 'application/json' -Body $payload -TimeoutSec 2 | ConvertTo-Json -Compress
} catch {
    $fallback = Join-Path $PSScriptRoot 'fufu-state.json'
    $payload | Set-Content -Encoding UTF8 -LiteralPath $fallback
    '{"ok":true,"transport":"state-file"}'
}

