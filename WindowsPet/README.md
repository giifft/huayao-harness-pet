# 花妖桌宠 · Windows 独立版

适用 Windows 10 22H2 或 Windows 11 的 x64 电脑。下载 Release 中的 Windows ZIP，完整解压后双击 `HuaYaoPet.exe`。运行库已随包附带，启动时保留同目录下的文件和 `Pets` 文件夹。

- 右键人物可切换双人、花旦和小生，选择带缩略图的 Q 版立绘，调节大小，开关花瓣、闲聊和置顶。
- 点击人物看台词，拖动人物可移动位置。右键「交互设置…」可配置四边吸附、单人贴左镜像、状态换姿、分事件音量和自定义气泡。任务栏通知区域里的花妖图标用于重新显示、打开任务和用量面板或退出。
- Harness 联动读取 `DSH_HOME\sessions`，未设置 `DSH_HOME` 时读取 `%USERPROFILE%\.dsh\sessions`。支持 v3/v4 压缩会话。Codex 与 WorkBuddy 的本地任务也可在「项目与任务」查看，操作仍在相应应用中完成。
- 「用量与余额…」显示 Harness 用量估算、DeepSeek 余额和峰谷价时段。查询余额时需自行填入 DeepSeek API 密钥，密钥由 Windows 凭据管理器保存。
- TRAE 和 Antigravity 通过菜单配置或移除 Hooks，豆包联动需单独开启。这些接入已经编译，实际效果取决于安装的 Windows 客户端版本与可访问接口。

## 构建

需要 .NET 10 SDK。在项目根目录运行：

```powershell
dotnet publish WindowsPet/Desktop -c Release -r win-x64 --self-contained true -o pet-win-x64
```

读取器验证可运行 `dotnet run --project WindowsPet/ReaderSmoke -c Release`。

## 饭制声明与立绘使用

本桌宠为越剧《花妖》饭制作品。本案立绘与人物形象不对外授权，禁止商用，仅作越剧《花妖》宣传之用，无商业用途。

二创产生的一切衍生权益归越剧《花妖》出品人李旭丹女士所有。
