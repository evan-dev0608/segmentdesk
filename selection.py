import re
from http.cookiejar import MozillaCookieJar
from pathlib import Path
from urllib.parse import urljoin, urlsplit
from urllib.request import HTTPCookieProcessor, ProxyHandler, Request, build_opener

FILTERS = {
    "--select-video", "--select-audio", "--select-subtitle",
    "--drop-video", "--drop-audio", "--drop-subtitle",
}


def exact_expression(text):
    return "^" + re.sub(r"([.\\^$|?*+()\[\]{}])", r"\\\1", text).replace(":", r"\:") + "$"


def local_channels(path):
    return parse_channels(Path(path).read_text(encoding="utf-8-sig"))


def remote_channels(url, headers=(), cookies=None, proxy=None, use_system_proxy=True):
    handlers = []
    if proxy:
        handlers.append(ProxyHandler({"http": proxy, "https": proxy}))
    elif not use_system_proxy:
        handlers.append(ProxyHandler({}))
    if cookies:
        jar = MozillaCookieJar(cookies)
        jar.load(ignore_discard=True)
        handlers.append(HTTPCookieProcessor(jar))
    request = Request(url, headers={"User-Agent": "StreamDownloadGUI"})
    for header in headers:
        name, separator, value = header.partition(":")
        if not separator or not re.fullmatch(r"[!#$%&'*+.^_`|~0-9A-Za-z-]+", name.strip()):
            raise ValueError("请求头应使用「名称: 值」格式")
        if "\r" in value or "\n" in value:
            raise ValueError("请求头不能包含换行")
        request.add_unredirected_header(name.strip(), value.strip())
    with build_opener(*handlers).open(request, timeout=20) as response:
        data = response.read(8 * 1024 * 1024 + 1)
        if len(data) > 8 * 1024 * 1024:
            raise ValueError("播放列表超过 8 MiB")
        return parse_channels(data.decode("utf-8-sig"), response.geturl())

def parse_channels(content, base=""):
    if not content.lstrip().startswith("#EXTM3U"):
        raise ValueError("输入不是 M3U 播放列表")
    channels = []
    name = ""
    for line in content.splitlines():
        line = line.strip()
        if line.startswith("#EXTINF:"):
            match = re.search(r'^#EXTINF:(?:[^",]|"[^"]*")*,(.*)$', line)
            name = match.group(1).strip() if match else ""
        elif line and not line.startswith("#"):
            if name and urlsplit(urljoin(base, line)).scheme in ("http", "https"):
                channels.append(name)
            name = ""
    return list(dict.fromkeys(channels))



def vod_parts(tracks, index_field):
    durations = {}
    for track in tracks:
        playlist = track.get("Playlist") or {}
        if playlist.get("IsLive"):
            return {}
        track_durations = {}
        for part in playlist.get("MediaParts", ()):
            index = part.get(index_field)
            if type(index) is int and index >= 0:
                duration = sum(segment.get("Duration", 0) for segment in part.get("MediaSegments", ()))
                track_durations[index] = duration + track_durations.get(index, 0)
        for index, duration in track_durations.items():
            durations[index] = max(duration, durations.get(index, 0))
    return dict(sorted(durations.items()))
