<div align="center">
  <img src="Resources/Pets/duo_D09.png" width="190" alt="花妖桌宠 Q 版双人立绘，执手对望">
  <h1>花妖桌宠 · Hua Yao Pet</h1>
  <p>把越剧《花妖》的花旦和小生请到桌面。点一下，轻跳一下，再听她们说句话。</p>
</div>

<p align="center">
  <a href="LICENSE"><img alt="代码许可 MIT" src="https://img.shields.io/badge/Code%20License-MIT-yellow"></a>
  <a href="NOTICE-ARTWORK.zh-CN.txt"><img alt="立绘不对外授权，禁止商用" src="https://img.shields.io/badge/Artwork-Promotion%20Only-8c4355"></a>
  <a href="https://github.com/giifft/huayao-harness-pet/releases/tag/v1.3.0"><img alt="macOS 独立版 v1.3.0" src="https://img.shields.io/badge/macOS-v1.3.0-446d62"></a>
  <a href="https://github.com/giifft/huayao-harness-pet/releases/tag/v1.3.0"><img alt="Windows 独立版 v1.1.0" src="https://img.shields.io/badge/Windows-v1.1.0-3575ad"></a>
  <a href="https://github.com/giifft/huayao-harness-pet/releases/tag/v1.3.0"><img alt="Harness 插件 v1.2.0" src="https://img.shields.io/badge/Harness%20Plugin-v1.2.0-8c4355"></a>
  <a href="https://github.com/giifft/huayao-harness-pet/actions/workflows/windows-pet.yml"><img alt="Windows 自动启动测试" src="https://github.com/giifft/huayao-harness-pet/actions/workflows/windows-pet.yml/badge.svg?branch=main"></a>
</p>

<p align="center">
  <a href="#桌宠预览">桌宠预览</a> ·
  <a href="#下载与安装">下载与安装</a> ·
  <a href="#关于越剧花妖">剧目与主创</a> ·
  <a href="#代码许可与立绘使用">代码许可与立绘使用</a>
</p>

> **越剧《花妖》饭制作品。** MIT 许可仅适用于本项目的自有软件代码与构建文件。立绘与人物形象不对外授权，禁止商用，仅作越剧《花妖》宣传之用。

## 桌宠预览

<p align="center">
  <img src="docs/screenshots/macos-desktop.png" width="235" alt="macOS 花妖桌宠，Q 版执手对望">
</p>

## 桌宠能做什么

| 玩法 | 说明 |
| --- | --- |
| **三种角色模式** | 内置 21 款双人、13 款花旦和 4 款小生 Q 版立绘。可以按缩略图挑选，三个模式各自记住上次使用的造型。 |
| **点击回话与花瓣** | 点人物会轻跳一下并弹出台词。花瓣可以关闭，独立版还可开关自动闲聊。 |
| **摆放桌面** | 独立版支持四边吸附，可分别设置吸附距离。可以拖动、记住位置、缩放、置顶、隐藏和唤回。可选贴左镜像仅用于单人造型。 |
| **AI 状态提醒** | 独立版有任务列表、最近结果和清空任务状态。桌宠可根据思考、工作、待回答或待授权临时换姿，保留原选立绘。点击、每轮结束、提问与授权音效可分别设置开关和音量。 |
| **自定义气泡** | 独立版支持编辑点击、待机、提问、授权、结算、余额预警和预算提醒的气泡，可逐类配图。「暗暗度良宵」只在双人模式出现。 |
| **用量与余额** | 独立版显示 Harness 对话用量估算、每轮费用、DeepSeek 余额、每日预算、峰谷价倒计时和观测账本。 |
| **Harness 窗口内玩法** | 从 Harness 的插件页安装和停用，跟随当前会话。还支持拖动记位、状态换姿、花台陪伴和本地存档。 |

### 三个版本怎么选

| 版本 | 显示位置 | 支持的联动 |
| --- | --- | --- |
| **macOS 独立版** | 系统桌面 | DeepSeek Harness、Codex、WorkBuddy、TRAE、Google Antigravity 和豆包。 |
| **Windows 独立版** | 系统桌面 | DeepSeek Harness、Codex、WorkBuddy。另提供 TRAE、Google Antigravity 和豆包接入入口，需在相应 Windows 客户端验证。 |
| **DeepSeek Harness 插件** | Harness 窗口右下角 | 当前 Harness 会话。同一个插件包面向 macOS 和 Windows。 |

两端常规联动读取 Codex 和 Harness 的本地会话日志及 WorkBuddy 本地任务状态，可按平台关闭。TRAE 和 Antigravity 需要先在菜单配置 Hooks，卸载前可用菜单移除花妖添加的 Hooks。豆包联动默认关闭。

右键选择「用量与余额…」可填写 DeepSeek API 密钥。macOS 使用钥匙串，Windows 使用凭据管理器，桌宠每 60 秒查询 DeepSeek 官方余额接口。余额账本只统计实际观测到的区间，可按到账与其他扣减校正。Harness 费用按本机仍保留的日志中记录的 token 用量及对应时段的公开单价估算。没有匹配单价的轮次单独提示；余额观测和用量估算各自显示。[DeepSeek 计费说明](https://api-docs.deepseek.com/zh-cn/quick_start/pricing)

## 下载与安装

| 版本 | 系统或应用要求 | 下载 |
| --- | --- | --- |
| **Windows 独立版 v1.1.0** | Windows 10 22H2 或 Windows 11，x64 | [Windows ZIP](https://github.com/giifft/huayao-harness-pet/releases/download/v1.3.0/huayao-desktop-windows-x64.zip) |
| **macOS 独立版 v1.3.0** | Apple 芯片，macOS 13 或更新 | [macOS ZIP](https://github.com/giifft/huayao-harness-pet/releases/download/v1.3.0/huayao-desktop-macos-arm64.zip) |
| **Harness 插件 v1.2.0** | 支持安装第三方插件的 DeepSeek Harness | [插件 TGZ](https://github.com/giifft/huayao-harness-pet/releases/download/v1.3.0/huayao-harness-pet-1.2.0.tgz) |

1. **Windows**　完整解压 ZIP，打开 `HuaYaoPet-Windows-x64` 文件夹并双击 `HuaYaoPet.exe`。把 EXE 和同目录的文件一并保留。
2. **macOS**　解压 ZIP，把「花妖桌宠.app」拖到「应用程序」后打开。顶部菜单栏的戏曲面具图标可以打开菜单。
3. **Harness 插件**　在 Harness 左侧打开「插件 → 添加插件」，粘贴 `.tgz` 的完整本地路径。安装后点「立即启用」，再回到聊天页。

Windows 安装包为自包含构建，未做数字签名。macOS 安装包适用于 Apple 芯片，未做 Apple 公证。Harness 插件支持可安装第三方插件的 0.2.2 系列桌面版。

macOS 首次打开若遇到 Gatekeeper 拦截，确认文件来自本项目的 Release 后，可以在「系统设置 → 隐私与安全性」里为该应用选择「仍要打开」。

## 关于越剧《花妖》

越剧《花妖》取材于蒲松龄《聊斋志异·香玉》。黄生与花妖香玉、绛雪相遇，故事由相知写到离别与守候。李旭丹饰香玉、绛雪，王婉娜饰黄生。

### 主创团队

| 职务 | 主创 |
| --- | --- |
| 出品人／制作人 | 李旭丹 |
| 艺术指导 | 王志萍 |
| 主演 | 李旭丹 饰 香玉／绛雪，王婉娜 饰 黄生 |
| 编剧 | 魏睿 |
| 导演／舞美设计／平面设计／多媒体设计 | 朱燕鸣 |
| 副导演 | 牟元笛 |
| 影像导演 | 杨君武 |
| 唱腔设计 | 黄莺 |
| 作曲／编曲 | 蒋笑、刘星羽 |
| 伴奏制作／编曲 | 江君亮 |
| 灯光设计 | 缪伟 |
| 造型设计 | 蒋沁颖 |
| 服装设计 | 李旭丹 |
| 服装制作 | 庞丽丽（绍兴市兰曦秀服饰设计有限公司） |
| 摄影 | 张予希、俞旭紊、余秀鹏 |

### 演出与购票信息

- 时间　2026 年 12 月 12 日至 13 日，每晚 19:15
- 地点　上海长江剧场·黑匣子
- 票价　280 元／380 元

## 源码与版本记录

| 部分 | 路径 | 构建 |
| --- | --- | --- |
| macOS 独立版（Swift／AppKit） | [Sources/HuaYaoPet](Sources/HuaYaoPet) | `bash Scripts/build.sh` |
| Windows 独立版（.NET／WPF） | [WindowsPet](WindowsPet/README.md) | `dotnet publish WindowsPet/Desktop -c Release -r win-x64 --self-contained true` |
| Harness 插件（React／Cordis） | [HarnessPlugin](HarnessPlugin/README.md) | `bash HarnessPlugin/scripts/build.sh` |

macOS 构建需要 Xcode 命令行工具，测试还需要 `zstd`。构建后运行 `bash Scripts/test-macos.sh`，可验证并行会话、清空状态、Hooks 和 Harness 用量。Windows 读取器测试和运行要求见 [Windows 版说明](WindowsPet/README.md)。

macOS 版支持豆包桌面端联动，覆盖当前窗口里的普通对话。豆包联动默认关闭。在花妖桌宠菜单单独开启「AI 联动 → 豆包」，并在 macOS「系统设置 → 隐私与安全性 → 辅助功能」为花妖桌宠授权。桌宠仅在豆包位于前台时读取普通对话的可访问文本。回复连续更新时，桌宠会提示正在回话，停止更新约 7 秒后回到空闲。聊天文本仅在本地内存中用于比对变化。短回复可能在轮询间隔内结束，因此可能跳过正在回话的提示。

macOS 版的 Antigravity 联动通过 [Google Hooks](https://antigravity.google/docs/hooks) 按会话显示工作区、工具类别和执行结果。首次使用请选「AI 联动 → 配置 Antigravity 联动」，然后在 Antigravity 中运行一项任务。花妖只在本机保存会话标识、目录名、时间和状态。移动桌宠应用后需要重新配置。可用同一菜单移除花妖的 Hooks。

[当前版本 Release](https://github.com/giifft/huayao-harness-pet/releases/tag/v1.3.0) 提供 macOS v1.3.0、Windows v1.1.0 和 Harness 插件 v1.2.0。

## 代码许可与立绘使用

项目自有软件代码和构建文件采用 MIT 许可，第三方组件沿用各自许可。[MIT LICENSE](LICENSE)

本桌宠为越剧《花妖》饭制作品。本案立绘与人物形象不对外授权，禁止商用，仅作越剧《花妖》宣传之用，无商业用途。二创产生的一切衍生权益归越剧《花妖》出品人李旭丹女士所有。[立绘使用声明](NOTICE-ARTWORK.zh-CN.txt)
