const button = document.querySelector('#capture');
const status = document.querySelector('#status');
const results = document.querySelector('#results');
const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });

if (!tab?.url || !/^https?:\/\//i.test(tab.url)) {
  status.textContent = '请在普通网页中打开扩展。';
} else {
  document.querySelector('#site').textContent = new URL(tab.url).hostname;
  const key = String(tab.id);
  let active = false;

  function render(state) {
    active = state?.active ?? false;
    button.textContent = active ? '停止检测' : '检测当前页面';
    button.setAttribute('aria-pressed', String(active));
    status.textContent = active
      ? '正在检测。请播放视频，必要时刷新网页。'
      : '检测到清单后，复制链接并粘贴到 SegmentDesk。';
    results.replaceChildren();
    for (const item of state?.items ?? []) {
      const row = document.createElement('li');
      const url = new URL(item.url);
      const kind = document.createElement('span');
      kind.className = 'kind';
      kind.textContent = item.type;
      const label = document.createElement('div');
      label.className = 'media';
      label.title = url.host + url.pathname;
      const name = document.createElement('span');
      name.className = 'name';
      name.textContent = url.pathname.split('/').filter(Boolean).at(-1) ?? '媒体清单';
      const host = document.createElement('span');
      host.className = 'host';
      host.textContent = url.host;
      label.append(name, host);
      const copy = document.createElement('button');
      copy.className = 'copy';
      copy.textContent = '复制链接';
      copy.onclick = async () => {
        try {
          await navigator.clipboard.writeText(item.url);
          status.textContent = '已复制完整链接，请粘贴到 SegmentDesk。';
        } catch {
          status.textContent = '复制失败，请重试。';
        }
      };
      row.append(kind, label, copy);
      results.append(row);
    }
  }

  chrome.storage.session.onChanged.addListener(changes => {
    if (key in changes) render(changes[key].newValue);
  });
  render((await chrome.storage.session.get(key))[key]);
  button.disabled = false;
  button.onclick = async () => {
    button.disabled = true;
    try {
      if (!active && !await chrome.permissions.request({
        origins: ['http://*/*', 'https://*/*'],
      })) {
        status.textContent = '请授予网站访问权限，以便识别跨域媒体请求。';
        return;
      }
      const response = await chrome.runtime.sendMessage({
        action: active ? 'stop' : 'start', tabId: tab.id,
      });
      if (!response?.ok) throw new Error('Capture state update failed');
    } catch {
      status.textContent = '无法更新检测状态，请重试。';
    } finally {
      button.disabled = false;
    }
  };
}
