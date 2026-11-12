import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
import zipfile
from contextlib import contextmanager
from types import SimpleNamespace
from urllib.error import HTTPError, URLError
from urllib.parse import unquote, urlsplit
from pathlib import Path, PurePosixPath

REPO = "nilaoda/N_m3u8DL-RE"
SYSTEM = platform.system()
EXE = "N_m3u8DL-RE.exe" if SYSTEM == "Windows" else "N_m3u8DL-RE"
FLAGS = subprocess.CREATE_NO_WINDOW if SYSTEM == "Windows" else 0
HOME = Path.home()
DATA = {
    "Windows": Path(os.environ.get("LOCALAPPDATA") or HOME / "AppData/Local"),
    "Darwin": HOME / "Library/Application Support",
}.get(SYSTEM, Path(os.environ.get("XDG_DATA_HOME") or HOME / ".local/share")) / "StreamDownloadGUI"
ACTIVE = DATA / "active.json"


def target_suffix():
    machine = platform.machine().lower()
    arch = {"amd64": "x64", "x86_64": "x64", "arm64": "arm64",
            "aarch64": "arm64"}.get(machine)
    system = {"Windows": "win", "Darwin": "osx", "Linux": "linux"}.get(SYSTEM)
    if not arch or not system:
        raise ValueError(f"暂不支持当前平台：{SYSTEM} {machine}")
    extension = "zip" if SYSTEM == "Windows" else "tar.gz"
    return f"-{system}-{arch}.{extension}"


def active_core():
    if not ACTIVE.is_file():
        return None, "未安装"
    state = json.loads(ACTIVE.read_text(encoding="utf-8"))
    path = DATA / state["directory"] / EXE
    return (path, state["tag"]) if path.is_file() else (None, "未安装")


@contextmanager
def request(url):
    try:
        response = urllib.request.urlopen(
            urllib.request.Request(url, headers={"User-Agent": "StreamDownloadGUI"}),
            timeout=15,
        )
    except HTTPError:
        raise
    except URLError as error:
        curl = shutil.which("curl")
        if not curl:
            raise
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / "response"
            result = subprocess.run(
                [curl, "--disable", "--fail", "--silent", "--show-error", "--location",
                 "--proto", "=https", "--proto-redir", "=https", "--connect-timeout", "10",
                 "--max-time", "90", "--user-agent", "StreamDownloadGUI",
                 "--output", str(output), "--write-out", "%{url_effective}", url],
                capture_output=True, text=True, creationflags=FLAGS,
            )
            if result.returncode:
                raise URLError(result.stderr.strip() or error.reason) from error
            with output.open("rb") as source:
                yield SimpleNamespace(read=source.read, geturl=lambda: result.stdout.strip())
        return
    with response:
        yield response


def unpack_core(archive, target):
    def matches(name):
        return PurePosixPath(name).name == EXE

    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive) as package:
            member, = [item for item in package.infolist()
                       if matches(item.filename) and not item.is_dir()]
            with package.open(member) as source, target.open("xb") as output:
                shutil.copyfileobj(source, output)
    else:
        with tarfile.open(archive, "r:gz") as package:
            member, = [item for item in package if matches(item.name) and item.isfile()]
            with package.extractfile(member) as source, target.open("xb") as output:
                shutil.copyfileobj(source, output)
    target.chmod(0o755)


def release_info():
    try:
        with request(f"https://api.github.com/repos/{REPO}/releases/latest") as response:
            return json.load(response)
    except HTTPError as error:
        if error.code not in (403, 429, 500, 502, 503, 504):
            raise
    except URLError:
        pass

    origin = f"https://github.com/{REPO}/releases"
    with request(f"{origin}/latest") as response:
        path = urlsplit(response.geturl()).path
    match = re.fullmatch(rf"/{re.escape(REPO)}/releases/tag/([\w.-]+)", path)
    if not match:
        raise ValueError("无法识别 GitHub 官方发行版本")
    tag = match[1]
    with request(f"{origin}/expanded_assets/{tag}") as response:
        html = response.read().decode("utf-8")
    pattern = rf'href="(/{re.escape(REPO)}/releases/download/{re.escape(tag)}/[^"<>]+)"'
    paths = dict.fromkeys(re.findall(pattern, html))
    return {"tag_name": tag, "assets": [
        {"name": unquote(path.rsplit("/", 1)[-1]),
         "browser_download_url": "https://github.com" + path}
        for path in paths
    ]}


def update_core(report):
    suffix = target_suffix()
    try:
        release = release_info()
    except URLError as error:
        raise ValueError(f"无法连接 GitHub 官方发行页：{error.reason}") from error
    tag = release["tag_name"]
    current, installed = active_core()
    if current and installed == tag:
        return f"核心已是最新版 {tag}"

    prefix = f"https://github.com/{REPO}/releases/download/"
    platform_id, extension = suffix[1:].split(".", 1)
    filename_end = rf"[-_]{re.escape(platform_id)}(?:_\d{{8}})?\.{re.escape(extension)}$"
    assets = [item for item in release["assets"]
              if item["name"].startswith("N_m3u8DL-RE")
              and re.search(filename_end, item["name"])
              and item["browser_download_url"].startswith(prefix)]
    if len(assets) != 1:
        raise ValueError(f"上游发行版 {tag} 未提供唯一匹配的 {platform_id} 核心")
    asset = assets[0]
    DATA.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=DATA) as temp:
        stage = Path(temp)
        archive = stage / ("core.zip" if suffix.endswith(".zip") else "core.tar.gz")
        report(f"正在下载核心 {tag}…")
        with request(asset["browser_download_url"]) as source, archive.open("xb") as output:
            shutil.copyfileobj(source, output)
        expected_size = asset.get("size")
        if expected_size is not None and archive.stat().st_size != expected_size:
            raise ValueError("下载文件大小与发布记录不一致")
        digest = asset.get("digest")
        if digest:
            with archive.open("rb") as source:
                actual = hashlib.file_digest(source, "sha256").hexdigest()
            if digest != f"sha256:{actual}":
                raise ValueError("核心压缩包校验失败")
        install = stage / "install"
        install.mkdir()
        candidate = install / EXE
        unpack_core(archive, candidate)
        probe = subprocess.run([str(candidate), "--version"], capture_output=True,
                               timeout=15, creationflags=FLAGS, check=True)
        if not re.search(rb"\d+\.\d+", probe.stdout):
            raise ValueError("无法识别核心版本")
        destination = Path(tempfile.mkdtemp(prefix="core-", dir=DATA))
        try:
            candidate.replace(destination / EXE)
            pointer = stage / "active.json"
            pointer.write_text(json.dumps({"tag": tag, "directory": destination.name}),
                               encoding="utf-8")
            pointer.replace(ACTIVE)
        except OSError:
            shutil.rmtree(destination)
            raise
    return f"核心已更新至 {tag}"
