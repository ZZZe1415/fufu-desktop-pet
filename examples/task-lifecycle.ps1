$petRoot = Split-Path -Parent $PSScriptRoot

& "$petRoot\Set-FufuState.ps1" -State working -Message '正在处理任务…'
Start-Sleep -Seconds 2

& "$petRoot\Set-FufuState.ps1" -State waiting -Message '请确认是否继续。'
Start-Sleep -Seconds 2

& "$petRoot\Set-FufuState.ps1" -State done -Message '任务完成啦！'

