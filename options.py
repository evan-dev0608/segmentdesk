import json
import re
import tempfile
import subprocess
import threading
from pathlib import Path
import tkinter as tk
from queue import Empty, Queue
from tkinter import filedialog, messagebox, ttk
from urllib.parse import urlsplit

from core import FLAGS
from selection import FILTERS, exact_expression, local_channels, remote_channels, vod_parts

OPTION = re.compile(r"^\s+((?:-\S+?,\s+)*--[\w-]+)(?:\s+(<[^>]+>))?(?:\s{2,}(.*))?$")
CHOICES = {
    "--ui-language": ("zh-CN", "zh-TW", "en-US"),
    "--sub-format": ("SRT", "VTT"),
    "--log-level": ("INFO", "WARN", "ERROR", "DEBUG", "OFF"),
    "--http-version": ("1.1", "2"),
    "--decryption-engine": ("MP4DECRYPT", "SHAKA_PACKAGER", "FFMPEG"),
}
SELECT_OPTIONS = {"--select-video", "--select-audio", "--select-subtitle"}
TOOLS = {"下载": None, "拼接文件": "concat", "合并媒体": "merge",
         "混流轨道": "mux", "检测环境": "doctor"}


def parse_options(help_text):
    for line in help_text.splitlines():
        match = OPTION.match(line)
        if match:
            aliases, value, description = match.groups()
            yield aliases.split()[-1], value, description or ""


def supports_tool(help_text, operation):
    return any(
        re.match(rf"^\s*N_m3u8DL-RE(?:\.exe)?\s+{re.escape(operation)}(?:\s|$)", line, re.I)
        for line in help_text.splitlines()
    )


def download_defaults(selected, directory, supported=()):
    if selected.get("--vod-select-parts") == "true":
        raise ValueError("请使用「读取轨道」勾选点播分段。")
    subtitle_only = selected.get("--sub-only") == "true"
    has_track_filters = bool(selected.keys() & SELECT_OPTIONS)
    auto_select = selected.get("--auto-select")
    if subtitle_only and (auto_select == "true" or has_track_filters):
        raise ValueError("仅下载字幕时，请关闭自动选轨并清空手动选轨条件。")
    if has_track_filters and auto_select == "true":
        raise ValueError("使用手动选轨条件时，请关闭自动选轨。")
    if auto_select == "false" and not subtitle_only and not has_track_filters:
        raise ValueError("关闭自动选轨后，请先读取并选择轨道，或设置选轨条件。")

    args = []
    if "--save-dir" not in selected:
        args.extend(["--save-dir", str(directory)])
    if auto_select is None:
        args.extend(["--auto-select", "false" if subtitle_only or has_track_filters else "true"])
    if "--vod-select-parts" in supported and "--vod-select-parts" not in selected:
        args.extend(["--vod-select-parts", "false"])
    return args


class OptionsDialog(tk.Toplevel):
    def __init__(self, app, core, directory, address):
        super().__init__(app)
        self.title("下载选项与工具")
        self.geometry("860x650")
        self.transient(app)
        self.grab_set()
        self.app, self.core, self.directory = app, core, directory
        self.operation = tk.StringVar(value="下载")
        self.address = tk.StringVar(value=address)
        self.status = tk.StringVar()
        self.fields = []
        self.result = Queue()
        self.generation = 0

        top = ttk.Frame(self, padding=12)
        top.pack(fill="x")
        self.operation_picker = ttk.Combobox(top, values=("下载",), textvariable=self.operation,
                                 state="readonly", width=13)
        self.operation_picker.pack(side="left")
        self.operation_picker.bind("<<ComboboxSelected>>", self.load)
        self.input = ttk.Frame(top)
        self.input.pack(side="left", fill="x", expand=True, padx=(8, 0))
        ttk.Entry(self.input, textvariable=self.address).pack(side="left", fill="x", expand=True)
        ttk.Button(self.input, text="选择本地清单…", command=lambda: self.pick(self.address)).pack(side="left")

        filters = ttk.Frame(self, padding=(12, 0, 12, 8))
        filters.pack(fill="x")
        ttk.Label(filters, text="搜索选项").pack(side="left", padx=(0, 8))
        self.search = tk.StringVar()
        ttk.Entry(filters, textvariable=self.search).pack(side="left", fill="x", expand=True)
        self.search.trace_add("write", self.filter_rows)
        self.rows = []

        ttk.Button(filters, text="读取轨道…", command=self.preview_tracks).pack(side="left", padx=(8, 0))
        ttk.Button(filters, text="本地 IPTV…", command=self.channels).pack(side="left", padx=(8, 0))

        ttk.Button(filters, text="远程 IPTV…", command=self.load_remote_channels).pack(side="left", padx=(8, 0))

        bottom = ttk.Frame(self, padding=12)
        bottom.pack(side="bottom", fill="x")
        ttk.Label(bottom, textvariable=self.status).pack(side="left")
        self.run = ttk.Button(bottom, text="开始", command=self.execute)
        self.run.pack(side="right")
        canvas = tk.Canvas(self, highlightthickness=0)
        scrollbar = ttk.Scrollbar(self, command=canvas.yview)
        scrollbar.pack(side="right", fill="y")
        canvas.pack(fill="both", expand=True)
        canvas.configure(yscrollcommand=scrollbar.set)
        self.form = ttk.Frame(canvas, padding=12)
        frame = canvas.create_window((0, 0), window=self.form, anchor="nw")
        canvas.bind("<Configure>", lambda event: canvas.itemconfigure(frame, width=event.width))
        self.form.bind("<Configure>", lambda event: canvas.configure(scrollregion=canvas.bbox("all")))
        self.bind("<MouseWheel>", lambda event: canvas.yview_scroll(-1 if event.delta > 0 else 1, "units"))
        self.load()
        self.after(50, self.poll)

    def pick(self, variable, directory=False):
        path = filedialog.askdirectory(parent=self) if directory else filedialog.askopenfilename(parent=self)
        if path:
            variable.set(path)

    def load(self, event=None):
        self.generation += 1
        generation = self.generation
        operation = TOOLS[self.operation.get()]
        if operation:
            self.input.pack_forget()
        elif not self.input.winfo_manager():
            self.input.pack(side="left", fill="x", expand=True, padx=(8, 0))
        for widget in self.form.winfo_children():
            widget.destroy()
        self.fields.clear()
        self.rows.clear()
        self.search.set("")
        self.run.configure(state="disabled")
        self.status.set("正在读取当前核心的选项…")

        def read():
            args = [str(self.core), *([operation] if operation else []), "--help"]
            try:
                result = subprocess.run(args, capture_output=True, encoding="utf-8",
                                        errors="replace", timeout=15, creationflags=FLAGS)
                tools = None
                if not operation:
                    tools = ["下载"]
                    for label, command in TOOLS.items():
                        if not command:
                            continue
                        help_result = subprocess.run(
                            [str(self.core), command, "--help"], capture_output=True, encoding="utf-8",
                            errors="replace", timeout=15, creationflags=FLAGS,
                        )
                        if help_result.returncode == 0 and supports_tool(help_result.stdout, command):
                            tools.append(label)
                options = list(parse_options(result.stdout))
                if result.returncode or not options or (operation and not supports_tool(result.stdout, operation)):
                    raise ValueError("当前核心未提供此命令的可识别帮助")
                self.result.put((generation, options, tools, None))
            except (OSError, ValueError, subprocess.TimeoutExpired) as error:
                self.result.put((generation, [], None, str(error)))

        threading.Thread(target=read, daemon=True).start()

    def poll(self):
        try:
            while True:
                generation, options, tools, error = self.result.get_nowait()
                if generation == self.generation:
                    self.status.set(error or "")
                    if not error:
                        if tools is not None:
                            self.operation_picker.configure(values=tools)
                        for flag, value, description in options:
                            if flag not in ("--help", "--version", "--morehelp", "--generate-completion"):
                                self.add_option(flag, value, description)
                        self.run.configure(state="normal")
        except Empty:
            pass
        self.after(50, self.poll)

    def preview_tracks(self):
        address = self.address.get().strip()
        if self.operation.get() != "下载" or not address:
            messagebox.showinfo("读取轨道", "请先输入链接或选择本地清单。", parent=self)
            return
        self.run.configure(state="disabled")
        self.status.set("正在读取媒体轨道…")
        result = Queue()
        network_options = {"--header", "--cookies", "--base-url", "--custom-proxy",
                           "--use-system-proxy", "--http-version", "--ffmpeg-binary-path",
                           "--append-url-params", "--config", "--no-config"}
        args = [str(self.core), address]
        for flag, variable, boolean in self.fields:
            value = variable.get().strip()
            if flag in network_options and value and value != "默认":
                args.extend([flag, ("true" if value == "启用" else "false") if boolean else value])

        def read():
            try:
                with tempfile.TemporaryDirectory() as folder:
                    probe = subprocess.run(
                        [*args, "--tmp-dir", folder, "--save-dir", folder,
                         "--save-name", "preview", "--auto-select", "--skip-download",
                         "--write-meta-json", "true", "--no-log", "--disable-update-check"],
                        cwd=self.directory, capture_output=True, timeout=45, creationflags=FLAGS,
                    )
                    metadata = Path(folder) / "preview" / "meta.json"
                    if not metadata.is_file():
                        raise ValueError(f"核心未输出轨道信息（退出码 {probe.returncode}）")
                    tracks = json.loads(metadata.read_text(encoding="utf-8-sig"))
                    if not isinstance(tracks, list) or not all(isinstance(track, dict) for track in tracks):
                        raise ValueError("无法识别当前核心的轨道信息格式")
                    selected_file = metadata.with_name("meta_selected.json")
                    selected = json.loads(selected_file.read_text(encoding="utf-8-sig")) if selected_file.is_file() else []
                    parts = vod_parts(tracks, "PeriodIndex") or vod_parts(selected, "DiscontinuitySequence")
                    result.put((tracks, parts))
            except (OSError, ValueError, subprocess.TimeoutExpired) as error:
                result.put(str(error))

        def check():
            try:
                tracks = result.get_nowait()
            except Empty:
                self.after(100, check)
                return
            if self.operation.get() != "下载":
                return
            self.run.configure(state="normal")
            self.status.set("")
            if self.address.get().strip() != address:
                return
            if isinstance(tracks, str):
                messagebox.showerror("无法读取轨道", tracks, parent=self)
            else:
                self.choose_tracks(*tracks)

        threading.Thread(target=read, daemon=True).start()
        self.after(100, check)

    def choose_tracks(self, tracks, parts):
        dialog = tk.Toplevel(self)
        dialog.title("选择下载轨道")
        dialog.transient(self)
        dialog.grab_set()
        panel = ttk.Frame(dialog, padding=12)
        panel.pack(fill="both", expand=True)
        selectors = {}
        for row, (kind, label) in enumerate((("video", "视频"), ("audio", "音频"), ("subtitle", "字幕"))):
            values = []
            for track in tracks:
                data = {key.lower(): value for key, value in track.items()}
                media_type = str(data.get("mediatype")).lower()
                track_kind = {"audio": "audio", "subtitles": "subtitle"}.get(media_type, "video")
                if track_kind == kind and data.get("url"):
                    title = " · ".join(str(data[key]) for key in
                                       ("name", "language", "resolution", "bandwidth", "codecs", "groupid")
                                       if data.get(key))
                    filters = ["url=" + exact_expression(data["url"])]
                    if data.get("groupid"):
                        filters.append("id=" + exact_expression(str(data["groupid"])))
                    values.append((title or label, ":".join(filters) + ":for=best"))
            ttk.Label(panel, text=label).grid(row=row, column=0, sticky="w", padx=(0, 8))
            selector = ttk.Combobox(panel, values=("不选", *(f"{i + 1}. {name}" for i, (name, _) in enumerate(values))),
                                    width=65, state="readonly")
            selector.grid(row=row, column=1, sticky="ew", pady=4)
            selector.current(0)
            selectors[kind] = (selector, values)

        part_field = next((variable for flag, variable, _ in self.fields if flag == "--vod-drop-parts"), None)
        if part_field is None:
            parts = {}
        checks = {}
        if len(parts) > 1:
            ttk.Label(panel, text="保留点播分段").grid(row=3, column=0, sticky="nw", pady=6)
            part_list = tk.Listbox(panel, selectmode="multiple", exportselection=False, height=min(len(parts), 8))
            part_list.grid(row=3, column=1, sticky="ew", pady=6)
            excluded = set(part_field.get().split(","))
            for position, (index, duration) in enumerate(parts.items()):
                part_list.insert("end", f"第 {index} 段 · {duration:.1f} 秒")
                checks[position] = index
                if str(index) not in excluded:
                    part_list.selection_set(position)

        def close():
            dialog.destroy()
            self.grab_set()

        def apply():
            if checks and not part_list.curselection():
                messagebox.showinfo("选择分段", "请至少保留一个点播分段。", parent=dialog)
                return
            if not checks and not any(selector.current() > 0 for selector, _ in selectors.values()):
                messagebox.showinfo("选择轨道", "请至少选择一个轨道。", parent=dialog)
                return
            if checks:
                kept = set(part_list.curselection())
                part_field.set(",".join(str(index) for position, index in checks.items() if position not in kept))
            manual_tracks = any(selector.current() > 0 for selector, _ in selectors.values())
            for flag, variable, _ in self.fields:
                if flag == "--auto-select" and manual_tracks:
                    variable.set("关闭")
                elif manual_tracks and flag.startswith("--select-") and flag[9:] in selectors:
                    selector, values = selectors[flag[9:]]
                    index = selector.current() - 1
                    variable.set(values[index][1] if index >= 0 else "")
            close()

        dialog.protocol("WM_DELETE_WINDOW", close)
        ttk.Button(panel, text="应用轨道与分段选择", command=apply).grid(row=4, column=1, sticky="e", pady=8)

    def load_remote_channels(self):
        address = self.address.get().strip()
        if self.operation.get() != "下载" or not address.startswith(("https://", "http://")):
            messagebox.showinfo("远程 IPTV", "请先在下载地址框粘贴 M3U 链接。", parent=self)
            return
        result = Queue()
        self.status.set("正在读取远程频道…")
        values = {flag: variable.get().strip() for flag, variable, _ in self.fields}
        headers = [variable.get().strip() for flag, variable, _ in self.fields
                   if flag == "--header" and variable.get().strip()]
        cookies = values.get("--cookies")
        if cookies:
            cookies = self.directory / cookies

        def read():
            try:
                result.put(remote_channels(
                    address, headers=headers, cookies=cookies,
                    proxy=values.get("--custom-proxy"),
                    use_system_proxy=values.get("--use-system-proxy") != "关闭",
                ))
            except (OSError, ValueError) as error:
                result.put(str(error))

        def check():
            try:
                channels = result.get_nowait()
            except Empty:
                self.after(100, check)
                return
            if self.operation.get() != "下载" or self.address.get().strip() != address:
                return
            self.status.set("")
            if isinstance(channels, str):
                messagebox.showerror("无法读取 IPTV", channels, parent=self)
            else:
                self.choose_channels(address, channels)

        threading.Thread(target=read, daemon=True).start()
        self.after(100, check)

    def channels(self):
        path = filedialog.askopenfilename(parent=self, filetypes=[("M3U 播放列表", "*.m3u *.m3u8")])
        if not path:
            return
        try:
            channels = local_channels(path)
        except (OSError, ValueError) as error:
            messagebox.showerror("无法读取 IPTV", str(error), parent=self)
            return
        self.choose_channels(path, channels)

    def choose_channels(self, path, channels):
        try:
            if not channels:
                raise ValueError("播放列表没有带名称的 HTTP(S) 频道")
            field = next(variable for flag, variable, _ in self.fields if flag == "--select-video")
        except (OSError, ValueError, StopIteration) as error:
            messagebox.showerror("无法读取 IPTV", str(error) or "请先加载下载选项", parent=self)
            return
        dialog = tk.Toplevel(self)
        dialog.title("选择 IPTV 频道")
        dialog.geometry("480x400")
        dialog.transient(self)
        dialog.grab_set()
        dialog.protocol("WM_DELETE_WINDOW", lambda: close())
        listing = tk.Listbox(dialog, selectmode="extended")
        scrollbar = ttk.Scrollbar(dialog, command=listing.yview)
        listing.configure(yscrollcommand=scrollbar.set)
        scrollbar.pack(side="right", fill="y")
        for channel in channels:
            listing.insert("end", channel)
        listing.pack(fill="both", expand=True, padx=10, pady=10)

        def close():
            dialog.destroy()
            self.grab_set()

        def apply():
            names = [channels[index] for index in listing.curselection()]
            if names:
                self.address.set(path)
                field.set("name=" + "|".join(map(exact_expression, names)) + ":for=all")
                for flag, variable, _ in self.fields:
                    if flag == "--auto-select":
                        variable.set("关闭")
                close()

        ttk.Button(dialog, text="使用选中的频道", command=apply).pack(pady=(0, 10))

    def filter_rows(self, *_):
        query = self.search.get().strip().casefold()
        for row, _ in self.rows:
            row.pack_forget()
        for row, text in self.rows:
            if query in text:
                row.pack(fill="x")

    def add_option(self, flag, placeholder, description):
        row = ttk.Frame(self.form, padding=(0, 4))
        self.rows.append((row, f"{flag} {description}".casefold()))
        self.filter_rows()
        ttk.Label(row, text=description or flag, wraplength=650).pack(anchor="w")
        controls = ttk.Frame(row)
        controls.pack(fill="x")
        ttk.Label(controls, text=flag, width=27).pack(side="left")
        if flag == "--mux-after-done":
            self.add_mux_option(controls, flag)
            return
        boolean = placeholder is None
        variable = tk.StringVar()
        self.fields.append((flag, variable, boolean))
        if boolean:
            ttk.Combobox(controls, textvariable=variable, state="readonly", width=14,
                         values=("默认", "启用", "关闭")).pack(side="left")
            variable.set("默认")
        else:
            choices = CHOICES.get(flag)
            if not choices and re.fullmatch(r"<[\w.-]+(?:\|[\w.-]+)+>", placeholder):
                choices = tuple(placeholder[1:-1].split("|"))
            if choices:
                ttk.Combobox(controls, textvariable=variable, values=("", *choices),
                             state="readonly").pack(side="left")
            else:
                ttk.Entry(controls, textvariable=variable).pack(side="left", fill="x", expand=True)
            if any(word in flag for word in ("file", "path", "dir", "input", "cookies", "config")):
                ttk.Button(controls, text="浏览…", command=lambda: self.pick(
                    variable, directory=flag.endswith("-dir"))).pack(side="left")
            if flag in FILTERS:
                ttk.Button(controls, text="设置筛选…", command=lambda: self.track_filter(
                    variable, flag.startswith("--drop"))).pack(side="left")
            if flag in ("--input", "--header", "--key", "--ad-keyword", "--mux-import"):
                ttk.Button(controls, text="再添加一项", command=lambda: self.add_option(
                    flag, placeholder, description)).pack(side="left")

    def track_filter(self, target, dropping):
        dialog = tk.Toplevel(self)
        dialog.title("设置轨道筛选")
        dialog.transient(self)
        dialog.grab_set()
        panel = ttk.Frame(dialog, padding=12)
        panel.pack(fill="both", expand=True)
        fields = {}
        for row, (key, label) in enumerate((
            ("id", "轨道 ID"), ("name", "名称"), ("lang", "语言"),
            ("res", "分辨率"), ("codecs", "编码"), ("role", "用途"),
            ("frame", "帧率"), ("channel", "声道"), ("range", "动态范围"),
            ("url", "轨道链接"), ("period", "DASH Period"),
            ("bwMin", "最低码率 (Kbps)"), ("bwMax", "最高码率 (Kbps)"),
            ("segsMin", "最少分片数"), ("segsMax", "最多分片数"),
            ("plistDurMin", "最短清单时长"), ("plistDurMax", "最长清单时长"),
        )):
            value = tk.StringVar()
            fields[key] = value
            ttk.Label(panel, text=label).grid(row=row, column=0, sticky="w", padx=(0, 8))
            ttk.Entry(panel, textvariable=value).grid(row=row, column=1, sticky="ew", pady=2)
        order = tk.StringVar(value="all")
        row = len(fields)
        if not dropping:
            ttk.Label(panel, text="匹配后选择").grid(row=row, column=0, sticky="w")
            ttk.Combobox(panel, textvariable=order, values=("all", "best", "worst"),
                         state="readonly").grid(row=row, column=1, sticky="ew")

        def close():
            dialog.destroy()
            self.grab_set()

        def apply():
            parts = []
            for key, variable in fields.items():
                value = variable.get().strip()
                if value:
                    if key != "role" and not key.endswith(("Min", "Max")):
                        value = exact_expression(value)
                    parts.append(f"{key}={value}")
            if not dropping:
                parts.append(f"for={order.get()}")
            if dropping and not parts:
                messagebox.showerror("缺少筛选条件", "请至少填写一项筛选条件。", parent=dialog)
                return
            target.set(":".join(parts))
            close()

        dialog.protocol("WM_DELETE_WINDOW", close)
        ttk.Button(panel, text="应用", command=apply).grid(row=row + 1, column=1, sticky="e", pady=8)

    def add_mux_option(self, controls, flag):
        output = tk.StringVar(value="默认")
        muxer = tk.StringVar(value="FFmpeg")
        binary = tk.StringVar()
        skip_subtitles = tk.BooleanVar()
        keep_tracks = tk.BooleanVar()
        argument = tk.StringVar()
        self.fields.append((flag, argument, False))
        ttk.Combobox(controls, textvariable=output, state="readonly", width=12,
                     values=("默认", "MP4", "MKV", "TS")).pack(side="left")
        ttk.Checkbutton(controls, text="忽略字幕", variable=skip_subtitles).pack(side="left")
        ttk.Checkbutton(controls, text="保留轨道文件", variable=keep_tracks).pack(side="left")

        ttk.Combobox(controls, textvariable=muxer, state="readonly", width=10,
                     values=("FFmpeg", "MKVToolNix")).pack(side="left")
        ttk.Button(controls, text="选择混流程序…", command=lambda: self.pick(binary)).pack(side="left")
        ttk.Label(controls.master, textvariable=binary, wraplength=650).pack(anchor="w")

        def refresh(*_):
            if output.get() == "默认" and muxer.get() == "FFmpeg" and not (
                skip_subtitles.get() or keep_tracks.get() or binary.get()
            ):
                argument.set("")
                return
            selected_format = output.get().lower() if output.get() != "默认" else "mkv"
            selected_muxer = "mkvmerge" if muxer.get() == "MKVToolNix" else "ffmpeg"
            parts = [f"format={selected_format}", f"muxer={selected_muxer}"]
            if binary.get():
                parts.append("bin_path=" + binary.get().replace(":", r"\:"))
            if skip_subtitles.get():
                parts.append("skip_sub=true")
            if keep_tracks.get():
                parts.append("keep=true")
            argument.set(":".join(parts))

        for variable in (output, muxer, binary, skip_subtitles, keep_tracks):
            variable.trace_add("write", refresh)

    def execute(self):
        operation = TOOLS[self.operation.get()]
        address = self.address.get().strip()
        if not operation and not address:
            messagebox.showerror("缺少输入", "请粘贴链接或选择本地清单。", parent=self)
            return
        args = [str(self.core), operation or address]
        selected = {}
        for flag, variable, boolean in self.fields:
            value = variable.get().strip()
            if not value or (boolean and value == "默认"):
                continue
            if flag == "--mux-after-done" and "muxer=mkvmerge" in value and not value.startswith("format=mkv:"):
                messagebox.showerror("混流格式不兼容", "MKVToolNix 只支持输出 MKV。", parent=self)
                return
            argument = ("true" if value == "启用" else "false") if boolean else value
            selected[flag] = argument
            args.extend([flag, argument])
        try:
            if not operation:
                args.extend(download_defaults(selected, self.directory, {flag for flag, _, _ in self.fields}))
            title = self.operation.get()
            if not operation:
                title = selected.get("--save-name") or urlsplit(address).hostname or Path(address).name
            self.app.launch(args, self.directory, "正在运行…", title)
        except (OSError, ValueError) as error:
            messagebox.showerror("无法启动核心", str(error), parent=self)
            return
        self.destroy()
