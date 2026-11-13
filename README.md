<p align="center">
  <img src="docs/assets/segmentdesk.png" width="112" height="112" alt="SegmentDesk">
</p>

<h1 align="center">SegmentDesk</h1>

<p align="center">基于 N_m3u8DL-RE 的 Flutter 流媒体下载桌面客户端</p>

<p align="center">
  <a href="https://github.com/evan-dev0608/segmentdesk/releases/tag/v1.0.4">下载 v1.0.4</a> ·
  <a href="docs/usage.md">使用说明</a> ·
  <a href="desktop/README.md">从源码运行</a> ·
  <a href="https://github.com/nilaoda/N_m3u8DL-RE">上游核心</a>
</p>

SegmentDesk 是 [N_m3u8DL-RE](https://github.com/nilaoda/N_m3u8DL-RE) 的图形外壳，**不重新实现下载**：粘贴 HLS、DASH、MSS 清单链接，或打开本地清单与 M3U 播放列表，选好保存目录即可发起任务。下载、解密与混流全部由官方发行包里的核心完成，核心可在客户端内独立安装与更新。

## 功能

- **下载工作台** · 同一时刻只跑一个下载进程，任务列表保留全部任务记录并可按「全部 / 运行中 / 已结束」筛选；查看阶段、进度与日志，停止任务、打开输出目录或用原设置重试。进度帧会折叠成一行，带时间戳与级别的正式日志完整保留（上限 1000 行）。
- **二进制直链** · 新建下载可开启「二进制直链」模式，明显的单文件链接会自动预判；核心按响应内容直接下载，启动前自动忽略混流、范围、解密与命名模板参数，逐秒的字节进度换算成任务百分比并折叠显示。这是依赖核心的兼容模式。实测官方发行包 v0.6.0-beta 拒绝了测试 MP4 链接。实际支持范围以所选核心对具体链接的下载结果为准。
- **不把退出码 0 等同于成功** · 日志出现上游 ERROR 或明确失败文案时标为 **完成（有错误）** 并保留重试入口；关闭 `--check-segments-count` 时标为 **已完成（未校验分片数）** 并在日志中提示风险。
- **高级选项** · 表单从已安装核心的 `--help` 动态生成，不硬编码参数，提供搜索、开关、文件选择与可重复参数；可用能力按实际帮助输出探测（`--no-config`、工具子命令、`--select-video`、`--vod-drop-parts`），界面只显示当前核心支持的控件。
- **轨道与频道选择** · 读取轨道后图形化挑选视频、音频、字幕与点播分段；从本地或远程 M3U 勾选 IPTV 频道，M3U 判定对齐上游 `IPTVExtractor.IsPlaylist`。
- **核心与 FFmpeg** · 设置页路径框可直接编辑，自动回填识别到的路径和版本；两者都支持「在线下载」或选择本地可执行文件，保存时校验可用性。**FFmpeg 在线下载仅支持 Windows x64**，其他平台按钮可见但禁用，需自备 ffmpeg 并加入 PATH。
- **核心安装校验** · 按系统与架构（x64 / arm64）挑选官方发行包；GitHub API 提供文件大小与 SHA-256 时逐项校验，网络失败回退官方发行页则跳过校验并标注「本次未做完整性校验」。安装后会试运行 `--version` 并原子切换，失败自动回滚。
- **客户端更新** · 启动或手动检查发现新版时会显示发布说明。Windows x64 可在弹窗选择 Skia 或 Impeller，默认选中当前渲染版本；下载并校验后可退出并安装。遇到连接错误时会尝试通过 Windows 自带的 curl 重新下载。其他平台可打开发布页。
- **外观与下载偏好** · 跟随系统 / 浅色 / 深色三种模式、6 个预设主题色与「从图片提取」主题色，保存即时生效；默认保存目录与输出格式（MKV / MP4 / TS / 分别保存轨道）。

## 开始使用

1. 运行客户端，启动时会检查核心与 FFmpeg。缺少核心时打开 **设置 → 下载核心 → 在线下载**；这一步需要能访问 GitHub，且系统装有 `curl` 与 `tar`。
2. 找不到 FFmpeg 时，在 **设置 → FFmpeg** 选择本地可执行文件，或在 Windows x64 上点 **在线下载**（源为 gyan.dev 的 essentials 构建，先校验 SHA-256 再按摘要缓存到数据目录）。下载或选择后点 **保存设置**。
3. 点 **新建下载**，粘贴清单链接或选择本地清单，确认保存目录，再点 **开始下载**。
4. 选中任务查看日志；结束后可 **打开输出目录**，失败或「完成（有错误）」可 **用原设置重试**。

## 下载

Windows x64 优先选 **Skia 兼容版**。**Impeller 版**使用 Flutter 在 Windows 上的默认渲染器。如果最大化后出现黑边或画面停留在旧尺寸，可改装 Skia 版。两种安装包使用同一个应用标识，安装另一版会替换当前客户端，并沿用原有设置和下载核心。

[GitHub Releases](https://github.com/evan-dev0608/segmentdesk/releases/tag/v1.0.4) 的 v1.0.4 提供：

| 平台 | 文件 |
| --- | --- |
| Windows x64 Skia 兼容版（推荐） | `SegmentDesk-windows-x64-skia-setup.exe` |
| Windows x64 Impeller 版 | `SegmentDesk-windows-x64-impeller-setup.exe` |
| Windows x64 免安装版 | `SegmentDesk-windows-x64-no-install.zip` |
| macOS ARM64 | `SegmentDesk-macos-arm64.zip` |
| Linux x64 | `SegmentDesk-linux-x64.tar.gz` |
| Chrome 扩展 | `SegmentDesk-Chrome-Extension-0.2.14.zip` |

另有 `SHA256SUMS.txt` 供校验。三端均由 GitHub Actions 从源码构建，macOS 与 Linux 尚未实机验证；macOS 包未做 Developer ID 签名与公证。

**安装版与免安装版的区别**：两者都带 Chrome 通信宿主 `segmentdesk_import.exe`，但只有安装版额外安装 `native_import.json` 并写入 Chrome Native Messaging 宿主注册表，因此支持浏览器一键导入；免安装 ZIP 只是运行目录的压缩，不含该清单与注册项，浏览器导入请改用扩展里的 **复制** 再粘贴到客户端。两者共用当前用户的核心与设置。详见 [使用说明](docs/usage.md) 与 [构建说明](desktop/README.md)。

## 从 Chrome 发送到客户端

1. 下载并解压上面的扩展 ZIP，在 `chrome://extensions` 开启开发者模式后选择「加载已解压的扩展程序」，按 [扩展说明](browser-extension/README.md) 操作。
2. 打开视频网页，点扩展里的 **开始检测**，然后播放视频。检测到 HLS 主清单时，优先选择标有 **自动选轨 · 主清单** 的结果。
3. 点 **发送到客户端**，在 SegmentDesk 的 **确认下载** 弹窗检查链接、保存位置与「二进制直链」开关；需要手动选轨时打开 **高级选项 → 读取轨道**。

一键导入目前是 **Windows 安装版专享**：扩展经 Native Messaging 把链接写入本地收件箱，客户端每 750 毫秒轮询并唤起已有窗口。HLS、DASH、MSS、M3U 与 MP4 可发送到客户端。导入 MP4 会预选直链模式，实际能否下载由所选核心处理。

核心更新在 **设置 → 下载核心**；客户端更新在 **设置 → 客户端**。

## 在 GUI 中使用上游参数

**设置 → 下载偏好** 管理普通下载的默认目录与输出格式（默认 `mkv`，选「分别保存轨道」时不混流）。需要为某次任务配置请求头、轨道筛选、限速或录制时长时，从 **新建下载 → 高级选项** 进入，在搜索框输入参数名或说明，填写对应控件后点 **开始下载**。开启「二进制直链」后，混流、范围、解密与命名模板类参数会在任务启动时忽略（核心的 `BinaryDownloadRunner` 不接受这些选项），留空时由核心推断文件名，填入的文件名若没有扩展名则由核心补全，「读取轨道」与 IPTV 入口也不再可用。

| 想做什么 | 在「高级选项」中查找 |
| --- | --- |
| 给清单和分片请求附加 Referer、User-Agent 等请求头 | `--header` |
| 设置代理、下载线程、重试次数和限速 | `--custom-proxy`、`--thread-count`、`--download-retry-count`、`--max-speed` |
| 仅下载字幕，或按规则选择视频、音频和字幕 | `--sub-only`、`--select-video`、`--select-audio`、`--select-subtitle` |
| 图形化挑选轨道、点播分段或 IPTV 频道 | 地址框下方的「读取轨道」「本地 IPTV」「远程 IPTV」，无需手填筛选表达式 |
| 下载一段范围，或限制直播录制时长 | `--custom-range`、`--live-record-limit` |
| 自定义混流或附加字幕文件 | `--mux-after-done`、`--mux-import` |
| 尝试单文件直链（需已验证的兼容核心） | 新建下载里的「二进制直链」开关 |

表单以已安装核心的帮助为准。参数值、配置隔离与 Cookie 的填写示例见 [GUI 填写示例](docs/usage.md#本地清单与高级选项)和 [上游命令行文档](https://github.com/nilaoda/N_m3u8DL-RE#命令行参数)。

## 数据与排障

核心、FFmpeg 缓存与 `preferences.json` 存放在当前用户的数据目录：Windows `%LOCALAPPDATA%\StreamDownloadGUI`，macOS `~/Library/Application Support/StreamDownloadGUI`，Linux `$XDG_DATA_HOME/StreamDownloadGUI`（未设置时为 `~/.local/share/StreamDownloadGUI`）；Windows 的浏览器导入收件箱在 `%LOCALAPPDATA%\SegmentDesk\browser-inbox`。核心与 FFmpeg 的在线下载依赖系统 `curl` 与 `tar`，媒体任务通常需要 FFmpeg。

## 当前范围

同一时刻只允许一个下载进程，任务列表保留全部任务记录并支持筛选与移除。高级选项的可用范围由已安装核心决定：选轨需要 `--select-video`，点播选段需要 `--vod-drop-parts`；核心帮助未列出的参数不会出现在表单中，客户端会在任务日志里提示受影响的行为。二进制直链要求核心支持该能力；浏览器一键导入限于 Windows 安装版。本地媒体处理请直接使用上游命令行。仓库根目录的 Python 原型不参与客户端运行。

## 许可证与致谢

SegmentDesk 以 [MIT License](LICENSE) 发布。下载核心来自 [nilaoda/N_m3u8DL-RE](https://github.com/nilaoda/N_m3u8DL-RE)，上游以 [MIT License](https://github.com/nilaoda/N_m3u8DL-RE/blob/main/LICENSE) 发布。上游文档明确要求仅用于学习和技术研究、只下载有合法权限的内容；使用本客户端时同样请遵守该范围及所在地的法律法规。感谢上游作者与贡献者。
