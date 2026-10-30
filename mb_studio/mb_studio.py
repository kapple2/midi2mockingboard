#!/usr/bin/env python3
"""Mockingboard Studio: convert MIDI files to Apple II .MBF and play .MBF files, in one window.

Convert tab: drop .mid files on the list (or Add...), pick the destination folder, press Convert.
Play tab: drop .MBF files on the list (or Add...), select one and press Play. Converted files are
added to the Play list by themselves.

It uses the converter (src/converter/converter.py) and the player's AY-3-8910 emulation
(src/win_player/win_player.py) as libraries, so it sounds and converts the same as the
command-line tools.
"""
import os
import queue
import sys
import threading
import traceback
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

HERE = os.path.dirname(os.path.abspath(__file__))
FROZEN = getattr(sys, "frozen", False)      # True inside the standalone .exe (PyInstaller)
if not FROZEN:
    sys.path.insert(0, os.path.join(HERE, "..", "converter"))
    sys.path.insert(0, os.path.join(HERE, "..", "win_player"))

import converter                    # noqa: E402
import win_player                   # noqa: E402

try:
    from tkinterdnd2 import DND_FILES, TkinterDnD
    HAVE_DND = True
except ImportError:                 # the window still works, with the Add buttons only
    HAVE_DND = False

if FROZEN and sys.platform == "darwin":     # next to the exe would be inside the .app bundle
    _OUT_BASE = os.path.join(os.path.expanduser("~"), "Documents")
elif FROZEN:
    _OUT_BASE = os.path.dirname(sys.executable)
else:
    _OUT_BASE = os.path.abspath(os.path.join(HERE, "..", ".."))
DEFAULT_OUT = os.path.join(_OUT_BASE, "mbf_out")
SAMPLE_RATE = win_player.SAMPLE_RATE


def fmt_time(seconds):
    return win_player.fmt_time(seconds)


class FileList(ttk.Frame):
    """A list box of file paths that accepts dropped files and Add / Remove / Clear buttons."""

    def __init__(self, master, patterns, title, extensions):
        super().__init__(master)
        self.extensions = extensions
        self.patterns = patterns
        self.title = title
        self.paths = []
        box = ttk.Frame(self)
        box.pack(fill="both", expand=True)
        self.listbox = tk.Listbox(box, selectmode="extended", activestyle="none", height=8)
        scroll = ttk.Scrollbar(box, command=self.listbox.yview)
        self.listbox.configure(yscrollcommand=scroll.set)
        self.listbox.pack(side="left", fill="both", expand=True)
        scroll.pack(side="right", fill="y")
        buttons = ttk.Frame(self)
        buttons.pack(fill="x", pady=(4, 0))
        ttk.Button(buttons, text="Add...", command=self.add_dialog).pack(side="left")
        ttk.Button(buttons, text="Remove", command=self.remove_selected).pack(side="left", padx=4)
        ttk.Button(buttons, text="Clear", command=self.clear).pack(side="left")
        self.hint = ttk.Label(buttons, foreground="gray",
                              text="drop files here" if HAVE_DND else "(drag and drop needs tkinterdnd2)")
        self.hint.pack(side="right")
        if HAVE_DND:
            for widget in (self.listbox, self):
                widget.drop_target_register(DND_FILES)
                widget.dnd_bind("<<Drop>>", self.on_drop)

    def on_drop(self, event):
        self.add(self.tk.splitlist(event.data))
        return event.action

    def add_dialog(self):
        names = filedialog.askopenfilenames(title=self.title, filetypes=self.patterns)
        self.add(names)

    def add(self, paths):
        for path in paths:
            path = os.path.normpath(path)
            if os.path.isdir(path):
                self.add([os.path.join(path, n) for n in sorted(os.listdir(path), key=str.lower)])
            elif path.lower().endswith(self.extensions) and path not in self.paths:
                self.paths.append(path)
                self.listbox.insert("end", os.path.basename(path))

    def selected(self):
        return [self.paths[i] for i in self.listbox.curselection()]

    def remove_selected(self):
        for i in reversed(self.listbox.curselection()):
            del self.paths[i]
            self.listbox.delete(i)

    def clear(self):
        self.paths.clear()
        self.listbox.delete(0, "end")

    def select_index(self, index):
        self.listbox.selection_clear(0, "end")
        self.listbox.selection_set(index)
        self.listbox.see(index)


class ConvertTab(ttk.Frame):
    def __init__(self, master, app):
        super().__init__(master, padding=10)
        self.app = app
        self.queue = queue.Queue()
        ttk.Label(self, text="MIDI files to convert").pack(anchor="w")
        self.files = FileList(self, [("MIDI files", "*.mid *.midi"), ("All files", "*.*")],
                              "Choose MIDI files", (".mid", ".midi"))
        self.files.pack(fill="both", expand=True)

        dest = ttk.Frame(self)
        dest.pack(fill="x", pady=(8, 0))
        ttk.Label(dest, text="Destination folder").pack(side="left")
        self.dest = tk.StringVar(value=DEFAULT_OUT)
        ttk.Entry(dest, textvariable=self.dest).pack(side="left", fill="x", expand=True, padx=6)
        ttk.Button(dest, text="Browse...", command=self.browse).pack(side="left")

        opts = ttk.Frame(self)
        opts.pack(fill="x", pady=(8, 0))
        self.drums = tk.BooleanVar(value=True)
        self.normalize = tk.BooleanVar(value=True)
        self.write_text = tk.BooleanVar(value=True)
        self.rate = tk.IntVar(value=50)
        ttk.Checkbutton(opts, text="Drums (noise)", variable=self.drums).pack(side="left")
        ttk.Checkbutton(opts, text="Scale volume", variable=self.normalize).pack(side="left", padx=10)
        ttk.Checkbutton(opts, text="Also write .txt dump", variable=self.write_text).pack(side="left")
        ttk.Label(opts, text="Tick rate (Hz)").pack(side="left", padx=(14, 4))
        ttk.Spinbox(opts, from_=16, to=255, width=5, textvariable=self.rate).pack(side="left")

        self.button = ttk.Button(self, text="Convert", command=self.start)
        self.button.pack(anchor="w", pady=8)
        self.log = tk.Text(self, height=8, state="disabled", wrap="word")
        self.log.pack(fill="both", expand=True)
        self.after(100, self.poll)

    def browse(self):
        folder = filedialog.askdirectory(title="Destination folder", initialdir=self.dest.get() or DEFAULT_OUT)
        if folder:
            self.dest.set(os.path.normpath(folder))

    def say(self, text):
        self.log.configure(state="normal")
        self.log.insert("end", text + "\n")
        self.log.see("end")
        self.log.configure(state="disabled")

    def start(self):
        paths = list(self.files.paths)
        if not paths:
            messagebox.showinfo("Convert", "Add or drop some MIDI files first.")
            return
        dest = self.dest.get().strip()
        if not dest:
            messagebox.showinfo("Convert", "Choose a destination folder.")
            return
        try:
            rate = int(self.rate.get())
        except (tk.TclError, ValueError):
            rate = 0
        if not 16 <= rate <= 255:
            messagebox.showinfo("Convert", "The tick rate must be 16-255 Hz.")
            return
        os.makedirs(dest, exist_ok=True)
        self.button.configure(state="disabled")
        settings = dict(rate=rate, normalize=self.normalize.get(), drums=self.drums.get(),
                        write_text=self.write_text.get())
        threading.Thread(target=self.work, args=(paths, dest, settings), daemon=True).start()

    def work(self, paths, dest, settings):
        for path in paths:
            base = os.path.join(dest, os.path.splitext(os.path.basename(path))[0])
            try:
                conv, gain = converter.convert_file(path, base, **settings)
                self.queue.put(("ok", base + ".MBF",
                                f"{os.path.basename(path)} -> {base}.MBF  ({len(conv.frames)} frames, "
                                f"volume x{gain:.2f}, {conv.hits} drum hits)"))
            except Exception:
                self.queue.put(("error", None, f"{os.path.basename(path)}: {traceback.format_exc(limit=1)}"))
        self.queue.put(("done", None, "Finished."))

    def poll(self):
        try:
            while True:
                kind, mbf, text = self.queue.get_nowait()
                self.say(text)
                if kind == "ok":
                    self.app.play_tab.files.add([mbf])
                elif kind == "done":
                    self.button.configure(state="normal")
        except queue.Empty:
            pass
        self.after(100, self.poll)


class PlayTab(ttk.Frame):
    def __init__(self, master, app):
        super().__init__(master, padding=10)
        self.app = app
        self.queue = queue.Queue()
        self.player = None              # win_player.Player while a song is loaded
        self.stream = None
        self.cache = {}                 # (path, mono) -> rendered audio
        self.current = None
        self.job = 0                    # incremented to cancel a render that is still running
        self.dragging = False

        ttk.Label(self, text="Songs (.MBF)").pack(anchor="w")
        self.files = FileList(self, [("Mockingboard files", "*.MBF"), ("All files", "*.*")],
                              "Choose .MBF files", (".mbf",))
        self.files.pack(fill="both", expand=True)
        self.files.listbox.bind("<Double-Button-1>", lambda e: self.play_selected())

        bar = ttk.Frame(self)
        bar.pack(fill="x", pady=(8, 0))
        ttk.Button(bar, text="Play", command=self.play_selected).pack(side="left")
        self.pause_button = ttk.Button(bar, text="Pause", command=self.toggle_pause)
        self.pause_button.pack(side="left", padx=4)
        ttk.Button(bar, text="Stop", command=self.stop).pack(side="left")
        ttk.Button(bar, text="Previous", command=lambda: self.step(-1)).pack(side="left", padx=(12, 4))
        ttk.Button(bar, text="Next", command=lambda: self.step(1)).pack(side="left")
        self.loop = tk.BooleanVar(value=False)
        self.mono = tk.BooleanVar(value=False)
        ttk.Checkbutton(bar, text="Loop", variable=self.loop, command=self.apply_loop).pack(side="left", padx=(14, 0))
        ttk.Checkbutton(bar, text="Mono", variable=self.mono).pack(side="left", padx=8)

        self.position = tk.DoubleVar(value=0)
        self.slider = ttk.Scale(self, from_=0, to=1, variable=self.position, command=self.on_slide)
        self.slider.pack(fill="x", pady=(10, 0))
        self.slider.bind("<ButtonPress-1>", lambda e: setattr(self, "dragging", True))
        self.slider.bind("<ButtonRelease-1>", self.on_slide_release)
        self.status = tk.StringVar(value="Nothing playing")
        ttk.Label(self, textvariable=self.status).pack(anchor="w", pady=(4, 0))
        self.after(100, self.poll)

    def apply_loop(self):
        if self.player:
            self.player.loop = self.loop.get()

    # -- starting a song
    def play_selected(self):
        chosen = self.files.selected()
        if not chosen:
            if not self.files.paths:
                messagebox.showinfo("Play", "Add or drop some .MBF files first.")
                return
            chosen = [self.files.paths[0]]
            self.files.select_index(0)
        self.start(chosen[0])

    def start(self, path):
        self.stop()
        self.current = path
        self.job += 1
        key = (path, self.mono.get())
        if key in self.cache:
            self.begin(path, self.cache[key])
            return
        self.status.set(f"Rendering {os.path.basename(path)}...")
        threading.Thread(target=self.render, args=(self.job, path, self.mono.get()), daemon=True).start()

    def render(self, job, path, mono):
        try:
            rate, header_loop, frames = win_player.load_mbf(path)
            audio = win_player.render(rate, frames, mono=mono)
            self.queue.put((job, path, mono, audio, None))
        except Exception as exc:
            self.queue.put((job, path, mono, None, str(exc)))

    def begin(self, path, audio):
        import sounddevice as sd
        self.player = win_player.Player(audio, self.loop.get())
        try:
            self.stream = sd.OutputStream(samplerate=SAMPLE_RATE, channels=2, dtype="int16",
                                          callback=self.player.callback)
            self.stream.start()
        except Exception as exc:
            self.player = None
            self.status.set("Cannot open the sound device")
            messagebox.showerror("Play", f"Cannot open the sound device:\n{exc}")
            return
        self.slider.configure(to=max(len(audio) / SAMPLE_RATE, 1))
        self.pause_button.configure(text="Pause")

    # -- controls
    def toggle_pause(self):
        if self.player:
            self.player.paused = not self.player.paused
            self.pause_button.configure(text="Resume" if self.player.paused else "Pause")

    def stop(self):
        self.job += 1                   # drop a render that is still running
        if self.stream:
            try:
                self.stream.stop()
                self.stream.close()
            except Exception:
                pass
        self.stream = None
        self.player = None
        self.position.set(0)
        self.pause_button.configure(text="Pause")
        self.status.set("Nothing playing")

    def step(self, delta):
        paths = self.files.paths
        if not paths:
            return
        index = paths.index(self.current) if self.current in paths else -1
        index = (index + delta) % len(paths)
        self.files.select_index(index)
        self.start(paths[index])

    def on_slide(self, value):
        pass

    def on_slide_release(self, event):
        self.dragging = False
        if self.player:
            self.player.pos = int(float(self.position.get()) * SAMPLE_RATE)
            self.player.finished = False

    # -- updating the display
    def poll(self):
        try:
            while True:
                job, path, mono, audio, error = self.queue.get_nowait()
                if job != self.job:
                    continue
                if error:
                    self.status.set(f"Cannot play {os.path.basename(path)}: {error}")
                    continue
                self.cache = {(path, mono): audio}          # keep one rendered song in memory
                self.begin(path, audio)
        except queue.Empty:
            pass
        if self.player:
            total = len(self.player.audio) / SAMPLE_RATE
            now = self.player.pos / SAMPLE_RATE
            if not self.dragging:
                self.position.set(now)
            state = "paused" if self.player.paused else "playing"
            self.status.set(f"{os.path.basename(self.current)}   {fmt_time(now)} / {fmt_time(total)}   {state}")
            if self.player.finished and not self.player.paused:
                paths = self.files.paths
                index = paths.index(self.current) if self.current in paths else -1
                if index + 1 < len(paths):
                    self.step(1)                            # play the next song in the list
                else:
                    self.stop()
        self.after(100, self.poll)


class App:
    def __init__(self):
        self.root = TkinterDnD.Tk() if HAVE_DND else tk.Tk()
        self.root.title("Mockingboard Studio")
        self.root.geometry("760x600")
        self.root.minsize(620, 480)
        notebook = ttk.Notebook(self.root)
        notebook.pack(fill="both", expand=True, padx=6, pady=6)
        self.convert_tab = ConvertTab(notebook, self)
        self.play_tab = PlayTab(notebook, self)
        notebook.add(self.convert_tab, text="Convert MIDI")
        notebook.add(self.play_tab, text="Play MBF")
        self.root.protocol("WM_DELETE_WINDOW", self.close)
        for arg in sys.argv[1:]:                            # files given on the command line
            if arg.lower().endswith((".mid", ".midi")):
                self.convert_tab.files.add([arg])
            elif arg.lower().endswith(".mbf"):
                self.play_tab.files.add([arg])
        if self.play_tab.files.paths and not self.convert_tab.files.paths:
            notebook.select(self.play_tab)

    def close(self):
        self.play_tab.stop()
        self.root.destroy()

    def run(self):
        self.root.mainloop()


if __name__ == "__main__":
    App().run()
