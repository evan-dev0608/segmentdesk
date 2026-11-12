# SegmentDesk 媒体检测

从 GitHub Releases 下载并解压扩展 ZIP。在 Chrome 打开 `chrome://extensions`，启用开发者模式，选择「加载已解压的扩展程序」，指向包含 `manifest.json` 的目录。从源码加载时可直接选择本目录。

打开视频网页，点击扩展中的「开始检测」，然后播放视频。已经在播放时，可以刷新网页，让播放器重新请求资源。扩展识别 HLS、DASH、Smooth Streaming、M3U 和 MP4 候选；HLS 主清单标为「自动选轨 · 主清单」。点击「发送到客户端」，在客户端的「确认下载」弹窗检查链接与保存位置。此功能需要带 Native Messaging 宿主的 Windows 安装版（免安装 ZIP 不含清单与注册项）。也可复制链接并粘贴到「新建下载」。HLS、DASH、Smooth Streaming 和 M3U 可发送到客户端；M3U 可在高级选项中使用远程 IPTV 选择频道，实际下载取决于核心。MP4 当前版本尚未开放浏览器导入，只能复制链接。检测结束后可点击「停止检测」。

安装时声明 HTTP 和 HTTPS 网站访问权限，以便 Chrome 在启动扩展时注册跨域 CDN 请求监听。扩展只为主动开启检测的标签页保存候选项，候选项随标签页关闭或浏览器会话结束清除。复制时保留完整查询参数。首版面向公开清单。依赖登录态或额外请求头的链接可能无法直接在客户端预览。

本地测试运行 `node --test browser-extension/media.test.mjs browser-extension/worker.test.mjs`。

扩展使用浏览器原生 JavaScript。运行 `pwsh -File browser-extension/build.ps1` 将运行文件打包到 `browser-extension/dist/`。
