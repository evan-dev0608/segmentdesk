<p align="center">
  <img src="docs/assets/segmentdesk.png" width="112" height="112" alt="SegmentDesk">
</p>

<h1 align="center">SegmentDesk</h1>

<p align="center">基于 N_m3u8DL-RE 的 Flutter 流媒体下载桌面客户端</p>

<p align="center">
  <a href="docs/usage.md">使用说明</a> ·
  <a href="desktop/README.md">从源码运行</a> ·
  <a href="https://github.com/nilaoda/N_m3u8DL-RE">上游核心</a>
</p>

SegmentDesk 把流媒体下载、任务日志和核心更新放在一个桌面窗口里。粘贴 HLS、DASH 或 MSS 清单链接，选择保存目录，就可以发起下载。下载能力由 [N_m3u8DL-RE](https://github.com/nilaoda/N_m3u8DL-RE) 的官方发行包提供，核心可在客户端内独立更新。

## 功能

- **下载工作台** · 新建下载、筛选任务、查看任务日志。
- **高级选项** · 读取当前核心的帮助，提供搜索、开关、文件选择及可重复参数。
- **文件工具** · 当核心版本支持时，可运行拼接、合并、混流和环境检测。
- **核心管理** · 按系统和架构安装官方发行包。GitHub API 限流时，可回退到官方发行页。
- **外观和下载偏好** · 支持深色模式、主题色、默认保存目录及混流格式。

## 开始使用

1. 运行客户端，在左侧点击 **安装核心**。
2. 安装 FFmpeg，并确保下载核心能在 PATH 中找到它。
3. 点击 **新建下载**，粘贴清单链接，选择目录，再点击 **开始下载**。

目前可从源码构建。Windows 构建和启动已验证，macOS 与 Linux 工程已加入，仍待实机验证。详见 [使用说明](docs/usage.md) 和 [构建说明](desktop/README.md)。

## 当前范围

客户端每次运行一个任务。图形化选轨、点播选段和 IPTV 频道选择仍在迁移。高级参数及文件工具的可用范围取决于已安装的核心版本。

## 许可证与致谢

SegmentDesk 以 [MIT License](LICENSE) 发布。下载核心来自 [nilaoda/N_m3u8DL-RE](https://github.com/nilaoda/N_m3u8DL-RE)，上游以 [MIT License](https://github.com/nilaoda/N_m3u8DL-RE/blob/main/LICENSE) 发布。感谢上游作者与贡献者。
