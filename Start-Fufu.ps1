param([int]$Port = 17862)

& powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File (Join-Path $PSScriptRoot 'FufuDesktopPet.ps1') -Port $Port

