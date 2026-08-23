[CmdletBinding()]
param(
    [int]$Port = 17862,
    [switch]$NoCursorLook,
    [switch]$SmokeTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

$script:Root = $PSScriptRoot
$script:AtlasPath = Join-Path $script:Root 'assets\fufu-spritesheet.png'
$script:AtlasPartsPath = Join-Path $script:Root 'assets\sprite-parts'
$script:StateFile = Join-Path $script:Root 'fufu-state.json'
$script:SettingsDir = Join-Path $env:LOCALAPPDATA 'FufuDesktopPet'
$script:SettingsPath = Join-Path $script:SettingsDir 'settings.json'
$script:FrameWidth = 192
$script:FrameHeight = 208
$script:ValidStates = @('idle', 'running-right', 'running-left', 'waving', 'jumping', 'failed', 'waiting', 'running', 'review')
$script:Animation = @{
    'idle'          = @{ Row = 0; Frames = 6; Interval = 180 }
    'running-right' = @{ Row = 1; Frames = 8; Interval = 90 }
    'running-left'  = @{ Row = 2; Frames = 8; Interval = 90 }
    'waving'        = @{ Row = 3; Frames = 4; Interval = 160 }
    'jumping'       = @{ Row = 4; Frames = 5; Interval = 115 }
    'failed'        = @{ Row = 5; Frames = 8; Interval = 140 }
    'waiting'       = @{ Row = 6; Frames = 6; Interval = 180 }
    'running'       = @{ Row = 7; Frames = 6; Interval = 120 }
    'review'        = @{ Row = 8; Frames = 6; Interval = 150 }
}
$script:StateAliases = @{
    'start' = 'waving'; 'remind' = 'waving'; 'success' = 'jumping'; 'done' = 'jumping';
    'complete' = 'jumping'; 'completed' = 'jumping'; 'working' = 'running';
    'thinking' = 'review'; 'needs-input' = 'waiting'; 'input' = 'waiting';
    'blocked' = 'failed'; 'error' = 'failed'; 'sleeping' = 'failed'
}
$script:PetState = 'idle'
$script:Frame = 0
$script:LastFrameAt = [DateTime]::UtcNow
$script:TransientUntil = $null
$script:TransientReturn = 'idle'
$script:BubbleUntil = [DateTime]::MinValue
$script:LastStateFileWrite = [DateTime]::MinValue
$script:LastSaved = [DateTime]::MinValue
$script:FrameCache = @{}
$script:HttpListener = $null
$script:HttpTask = $null

function ConvertTo-PetState {
    param([string]$State)
    if ([string]::IsNullOrWhiteSpace($State)) { return 'idle' }
    $candidate = $State.Trim().ToLowerInvariant()
    if ($script:StateAliases.ContainsKey($candidate)) { $candidate = $script:StateAliases[$candidate] }
    if ($script:ValidStates -contains $candidate) { return $candidate }
    return 'idle'
}

function Load-PetSettings {
    if (-not (Test-Path -LiteralPath $script:SettingsPath)) { return $null }
    try { return Get-Content -Raw -LiteralPath $script:SettingsPath | ConvertFrom-Json } catch { return $null }
}

function Save-PetSettings {
    if (-not (Test-Path -LiteralPath $script:SettingsDir)) {
        New-Item -ItemType Directory -Force -Path $script:SettingsDir | Out-Null
    }
    $payload = [ordered]@{ left = [math]::Round($script:Window.Left); top = [math]::Round($script:Window.Top); updatedAt = [DateTime]::UtcNow.ToString('o') }
    $payload | ConvertTo-Json | Set-Content -Encoding UTF8 -LiteralPath $script:SettingsPath
    $script:LastSaved = [DateTime]::UtcNow
}

function Set-PetState {
    param(
        [string]$State,
        [string]$Message,
        [int]$TransientSeconds = 0
    )
    $script:PetState = ConvertTo-PetState $State
    $script:Frame = 0
    $script:LastFrameAt = [DateTime]::UtcNow
    if ($TransientSeconds -gt 0) {
        $script:TransientReturn = 'idle'
        $script:TransientUntil = [DateTime]::UtcNow.AddSeconds($TransientSeconds)
    } else {
        $script:TransientUntil = $null
    }
    if (-not [string]::IsNullOrWhiteSpace($Message)) { Show-Bubble -Text $Message }
}

function Show-Bubble {
    param([string]$Text, [int]$Seconds = 5)
    $script:BubbleText.Text = $Text
    $script:Bubble.Visibility = 'Visible'
    $script:BubbleUntil = [DateTime]::UtcNow.AddSeconds($Seconds)
}

function Get-CroppedFrame {
    param([int]$Row, [int]$Column)
    $key = "$Row,$Column"
    if (-not $script:FrameCache.ContainsKey($key)) {
        $rect = New-Object System.Windows.Int32Rect ($Column * $script:FrameWidth), ($Row * $script:FrameHeight), $script:FrameWidth, $script:FrameHeight
        $crop = New-Object System.Windows.Media.Imaging.CroppedBitmap $script:Atlas, $rect
        $crop.Freeze()
        $script:FrameCache[$key] = $crop
    }
    return $script:FrameCache[$key]
}

function Get-LookDirection {
    $cursor = [System.Windows.Forms.Cursor]::Position
    $originX = $script:Window.Left + ($script:PetImage.Width / 2)
    $originY = $script:Window.Top + 170
    $dx = $cursor.X - $originX
    $dy = $cursor.Y - $originY
    if ([math]::Sqrt(($dx * $dx) + ($dy * $dy)) -lt 90) { return $null }
    $degrees = (([math]::Atan2($dx, -$dy) * 180 / [math]::PI) + 360) % 360
    return [int]([math]::Round($degrees / 22.5) % 16)
}

function Update-Sprite {
    $now = [DateTime]::UtcNow
    if ($script:TransientUntil -and $now -gt $script:TransientUntil) {
        $script:PetState = $script:TransientReturn
        $script:TransientUntil = $null
        $script:Frame = 0
    }
    if ($script:Bubble.Visibility -eq 'Visible' -and $now -gt $script:BubbleUntil) { $script:Bubble.Visibility = 'Collapsed' }

    if ($script:PetState -eq 'idle' -and -not $NoCursorLook) {
        $direction = Get-LookDirection
        if ($null -ne $direction) {
            $row = if ($direction -lt 8) { 9 } else { 10 }
            $column = $direction % 8
            $script:PetImage.Source = Get-CroppedFrame -Row $row -Column $column
            return
        }
    }

    $definition = $script:Animation[$script:PetState]
    if (($now - $script:LastFrameAt).TotalMilliseconds -ge $definition.Interval) {
        $script:Frame = ($script:Frame + 1) % $definition.Frames
        $script:LastFrameAt = $now
    }
    $script:PetImage.Source = Get-CroppedFrame -Row $definition.Row -Column $script:Frame
}

function Write-JsonResponse {
    param($Context, [int]$StatusCode, $Payload)
    $json = $Payload | ConvertTo-Json -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = 'application/json; charset=utf-8'
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.Close()
}

function Process-HttpRequest {
    param($Context)
    try {
        $request = $Context.Request
        $path = $request.Url.AbsolutePath.ToLowerInvariant()
        $data = @{}
        foreach ($key in $request.QueryString.AllKeys) { if ($key) { $data[$key] = $request.QueryString[$key] } }
        if ($request.HasEntityBody) {
            $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
            $body = $reader.ReadToEnd(); $reader.Dispose()
            if ($body) {
                try { $json = $body | ConvertFrom-Json; $json.PSObject.Properties | ForEach-Object { $data[$_.Name] = [string]$_.Value } } catch { }
            }
        }
        switch ($path) {
            '/health' { Write-JsonResponse $Context 200 @{ ok = $true; name = 'fufu-desktop-pet'; state = $script:PetState; port = $Port }; return }
            '/state' {
                if ($request.HttpMethod -eq 'GET' -and -not $data.ContainsKey('state')) {
                    Write-JsonResponse $Context 200 @{ ok = $true; state = $script:PetState }; return
                }
                $state = if ($data.ContainsKey('state')) { $data['state'] } else { 'idle' }
                $message = if ($data.ContainsKey('message')) { $data['message'] } else { '' }
                Set-PetState -State $state -Message $message
                Write-JsonResponse $Context 200 @{ ok = $true; state = $script:PetState }; return
            }
            '/action' {
                $action = if ($data.ContainsKey('name')) { $data['name'] } elseif ($data.ContainsKey('action')) { $data['action'] } else { 'waving' }
                Set-PetState -State $action -Message (if ($data.ContainsKey('message')) { $data['message'] } else { '' }) -TransientSeconds 3
                Write-JsonResponse $Context 200 @{ ok = $true; state = $script:PetState }; return
            }
            default { Write-JsonResponse $Context 404 @{ ok = $false; error = 'Use /health, /state, or /action.' }; return }
        }
    } catch {
        try { Write-JsonResponse $Context 500 @{ ok = $false; error = $_.Exception.Message } } catch { }
    }
}

function Start-LocalApi {
    try {
        $script:HttpListener = New-Object System.Net.HttpListener
        $script:HttpListener.Prefixes.Add("http://127.0.0.1:$Port/")
        $script:HttpListener.Start()
        $script:HttpTask = $script:HttpListener.BeginGetContext($null, $null)
        return $true
    } catch {
        $script:HttpListener = $null
        return $false
    }
}

function Poll-LocalApi {
    if ($script:HttpTask -and $script:HttpTask.IsCompleted) {
        try { $context = $script:HttpListener.EndGetContext($script:HttpTask); Process-HttpRequest $context } catch { }
        if ($script:HttpListener -and $script:HttpListener.IsListening) { $script:HttpTask = $script:HttpListener.BeginGetContext($null, $null) }
    }
}

function Poll-StateFile {
    if (-not (Test-Path -LiteralPath $script:StateFile)) { return }
    try {
        $item = Get-Item -LiteralPath $script:StateFile
        if ($item.LastWriteTimeUtc -le $script:LastStateFileWrite) { return }
        $stateData = Get-Content -Raw -LiteralPath $script:StateFile | ConvertFrom-Json
        Set-PetState -State $stateData.state -Message $stateData.message
        $script:LastStateFileWrite = $item.LastWriteTimeUtc
    } catch { }
}

if (-not (Test-Path -LiteralPath $script:AtlasPath) -and (Test-Path -LiteralPath $script:AtlasPartsPath)) {
    $parts = Get-ChildItem -LiteralPath $script:AtlasPartsPath -Filter '*.b64' | Sort-Object Name
    if ($parts.Count -gt 0) {
        $base64 = [string]::Concat([string[]]($parts | ForEach-Object { [IO.File]::ReadAllText($_.FullName).Trim() }))
        [IO.File]::WriteAllBytes($script:AtlasPath, [Convert]::FromBase64String($base64))
    }
}
if (-not (Test-Path -LiteralPath $script:AtlasPath)) { throw "Fufu spritesheet was not found: $script:AtlasPath" }
$stream = New-Object System.IO.FileStream($script:AtlasPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read)
$script:Atlas = New-Object System.Windows.Media.Imaging.BitmapImage
$script:Atlas.BeginInit(); $script:Atlas.CacheOption = 'OnLoad'; $script:Atlas.StreamSource = $stream; $script:Atlas.EndInit(); $script:Atlas.Freeze(); $stream.Dispose()

if ($SmokeTest) {
    [ordered]@{ ok = ($script:Atlas.PixelWidth -eq 1536 -and $script:Atlas.PixelHeight -eq 2288); width = $script:Atlas.PixelWidth; height = $script:Atlas.PixelHeight; states = $script:ValidStates; v2LookCells = 16 } | ConvertTo-Json
    exit 0
}

$settings = Load-PetSettings
$script:Window = New-Object System.Windows.Window
$script:Window.Title = 'Fufu Desktop Pet'
$script:Window.Width = 260; $script:Window.Height = 310
$script:Window.WindowStyle = 'None'; $script:Window.ResizeMode = 'NoResize'; $script:Window.AllowsTransparency = $true
$script:Window.Background = [System.Windows.Media.Brushes]::Transparent; $script:Window.Topmost = $true; $script:Window.ShowInTaskbar = $false
$script:Window.Left = if ($settings -and $null -ne $settings.left) { [double]$settings.left } else { [System.Windows.SystemParameters]::WorkArea.Right - 300 }
$script:Window.Top = if ($settings -and $null -ne $settings.top) { [double]$settings.top } else { [System.Windows.SystemParameters]::WorkArea.Bottom - 350 }

$grid = New-Object System.Windows.Controls.Grid
$rowBubble = New-Object System.Windows.Controls.RowDefinition; $rowBubble.Height = 'Auto'
$rowPet = New-Object System.Windows.Controls.RowDefinition; $rowPet.Height = '*'
$grid.RowDefinitions.Add($rowBubble); $grid.RowDefinitions.Add($rowPet)

$script:Bubble = New-Object System.Windows.Controls.Border
$script:Bubble.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#EE142341')
$script:Bubble.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#AAB8D9FF')
$script:Bubble.BorderThickness = '1'; $script:Bubble.CornerRadius = '14'; $script:Bubble.Padding = '12,8,12,8'; $script:Bubble.Margin = '12,8,12,0'; $script:Bubble.Visibility = 'Collapsed'; $script:Bubble.IsHitTestVisible = $false
$script:BubbleText = New-Object System.Windows.Controls.TextBlock
$script:BubbleText.Foreground = [System.Windows.Media.Brushes]::White; $script:BubbleText.TextWrapping = 'Wrap'; $script:BubbleText.TextAlignment = 'Center'; $script:BubbleText.FontSize = 13
$script:Bubble.Child = $script:BubbleText
[System.Windows.Controls.Grid]::SetRow($script:Bubble, 0); $grid.Children.Add($script:Bubble)

$script:PetImage = New-Object System.Windows.Controls.Image
$script:PetImage.Width = 246; $script:PetImage.Height = 267; $script:PetImage.Stretch = 'Uniform'; $script:PetImage.HorizontalAlignment = 'Center'; $script:PetImage.VerticalAlignment = 'Bottom'; $script:PetImage.Cursor = [System.Windows.Input.Cursors]::Hand
[System.Windows.Controls.Grid]::SetRow($script:PetImage, 1); $grid.Children.Add($script:PetImage)
$script:Window.Content = $grid

$menu = New-Object System.Windows.Controls.ContextMenu
foreach ($entry in @(@('Idle', 'idle'), @('Working', 'running'), @('Needs input', 'waiting'), @('Celebrate', 'jumping'), @('Reviewing', 'review'), @('Blocked', 'failed'))) {
    $item = New-Object System.Windows.Controls.MenuItem; $item.Header = $entry[0]; $stateForItem = $entry[1]
    $transientForItem = if ($stateForItem -in @('jumping','waving')) { 3 } else { 0 }
    $item.Tag = @{ state = $stateForItem; seconds = $transientForItem }
    $item.Add_Click({ param($sender, $event); Set-PetState -State $sender.Tag.state -Message '' -TransientSeconds $sender.Tag.seconds })
    $menu.Items.Add($item) | Out-Null
}
$menu.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null
$quitItem = New-Object System.Windows.Controls.MenuItem; $quitItem.Header = 'Quit Fufu'; $quitItem.Add_Click({ $script:Window.Close() }); $menu.Items.Add($quitItem) | Out-Null
$grid.ContextMenu = $menu

$script:Dragging = $false; $script:DragStart = $null; $script:WindowStart = $null
$script:PetImage.Add_MouseLeftButtonDown({
    param($sender, $event)
    if ($event.ClickCount -ge 2) { Set-PetState -State 'jumping' -Message 'Yay! Let us celebrate.' -TransientSeconds 3; return }
    $script:Dragging = $true; $script:DragStart = $event.GetPosition($null); $script:WindowStart = [System.Windows.Point]::new($script:Window.Left, $script:Window.Top); $sender.CaptureMouse(); $event.Handled = $true
})
$script:PetImage.Add_MouseMove({
    param($sender, $event)
    if (-not $script:Dragging) { return }
    $now = $event.GetPosition($null); $script:Window.Left = $script:WindowStart.X + ($now.X - $script:DragStart.X); $script:Window.Top = $script:WindowStart.Y + ($now.Y - $script:DragStart.Y)
})
$script:PetImage.Add_MouseLeftButtonUp({
    param($sender, $event)
    if (-not $script:Dragging) { return }
    $now = $event.GetPosition($null); $distance = [math]::Abs($now.X - $script:DragStart.X) + [math]::Abs($now.Y - $script:DragStart.Y)
    $script:Dragging = $false; $sender.ReleaseMouseCapture()
    if ($distance -lt 8) { Set-PetState -State 'waving' -Message 'Hello! Right-click me to change my state.' -TransientSeconds 3 }
})

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = [System.Drawing.SystemIcons]::Information; $tray.Text = 'Fufu Desktop Pet'; $tray.Visible = $true
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$showHide = $trayMenu.Items.Add('Show / hide'); $showHide.Add_Click({ if ($script:Window.IsVisible) { $script:Window.Hide() } else { $script:Window.Show(); $script:Window.Activate() } })
$trayDone = $trayMenu.Items.Add('Celebrate'); $trayDone.Add_Click({ Set-PetState -State 'jumping' -Message 'Task complete!' -TransientSeconds 3 })
$trayQuit = $trayMenu.Items.Add('Quit'); $trayQuit.Add_Click({ $script:Window.Close() })
$tray.ContextMenuStrip = $trayMenu
$tray.Add_DoubleClick({ $script:Window.Show(); $script:Window.Activate() })

$apiStarted = Start-LocalApi
if ($apiStarted) { Show-Bubble -Text "Fufu is ready. Local API: 127.0.0.1:$Port" -Seconds 4 } else { Show-Bubble -Text 'Fufu is ready. The local API port is unavailable; state-file control still works.' -Seconds 5 }

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(60)
$timer.Add_Tick({
    Poll-LocalApi; Poll-StateFile; Update-Sprite
    if (([DateTime]::UtcNow - $script:LastSaved).TotalSeconds -ge 8) { Save-PetSettings }
})
$timer.Start()
$script:Window.Add_Closing({
    $timer.Stop(); Save-PetSettings
    if ($script:HttpListener) { try { $script:HttpListener.Stop(); $script:HttpListener.Close() } catch { } }
    $tray.Visible = $false; $tray.Dispose()
})

Update-Sprite
$script:Window.ShowDialog() | Out-Null

