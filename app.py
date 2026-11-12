import queue
import shutil
import subprocess
import threading
from collections import deque
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, font, messagebox, ttk
from urllib.parse import urlsplit

from core import FLAGS, HOME, active_core, update_core
from options import OptionsDialog


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("流媒体下载")
        self.geometry("1050x700")
        self.minsize(740, 540)
        self.events = queue.Queue(maxsize=512)
        self.busy = False
        self.process = None
        self.stopping = False
        self.url = tk.StringVar()
        self.directory = tk.StringVar(value=str(HOME / "Downloads"))
        self.name = tk.StringVar()
        self.status = tk.StringVar(value="就绪")
        self.version = tk.StringVar()

        self.tasks = {}
        self.active_task = None
        self.task_filter = tk.StringVar(value="全部任务")
        background, surface, ink, muted = "#f0f4f8", "#ffffff", "#172841", "#52667e"
        border, accent = "#d7e1eb", "#185bcc"
        self.configure(background=background)
        style = ttk.Style(self)
        style.theme_use("clam")
        default_font = font.nametofont("TkDefaultFont")
        for family in ("Microsoft YaHei UI", "PingFang SC", "Noto Sans CJK SC"):
            if family in font.families(self):
                default_font.configure(family=family, size=10)
                break
        style.configure(".", background=background, foreground=ink, font="TkDefaultFont")
        style.configure("TButton", background=surface, bordercolor=border, padding=(12, 7))
        style.map("TButton", background=[("active", "#e6eef9"), ("disabled", "#e9eef4")],
                  foreground=[("disabled", muted)])
        style.configure("Primary.TButton", background=accent, foreground="white",
                        bordercolor=accent, padding=(14, 8))
        style.map("Primary.TButton", background=[("disabled", "#dde7f3"), ("active", "#134da9")],
                  foreground=[("disabled", muted), ("!disabled", "white")])
        style.configure("TEntry", fieldbackground=surface, bordercolor=border, padding=6)
        style.configure("TLabelframe", bordercolor=border, relief="solid")
        style.configure("TLabelframe.Label", foreground=ink, font=(default_font.actual("family"), 10, "bold"))
        style.configure("Task.Treeview", background=surface, fieldbackground=surface,
                        bordercolor=border, rowheight=max(32, default_font.metrics("linespace") + 12))
        style.configure("Task.Treeview.Heading", background="#e6eef8", foreground=muted, padding=(10, 7))
        style.map("Task.Treeview", background=[("selected", "#d8e7fc")], foreground=[("selected", ink)])
        style.configure("Toolbar.TButton", padding=(12, 8))
        style.configure("Title.TLabel", font=(default_font.actual("family"), 19, "bold"))
        style.configure("Muted.TLabel", foreground=muted)
        style.configure("Error.TLabel", foreground="#a62b33")

        style.configure("Rail.TFrame", background="#10213a")
        style.configure("RailTitle.TLabel", background="#10213a", foreground="#ffffff",
                        font=(default_font.actual("family"), 17, "bold"))
        style.configure("RailLabel.TLabel", background="#10213a", foreground="#a9bbd1")
        style.configure("Rail.TRadiobutton", background="#10213a", foreground="#d8e5f5",
                        padding=(10, 8), indicatorcolor="#263c58", borderwidth=0)
        style.map("Rail.TRadiobutton",
                  background=[("selected", "#25456c"), ("active", "#1a3455")],
                  foreground=[("selected", "#ffffff")],
                  indicatorcolor=[("selected", "#71a8ff")])
        style.configure("Section.TLabel", font=(default_font.actual("family"), 21, "bold"))
        style.configure("LogTitle.TLabel", font=(default_font.actual("family"), 11, "bold"))

        workspace = ttk.Frame(self)
        workspace.pack(fill="both", expand=True)
        sidebar = ttk.Frame(workspace, style="Rail.TFrame", padding=(18, 22))
        sidebar.pack(side="left", fill="y")
        ttk.Label(sidebar, text="流媒体下载", style="RailTitle.TLabel").pack(anchor="w", pady=(0, 32))
        ttk.Label(sidebar, text="任务视图", style="RailLabel.TLabel").pack(anchor="w", pady=(0, 5))
        for label in ("全部任务", "运行中", "已结束"):
            ttk.Radiobutton(sidebar, text=label, value=label, variable=self.task_filter,
                            style="Rail.TRadiobutton", command=self.refresh_tasks).pack(fill="x", pady=2)
        self.update_button = ttk.Button(sidebar, text="安装 / 更新核心", command=self.install_core)
        self.update_button.pack(side="bottom", fill="x", pady=(8, 0))
        ttk.Label(sidebar, textvariable=self.version, style="RailLabel.TLabel").pack(side="bottom", anchor="w")

        main = ttk.Frame(workspace, padding=(22, 18))
        main.pack(side="left", fill="both", expand=True)
        toolbar = ttk.Frame(main)
        toolbar.pack(fill="x", pady=(0, 15))
        ttk.Label(toolbar, textvariable=self.task_filter, style="Section.TLabel").pack(side="left")
        self.start_button = ttk.Button(toolbar, text="＋ 新建下载", style="Primary.TButton",
                                       command=self.new_download)
        self.start_button.pack(side="right")
        ttk.Button(toolbar, text="选项与工具", command=self.advanced).pack(side="right", padx=8)
        self.stop_button = ttk.Button(toolbar, text="停止", command=self.stop, state="disabled")
        self.stop_button.pack(side="right")
        panes = ttk.Panedwindow(main, orient="vertical")
        panes.pack(fill="both", expand=True)
        table_panel = ttk.Frame(panes)
        panes.add(table_panel, weight=3)
        self.table = ttk.Treeview(table_panel, columns=("task", "state", "folder"),
                                  show="headings", selectmode="browse", style="Task.Treeview")
        for key, title, width in (("task", "任务", 245), ("state", "状态", 125), ("folder", "工作目录", 220)):
            self.table.heading(key, text=title, anchor="w")
            self.table.column(key, width=width, minwidth=72, stretch=key != "state")
        task_scroll = ttk.Scrollbar(table_panel, command=self.table.yview)
        self.table.configure(yscrollcommand=task_scroll.set)
        task_scroll.pack(side="right", fill="y")
        self.table.pack(fill="both", expand=True)
        self.table.bind("<<TreeviewSelect>>", self.show_task_log)
        self.empty = tk.Label(table_panel, text="暂无任务\n点击「新建下载」添加链接",
                              background=surface, foreground=muted, font="TkDefaultFont",
                              justify="center", padx=16, pady=10)
        self.empty.place(relx=.5, rely=.5, anchor="center")

        log_panel = ttk.Frame(panes, padding=(0, 8, 0, 0))
        ttk.Label(log_panel, text="任务日志", style="LogTitle.TLabel").pack(anchor="w", pady=(0, 6))
        panes.add(log_panel, weight=2)
        self.log = tk.Text(log_panel, wrap="word", state="disabled", height=7, relief="flat", background=surface,
                           foreground=ink, padx=10, pady=8, highlightthickness=0)
        scrollbar = ttk.Scrollbar(log_panel, command=self.log.yview)
        self.log.configure(yscrollcommand=scrollbar.set)
        scrollbar.pack(side="right", fill="y")
        self.log.pack(side="left", fill="both", expand=True)

        ttk.Separator(self).pack(fill="x")
        footer = ttk.Frame(self, padding=(14, 7))
        footer.pack(fill="x")
        self.status_label = ttk.Label(footer, textvariable=self.status, style="Muted.TLabel")
        self.status_label.pack(side="left", fill="x", expand=True)
        self.update_progress = ttk.Progressbar(footer, mode="indeterminate", length=80)
        self.status.trace_add("write", self.style_status)
        self.refresh_tasks()
        self.refresh_version()
        self.protocol("WM_DELETE_WINDOW", self.close)
        self.after(50, self.poll)

    def style_status(self, *_):
        failed = "失败" in self.status.get()
        self.status_label.configure(style="Error.TLabel" if failed else "Muted.TLabel")

    def refresh_tasks(self):
        selected = self.table.selection()
        self.table.delete(*self.table.get_children())
        view = self.task_filter.get()
        for key, task in reversed(self.tasks.items()):
            running = key == self.active_task
            if view == "全部任务" or (view == "运行中" and running) or (view == "已结束" and not running):
                self.table.insert("", "end", iid=key, values=(task["title"], task["status"], task["directory"]))
        if self.table.get_children():
            self.empty.place_forget()
        else:
            self.empty.configure(text="暂无任务\n点击「新建下载」添加链接" if view == "全部任务" else "此视图没有任务")
            self.empty.place(relx=.5, rely=.5, anchor="center")
        if selected and self.table.exists(selected[0]):
            self.table.selection_set(selected[0])
        self.show_task_log()

    def show_task_log(self, event=None):
        selected = self.table.selection()
        lines = self.tasks[selected[0]]["log"] if selected else ()
        self.log.configure(state="normal")
        self.log.delete("1.0", "end")
        self.log.insert("end", "".join(lines))
        self.log.see("end")
        self.log.configure(state="disabled")

    def refresh_version(self):
        try:
            _, version = active_core()
        except (OSError, ValueError, KeyError):
            version = "读取失败"
        self.version.set(f"核心：{version}")

    def new_download(self):
        dialog = tk.Toplevel(self, background=self.cget("background"))
        dialog.title("新建下载")
        dialog.transient(self)
        dialog.grab_set()
        dialog.minsize(520, 245)
        panel = ttk.Frame(dialog, padding=20)
        panel.pack(fill="both", expand=True)
        panel.columnconfigure(1, weight=1)
        for row, label, variable in (
            (0, "下载链接", self.url), (1, "保存目录", self.directory),
            (2, "文件名（选填）", self.name),
        ):
            ttk.Label(panel, text=label).grid(row=row, column=0, sticky="w", padx=(0, 10), pady=5)
            entry = ttk.Entry(panel, textvariable=variable)
            entry.grid(row=row, column=1, sticky="ew", pady=5)
            if row == 0:
                entry.focus_set()
        ttk.Button(panel, text="浏览…", command=lambda: self.browse(dialog)).grid(
            row=1, column=2, padx=(8, 0))

        def submit(event=None):
            if self.start(parent=dialog):
                dialog.destroy()

        actions = ttk.Frame(panel)
        actions.grid(row=3, column=0, columnspan=3, sticky="e", pady=(14, 0))
        ttk.Button(actions, text="取消", command=dialog.destroy).pack(side="left", padx=(0, 8))
        ttk.Button(actions, text="开始下载", style="Primary.TButton", command=submit).pack(side="left")
        dialog.bind("<Return>", submit)
        dialog.bind("<Escape>", lambda event: dialog.destroy())

    def browse(self, parent=None):
        path = filedialog.askdirectory(parent=parent or self)
        if path:
            self.directory.set(path)

    def emit(self, kind, value):
        self.events.put((kind, value))

    def poll(self):
        refresh_log = False
        for _ in range(100):
            try:
                kind, value = self.events.get_nowait()
            except queue.Empty:
                break
            if kind == "log":
                if self.active_task:
                    self.tasks[self.active_task]["log"].append(value)
                    refresh_log = self.table.selection() == (self.active_task,)
                continue
            self.status.set(value)
            if kind == "done":
                self.update_progress.stop()
                self.update_progress.pack_forget()
                if self.active_task:
                    self.tasks[self.active_task]["status"] = value
                    self.active_task = None
                    self.refresh_tasks()
                self.busy = False
                self.process = None
                self.start_button.configure(state="normal")
                self.update_button.configure(state="normal")
                self.stop_button.configure(state="disabled")
                self.refresh_version()
        if refresh_log:
            self.show_task_log()
        self.after(50, self.poll)

    def run_job(self, status, work):
        self.busy = True
        self.stopping = False
        self.start_button.configure(state="disabled")
        self.update_button.configure(state="disabled")
        self.status.set(status)

        def worker():
            try:
                result = work()
            except Exception as error:
                result = f"操作失败：{error}"
            self.emit("done", result)

        threading.Thread(target=worker, daemon=True).start()

    def install_core(self):
        self.update_progress.pack(side="right", padx=8)
        self.update_progress.start(15)
        self.run_job("正在检查上游发行版…",
                     lambda: update_core(lambda status: self.emit("status", status)))

    def advanced(self):
        if self.busy:
            messagebox.showinfo("任务进行中", "请等待当前任务结束。", parent=self)
            return
        try:
            core, _ = active_core()
            if not core:
                raise ValueError("请先安装核心")
            folder = self.directory.get().strip()
            if not folder:
                raise ValueError("请选择保存目录")
            directory = Path(folder).expanduser().resolve()
            directory.mkdir(parents=True, exist_ok=True)
            OptionsDialog(self, core, directory, self.url.get().strip())
        except (OSError, ValueError, KeyError) as error:
            messagebox.showerror("无法打开选项", str(error), parent=self)
    def start(self, parent=None):
        try:
            address = self.url.get().strip()
            url = urlsplit(address)
            if url.scheme not in ("http", "https") or not url.hostname:
                raise ValueError("请输入完整的 HTTP 或 HTTPS 下载链接")
            core, _ = active_core()
            if not core:
                raise ValueError("请先点击「安装 / 更新核心」")
            ffmpeg = shutil.which("ffmpeg")
            if not ffmpeg:
                raise ValueError("请安装 FFmpeg 并将其加入 PATH，然后重新打开本工具")
            folder = self.directory.get().strip()
            if not folder:
                raise ValueError("请选择保存目录")
            directory = Path(folder).expanduser().resolve()
            directory.mkdir(parents=True, exist_ok=True)
            args = [str(core), address, "--save-dir", str(directory), "--auto-select",
                    "--no-ansi-color", "--no-log", "--ui-language", "zh-CN",
                    "--ffmpeg-binary-path", ffmpeg, "--disable-update-check", "-M", "format=mkv"]
            if self.name.get().strip():
                args.extend(["--save-name", self.name.get().strip()])
            self.launch(args, directory, "正在下载…", self.name.get().strip() or url.hostname)
            return True
        except (OSError, ValueError, KeyError) as error:
            messagebox.showerror("无法开始下载", str(error), parent=parent or self)
            return False

    def launch(self, args, directory, status, title="上游任务"):
        self.process = subprocess.Popen(
            args, cwd=directory, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace",
            creationflags=FLAGS,
        )
        process = self.process
        self.active_task = str(len(self.tasks) + 1)
        self.tasks[self.active_task] = {
            "title": title, "status": status, "directory": str(directory), "log": deque(maxlen=3000),
        }
        if self.task_filter.get() == "已结束":
            self.task_filter.set("全部任务")
        self.refresh_tasks()
        self.table.selection_set(self.active_task)
        self.stop_button.configure(state="normal")

        def download():
            with process.stdout as output:
                for line in output:
                    self.emit("log", line)
            code = process.wait()
            if self.stopping:
                return "任务已停止"
            return "任务完成" if code == 0 else f"任务失败（退出码 {code}）"

        self.run_job(status, download)

    def stop(self):
        if self.process and self.process.poll() is None:
            self.stopping = True
            self.process.terminate()
            self.status.set("正在停止…")
            if self.active_task:
                self.tasks[self.active_task]["status"] = "正在停止…"
                self.refresh_tasks()
            self.stop_button.configure(state="disabled")

    def close(self):
        if self.busy:
            messagebox.showinfo("任务进行中", "请等待任务结束，或先停止下载。", parent=self)
        else:
            self.destroy()


if __name__ == "__main__":
    App().mainloop()
