# 花妖桌宠 · Windows 独立版

适用 Windows 10 22H2 或 Windows 11 的 x64 电脑。下载 Release 中的 Windows ZIP，完整解压后双击 `HuaYaoPet.exe`。运行库已随包附带，启动时保留同目录下的文件和 `Pets` 文件夹。

- 右键人物可切换双人、花旦和小生，选择带缩略图的立绘，调节大小，开关花瓣、闲聊和置顶。
- 点击人物听台词，拖动人物可移动位置。任务栏通知区域里的花妖图标用于重新显示、移到右下角或退出。
- Harness 联动读取 `DSH_HOME\sessions`，未设置 `DSH_HOME` 时读取 `%USERPROFILE%\.dsh\sessions`。支持 v3/v4 压缩会话，跟踪最近写入的主会话；解压组件随包提供。待确认操作仍在 Harness 里完成。
- Windows 独立版首发提供 Harness 联动。macOS 独立版另有 Codex、WorkBuddy 和 TRAE 接入。

## 构建

需要 .NET 10 SDK。在项目根目录运行：

```powershell
dotnet publish WindowsPet/Desktop -c Release -r win-x64 --self-contained true -o pet-win-x64
```

读取器验证可运行 `dotnet run --project WindowsPet/ReaderSmoke -c Release`。
