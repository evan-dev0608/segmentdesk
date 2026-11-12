# SegmentDesk · Flutter 桌面版

进入本目录后运行 `flutter run -d windows`。macOS 和 Linux 分别使用 `-d macos` 和 `-d linux`，需在对应平台安装 Flutter 桌面构建工具链。

通过「安装核心」获取官方 N_m3u8DL-RE，然后点击「新建下载」。安装更新使用系统 curl 和 tar，下载依赖核心能够找到 FFmpeg。已有 Python 原型的核心安装可复用。

在侧栏选择「选项与工具」可搜索高级参数，打开本地清单，或运行当前核心支持的拼接、合并、混流和环境检测命令。图形媒体预览、选轨、选段和 IPTV 频道选择还在 Python 原型中。



## 打包

在对应平台运行 `flutter build windows`、`flutter build macos` 或 `flutter build linux`。Windows 发布包需要包含 `build/windows/x64/runner/Release/` 的完整内容，入口为 `stream_download.exe`。

## GitHub 打包

仓库的 **Desktop builds** 工作流会分别在 Windows、macOS 和 Linux 上构建。手动运行可下载三个 Actions 构建产物。推送 `v` 开头的标签后，三端全部构建成功才会发布一个 GitHub 预发行版，包含 Windows x64 安装版与免安装 ZIP、macOS ARM64 和 Linux x64 压缩包，以及 SHA-256 清单。Windows 安装包使用 Inno Setup，CI 会验证静默安装和卸载。macOS 包没有签名和公证。
