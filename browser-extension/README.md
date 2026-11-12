# SegmentDesk 媒体检测

从 GitHub Releases 下载并解压扩展 ZIP。在 Chrome 打开 `chrome://extensions`，启用开发者模式，选择「加载已解压的扩展程序」，指向包含 `manifest.json` 的目录。从源码加载时可直接选择本目录。

打开视频网页，点击扩展中的「检测当前页面」并授权网站访问，然后播放视频。已经在播放时，可以刷新网页，让播放器重新请求清单。选择 HLS 或 DASH 候选项，复制链接并粘贴到 SegmentDesk 的「新建下载」。检测结束后可点击「停止检测」。

网站访问权限用于跨域 CDN。扩展只为主动开启检测的标签页保存候选项，候选项随标签页关闭或浏览器会话结束清除。复制时保留完整查询参数。首版面向公开清单。依赖登录态或额外请求头的链接可能无法直接在客户端预览。

本地测试运行 `node --test browser-extension/media.test.mjs browser-extension/worker.test.mjs`。后续可用 Native Messaging 接入「在 SegmentDesk 打开」，并复用客户端确认表单。

扩展使用浏览器原生 JavaScript。运行 `pwsh -File browser-extension/build.ps1` 将运行文件打包到 `browser-extension/dist/`。
