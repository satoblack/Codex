"""Lightning.ai uyumlu torrent indirici.

Kullanım seçenekleri:
1) Jupyter/Lightning paneli:

    from torrent_resume_lightning import launch_torrent_panel
    launch_torrent_panel()

2) Saf Python (widgets olmadan):

    from torrent_resume_lightning import TorrentDownloader

    dl = TorrentDownloader()
    dl.enqueue_magnet("magnet:?xt=urn:btih:...")
    dl.run()
"""

from __future__ import annotations

import hashlib
import os
import time
from pathlib import Path
from typing import Any

try:
    import libtorrent as lt
except Exception:
    lt = None

try:
    import ipywidgets as widgets
    from IPython.display import clear_output, display
except Exception:
    widgets = None
    clear_output = None
    display = None


def _resolve_base_dir() -> Path:
    """Lightning üzerinde kalıcı bir klasör seç.

    Öncelik:
    1) TORRENT_BASE_DIR env
    2) /teamspace/studios/this_studio (Lightning persistent volume)
    3) mevcut çalışma dizini
    """

    env_dir = os.getenv("TORRENT_BASE_DIR")
    if env_dir:
        return Path(env_dir).expanduser().resolve()

    lightning_default = Path("/teamspace/studios/this_studio")
    if lightning_default.exists():
        return lightning_default.resolve()

    return Path.cwd().resolve()


def _build_session() -> "lt.session":
    if lt is None:
        raise RuntimeError("libtorrent yüklü değil. Önce `pip install libtorrent==2.0.11` çalıştırın.")

    session = lt.session()
    session.start_dht()
    session.start_upnp()

    fast_settings = {
        "connections_limit": 8000,
        "connection_speed": 500,
        "active_downloads": 200,
        "active_seeds": 200,
        "active_limit": 600,
        "active_checking": 50,
        "active_dht_limit": 300,
        "active_tracker_limit": 300,
        "active_lsd_limit": 300,
        "active_upnp_limit": 300,
        "max_out_request_queue": 5000,
        "request_timeout": 8,
        "peer_timeout": 20,
        "tick_interval": 200,
        "dl_rate_limit": 0,
        "ul_rate_limit": 0,
    }

    try:
        session.apply_settings(fast_settings)
    except Exception:
        session.set_settings(fast_settings)

    return session


def _torrent_key(kind: str, data: str) -> str:
    return hashlib.sha1(f"{kind}:{data}".encode()).hexdigest()


class TorrentDownloader:
    """Lightning üzerinde çalışacak queue/resume destekli torrent indirici."""

    def __init__(self, base_dir: Path | None = None, max_concurrent: int = 20, checkpoint_seconds: int = 5):
        if lt is None:
            raise RuntimeError("TorrentDownloader için libtorrent gerekli: pip install libtorrent==2.0.11")

        self.base_dir = (base_dir or _resolve_base_dir()).resolve()
        self.download_dir = self.base_dir / "Torrent"
        self.resume_dir = self.base_dir / ".torrent_resume"
        self.tmp_torrent_dir = self.base_dir / ".tmp_torrents"

        for p in (self.download_dir, self.resume_dir, self.tmp_torrent_dir):
            p.mkdir(parents=True, exist_ok=True)

        self.session = _build_session()
        self.max_concurrent = max_concurrent
        self.checkpoint_seconds = checkpoint_seconds

        self.queue: list[dict[str, str]] = []
        self.active: list[tuple[lt.torrent_handle, dict[str, str]]] = []

    def enqueue_magnet(self, magnet: str) -> None:
        magnet = magnet.strip()
        if not magnet.startswith("magnet:?"):
            raise ValueError("Geçersiz magnet linki")

        key = _torrent_key("magnet", magnet)
        self.queue.append({"type": "magnet", "data": magnet, "key": key, "name": magnet[:80]})

    def enqueue_torrent_file(self, torrent_path: str | Path) -> None:
        path = Path(torrent_path).expanduser().resolve()
        if not path.exists():
            raise FileNotFoundError(path)

        key = _torrent_key("torrent", f"{path}:{path.stat().st_size}")
        self.queue.append({"type": "torrent", "data": str(path), "key": key, "name": path.name})

    def _resume_path(self, key: str) -> Path:
        return self.resume_dir / f"{key}.resume"

    def _load_resume(self, key: str) -> bytes | None:
        path = self._resume_path(key)
        return path.read_bytes() if path.exists() else None

    def _save_resume(self, handle: lt.torrent_handle, key: str) -> None:
        if not handle.is_valid():
            return

        # Libtorrent Python binding sürümlerinde resume API farklı olabiliyor.
        try:
            entry = handle.write_resume_data()
            data = lt.bencode(entry)
        except Exception:
            try:
                atp = handle.save_resume_data()
                data = lt.write_resume_data_buf(atp)
            except Exception:
                return

        self._resume_path(key).write_bytes(data)

    @staticmethod
    def _tune_handle(handle: lt.torrent_handle) -> None:
        handle.set_max_connections(1200)
        handle.set_max_uploads(800)
        handle.set_download_limit(0)
        handle.set_upload_limit(0)

    def _spawn_from_queue(self) -> None:
        while self.queue and len(self.active) < self.max_concurrent:
            item = self.queue.pop(0)
            params = lt.add_torrent_params()
            params.save_path = str(self.download_dir)

            if item["type"] == "magnet":
                params.url = item["data"]
            else:
                params.ti = lt.torrent_info(item["data"])

            resume_data = self._load_resume(item["key"])
            if resume_data:
                params.resume_data = resume_data

            handle = self.session.add_torrent(params)
            self._tune_handle(handle)
            self.active.append((handle, item))

    def tick(self) -> dict[str, Any]:
        self._spawn_from_queue()

        total_speed = 0
        total_done = 0
        lines: list[str] = []

        for handle, item in self.active[:]:
            if not handle.is_valid():
                self.active.remove((handle, item))
                continue

            st = handle.status()
            if handle.is_seed():
                self._save_resume(handle, item["key"])
                self.session.remove_torrent(handle)
                self.active.remove((handle, item))
                continue

            pct = st.progress * 100
            speed = st.download_rate
            total_speed += speed
            total_done += st.total_done
            lines.append(f"{pct:5.1f}% | {speed/1024/1024:6.2f} MB/s | {item['name'][:55]}")

        return {
            "active": len(self.active),
            "queued": len(self.queue),
            "total_speed": total_speed,
            "total_done": total_done,
            "lines": lines,
        }

    def run(self, status_callback=None) -> None:
        if not self.queue and not self.active:
            return

        started = time.time()
        last_checkpoint = time.time()

        while self.queue or self.active:
            now = time.time()
            if now - last_checkpoint >= self.checkpoint_seconds:
                for handle, item in self.active:
                    if handle.is_valid() and not handle.is_seed():
                        self._save_resume(handle, item["key"])
                last_checkpoint = now

            status = self.tick()
            if status_callback is not None:
                status_callback(int(time.time() - started), status)

            time.sleep(1)


def _extract_uploaded_files(upload_value: Any) -> list[tuple[str, bytes]]:
    """ipywidgets 7/8 için FileUpload payload normalizasyonu."""

    files: list[tuple[str, bytes]] = []

    if isinstance(upload_value, dict):
        for filename, meta in upload_value.items():
            if isinstance(meta, dict) and "content" in meta:
                files.append((filename, meta["content"]))
        return files

    if isinstance(upload_value, tuple):
        for meta in upload_value:
            if not isinstance(meta, dict):
                continue
            name = str(meta.get("name", "upload.torrent"))
            content = meta.get("content", b"")
            if content:
                files.append((name, content))

    return files


def launch_torrent_panel(max_concurrent: int = 20, checkpoint_seconds: int = 5) -> None:
    """Lightning/Jupyter için widget tabanlı torrent panelini başlat."""

    if widgets is None or clear_output is None or display is None:
        raise RuntimeError("launch_torrent_panel için ipywidgets ve IPython gerekli.")

    downloader = TorrentDownloader(max_concurrent=max_concurrent, checkpoint_seconds=checkpoint_seconds)

    magnet_input = widgets.Textarea(
        description="Magnet",
        placeholder="magnet:?xt=urn:btih:...",
        layout=widgets.Layout(width="100%", height="90px"),
    )
    upload = widgets.FileUpload(accept=".torrent", multiple=True)
    add_magnet_btn = widgets.Button(description="Magnet Ekle", button_style="primary")
    add_torrent_btn = widgets.Button(description="Torrent Ekle", button_style="primary")
    start_btn = widgets.Button(description="İndirmeyi Başlat", button_style="success")
    queue_out = widgets.Output(layout=widgets.Layout(border="1px solid #ddd", padding="8px"))
    status_out = widgets.Output(layout=widgets.Layout(border="1px solid #ddd", padding="8px"))

    def render_queue() -> None:
        with queue_out:
            clear_output(wait=True)
            print(f"Kuyruk: {len(downloader.queue)}")
            for i, item in enumerate(downloader.queue[-12:], 1):
                print(f"{i:02d}. {item['name']}")

    def add_magnet(_):
        with queue_out:
            try:
                downloader.enqueue_magnet(magnet_input.value)
                magnet_input.value = ""
            except ValueError:
                print("⚠️ Geçerli magnet girin.")
        render_queue()

    def add_torrents(_):
        files = _extract_uploaded_files(upload.value)
        if not files:
            with queue_out:
                print("⚠️ Önce .torrent dosyası yükleyin.")
            return

        for filename, content in files:
            save_file = downloader.tmp_torrent_dir / filename
            save_file.write_bytes(content)
            downloader.enqueue_torrent_file(save_file)

        try:
            upload.value = ()
        except Exception:
            try:
                upload.value.clear()
                upload._counter = 0
            except Exception:
                pass
        render_queue()

    def render_status(elapsed: int, status: dict[str, Any]) -> None:
        with status_out:
            clear_output(wait=True)
            print(f"Süre: {elapsed//3600:02d}:{(elapsed%3600)//60:02d}:{elapsed%60:02d}")
            print(f"Aktif: {status['active']} | Kuyruk: {status['queued']}")
            print(f"Toplam hız: {status['total_speed']/1024/1024:.2f} MB/s")
            print(f"İndirilen: {status['total_done']/1024/1024/1024:.2f} GB")
            print("-" * 72)
            for row in status["lines"][:20]:
                print(row)

    def run_download(_):
        if not downloader.queue and not downloader.active:
            with status_out:
                clear_output(wait=True)
                print("⚠️ Kuyruk boş.")
            return

        start_btn.disabled = True
        try:
            downloader.run(status_callback=render_status)
            with status_out:
                clear_output(wait=True)
                print("✅ Tüm indirmeler tamamlandı.")
        finally:
            start_btn.disabled = False

    add_magnet_btn.on_click(add_magnet)
    add_torrent_btn.on_click(add_torrents)
    start_btn.on_click(run_download)

    panel = widgets.VBox(
        [
            widgets.HTML(f"<b>Base klasör:</b> {downloader.base_dir}"),
            widgets.HTML(f"<b>İndirme klasörü:</b> {downloader.download_dir}"),
            magnet_input,
            widgets.HBox([add_magnet_btn, upload, add_torrent_btn, start_btn]),
            queue_out,
            status_out,
        ]
    )

    display(panel)
    render_queue()


if __name__ == "__main__":
    print("Notebook kullanımı:")
    print("from torrent_resume_lightning import launch_torrent_panel")
    print("launch_torrent_panel()")
