# SegmentDesk · Flutter 桌面版

进入本目录后运行 `flutter run -d windows`。macOS 和 Linux 分别使用 `-d macos` 和 `-d linux`，需在对应平台安装 Flutter 桌面构建工具链。

通过「设置 → 下载核心 → 在线下载」获取官方 N_m3u8DL-RE，然后点击「新建下载」。核心与 FFmpeg 的路径框可直接编辑，也可选择本地可执行文件；FFmpeg 在线下载仅支持 Windows x64。安装更新使用系统 curl 和 tar，下载依赖核心能够找到 FFmpeg；客户端会探测 PATH 中的 ffmpeg 并显式传路径。仅当核心帮助列出 `--no-config` 时才会追加该参数以忽略上游全局配置（`doctor` 命令除外）；旧发行版没有该参数时会跳过隔离并写入提示日志。已有 Python 原型的核心安装可复用。

「新建下载」支持链接、本地清单和高级参数。高级选项地址框下方提供「读取轨道」「本地 IPTV」「远程 IPTV」：前者让核心以 `--skip-download` 写出 `meta.json` / `meta_selected.json`，据此生成选轨表达式和 `--vod-drop-parts`；后两者解析 M3U 频道并生成 `name=...:for=all`。M3U 判定与分段编号按上游 `IPTVExtractor.IsPlaylist`、`VodPartSelector.Id` 校准。1.0.0 已移除工作台「更多操作 → 处理本地媒体文件」入口，`advanced.dart` 中的 `toolsOnly` 分支目前没有 UI 调用点。

`lib/selection.dart` 是纯逻辑层（表达式转义、M3U 与元数据解析、预览参数、远程拉取），`lib/selection_dialog.dart` 是两个选择对话框，两者都不依赖具体核心可执行文件，便于用固定样本测试。



## 测试

运行 `flutter analyze --no-pub` 与 `flutter test --no-pub`。核心安装链路通过注入 `CoreRunner` 做不联网测试，不访问 GitHub，也不调用系统 curl / tar；选轨、选段与 IPTV 的解析和回填使用固定 JSON / M3U 样本，不启动真实核心。若本机设置了 `HTTP_PROXY`，`flutter_tester` 的本地 WebSocket 升级会失败并报 `Invalid WebSocket upgrade request`，需先清空代理变量或把 `localhost,127.0.0.1` 加入 `NO_PROXY`。

## 打包

在对应平台运行 `flutter build windows`、`flutter build macos` 或 `flutter build linux`。Windows 发布包需要包含 `build/windows/x64/runner/Release/` 的完整内容，入口为 `stream_download.exe`。安装包用 Inno Setup 6 编译：`ISCC.exe /DAppVersion=<pubspec 版本> packaging/windows/SegmentDesk.iss`，产物在 `dist/`；编译前把仓库根 `LICENSE` 复制成 Release 目录下的 `LICENSE.txt`。未安装 Inno Setup 时可用官方安装器的 `/VERYSILENT /CURRENTUSER /DIR=<可写目录>` 静默装到用户目录，无需管理员权限。

## GitHub 打包

仓库的 **Desktop builds** 工作流会分别在 Windows、macOS 和 Linux 上构建。手动运行可下载三个 Actions 构建产物。推送 `v` 开头的标签后，三端全部构建成功才会发布一个 GitHub 正式版（Latest），包含 Windows x64 安装版与免安装 ZIP、macOS ARM64 和 Linux x64 压缩包，以及 SHA-256 清单。Windows 安装包使用 Inno Setup，CI 会验证静默安装和卸载。macOS 包没有签名和公证。
