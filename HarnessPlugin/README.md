# 花妖桌宠 · DeepSeek Harness 插件

越剧《花妖》同人桌宠。使用 Harness 的窗口内浮层，支持双人合照 16 款、花旦单人 13 款和小生单人 4 款。点击立绘会回应一句，三种模式各自记住所选立绘。点「立绘」选角色、造型或开关花瓣，点「收起」可缩成状态按钮。

插件跟随当前 Harness 会话，显示思考、调用工具、待确认、完成等状态。待确认时仍在 Harness 原有界面操作。立绘随包提供，设置保存在本机，插件没有额外网络服务。

## 安装或启用

1. 在电脑上保存 `huayao-harness-pet-1.0.0.tgz`，保留压缩包。
2. 打开支持第三方插件的 DeepSeek Harness 桌面版，在左侧进入「插件」，选择「添加插件」或「安装第三方插件」。
3. 在包名输入框中粘贴压缩包的**完整本地路径**。macOS 示例为 `/Users/你的用户名/Downloads/huayao-harness-pet-1.0.0.tgz`，Windows 示例为 `C:\Users\你的用户名\Downloads\huayao-harness-pet-1.0.0.tgz`。把示例路径换为你的实际路径。
4. 确认预览里的包名为 `huayao-harness-pet`，安装后选择「立即启用」。若 Harness 提示重启，在重启后继续。
5. 回到聊天页，查看 Harness 窗口右下角。停用或卸载通过同一个「插件」页面操作。

两端使用同一个插件包。插件按 Harness 0.2.2-rc.5 的客户端扩展接口开发，需能安装第三方组合包的 0.2.2 系列桌面版。窗口外的 macOS 原生独立桌宠有自己的安装包。

## 从源码打包

在本项目根目录运行 `bash HarnessPlugin/scripts/build.sh`。需要 Node.js/npm、Python 3 和 Pillow。
