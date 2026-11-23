# 花妖桌宠

越剧《花妖》同人桌宠。双人模式可选 16 张合照，花旦有 13 款立绘，小生有 4 款。点人物会轻跳并回应，三个模式各自记住所选立绘。

## DeepSeek Harness 插件

1. 从 [插件 Release](https://github.com/giifft/huayao-harness-pet/releases/tag/v1.0.0) 下载 `huayao-harness-pet-1.0.0.tgz`。
2. 在 Harness 左侧打开「插件 → 添加插件」，粘贴 `.tgz` 文件的完整本地路径，安装后选择「立即启用」。
3. 回到聊天页，花妖会出现在 Harness 窗口右下角。点「立绘」可以选角色、换造型或开关花瓣。

这份插件包面向支持第三方插件安装的 macOS 和 Windows 版 Harness，使用当前会话的状态提示。在 Mac 上用 0.2.2-rc.5 的隔离环境验证了安装、启用和交互。Windows 桌面客户端还需实机验收。详细安装步骤见 Release 中的 PDF。

## 独立桌宠

独立版浮在系统桌面，可换立绘、点人物听台词、拖动、调大小和置顶。

| 系统 | 要求 | 使用方式 |
| --- | --- | --- |
| macOS | Apple 芯片，macOS 13 或更新 | 解压后打开「花妖桌宠.app」 |
| Windows | Windows 10 22H2 或 Windows 11，x64 | 完整解压后双击 `HuaYaoPet.exe` |

macOS 构建运行 `bash Scripts/build.sh`。Windows 构建和使用见 [WindowsPet](WindowsPet/README.md)。

Harness 插件的源码和打包说明见 [HarnessPlugin](HarnessPlugin/README.md)。
