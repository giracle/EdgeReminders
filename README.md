# 浮光提醒 · EdgeReminders

浮光提醒是一款原生 macOS 提醒事项应用。拖动浮窗靠近屏幕四边，松手后它会伴着水波收起。把鼠标停在任意可用屏幕边缘，待办会从指针附近展开。

## 功能

- **四边浮窗**。自由拖动、贴边提示、完全隐藏和悬停唤出。菜单栏也可以随时显示或收起浮窗。
- **Apple 提醒事项**。授权后可查看和编辑已有清单中的事项。iCloud 清单继续通过 Apple 的账户同步，提醒由系统「提醒事项」发出。
- **本机清单**。在这台 Mac 上创建自己的清单，安排日期、时间与重复提醒。浮窗可一起显示两类事项，管理窗口还支持搜索与恢复已完成事项。
- **玻璃与水波**。macOS 26 及更高版本使用原生 Liquid Glass，macOS 15 使用系统半透明材质。玻璃层的动效与任务文字分开绘制，并遵循系统「减少动态效果」设置。

## 安装与使用

需要 **macOS 15 或更高版本**。通用版同时支持 Apple 芯片和 Intel Mac。

1. 在 [GitHub Releases](https://github.com/giracle/EdgeReminders/releases) 下载 `EdgeReminders-0.1.0-macOS-universal.dmg`。
2. 打开 DMG，把 `EdgeReminders.app` 拖到「应用程序」，再从「应用程序」打开。
3. 点击菜单栏中的浮光提醒图标，选择「管理清单…」。要访问已有的 Apple 提醒事项，点击「连接 Apple 提醒事项」并授予完全访问权限。使用本机定时提醒时，在系统提示中允许通知。

`v0.1.0` 是测试版，使用临时签名，尚未经过 Apple 公证。macOS 可能拦截从网上下载的安装包。下载时可用随附的 `.sha256` 核对镜像。

当前已在 macOS 15.7.4 上构建并运行，macOS 27 上的原生玻璃合成与水波帧率仍待真机验收。

## 本地构建

需要 **Xcode 26 或更高版本**以及 Metal 工具链。缺少 Metal 工具链时，用以下命令下载组件。

```sh
xcodebuild -downloadComponent MetalToolchain
```

用 Xcode 打开 `EdgeReminders.xcodeproj`，选择 `EdgeReminders` 运行。在仓库根目录运行打包脚本可生成通用版。

```sh
./scripts/package.sh
```

安装镜像与 SHA-256 文件位于 `dist/`。本机配置好 Developer ID Application 证书与 `notarytool` 钥匙串配置后，可生成已签名、公证并装订票据的安装包。

```sh
DEVELOPER_ID_APPLICATION='Developer ID Application: Your Name (TEAMID)' \
NOTARYTOOL_PROFILE='your-keychain-profile' ./scripts/package.sh
```
