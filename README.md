# 芙芙独立桌面宠物

这是一个不依赖 Electron 或 npm 的 Windows PowerShell/WPF 小程序。它直接使用芙芙的 **v2（8×11）图集**，并提供：透明置顶悬浮、拖拽定位、鼠标注视、点击互动、气泡提示、托盘菜单、状态持久化，以及仅绑定本机的任务状态 API。GitHub 版本会在首次启动时从 `assets/sprite-parts/` 自动还原图集 PNG。

## 启动

双击 `Start-Fufu.cmd`，或在 PowerShell 中执行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Start-Fufu.ps1
```

首次启动时，芙芙会显示在屏幕右下角。拖拽她移动；单击会挥手，双击会跳跃；右键可手动切换工作、等待、完成、复核和失败状态。

## 从任务或脚本触发

程序启动后会在 `127.0.0.1:17862` 开启仅本机可访问的 API：

```powershell
# 任务开始
.\Set-FufuState.ps1 -State running -Message '正在整理代码…'

# 等待你的确认
.\Set-FufuState.ps1 -State waiting -Message '需要你确认下一步。'

# 任务完成
.\Set-FufuState.ps1 -State done -Message '任务完成啦！'
```

也可以直接请求 API：

```powershell
Invoke-RestMethod http://127.0.0.1:17862/health
Invoke-RestMethod http://127.0.0.1:17862/state -Method Post -ContentType application/json -Body '{"state":"running","message":"正在工作"}'
Invoke-RestMethod 'http://127.0.0.1:17862/action?name=jumping&message=完成啦'
```

如果端口已被占用，`Set-FufuState.ps1` 会自动写入同目录的 `fufu-state.json`；正在运行的芙芙会轮询它。

## 状态映射

| 事件 | 动画 |
|---|---|
| `working` / `running` | 工作 |
| `thinking` / `review` | 复核 |
| `waiting` | 等待输入或批准 |
| `done` / `success` / `jumping` | 完成庆祝 |
| `blocked` / `failed` | 失败或受阻 |
| `start` / `waving` | 打招呼/提醒 |

它不会读取、上传或分析你的屏幕。若要自动连到某个编码代理，需要由该代理的 Hook、脚本或自动化在合适的生命周期调用 `Set-FufuState.ps1`；此版本不修改 Codex、Claude Code 或任何其他程序的配置文件。

## 自检

```powershell
.\FufuDesktopPet.ps1 -SmokeTest
```

预期会返回 `1536×2288`、9 个标准状态和 16 个 v2 注视单元的验证结果。

