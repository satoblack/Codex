"""Lightning.ai uyumlu torrent indirme paneli.

Jupyter/Lightning notebook içinde çalıştırmak için:

    from torrent_resume_lightning import launch_torrent_panel
    launch_torrent_panel()
"""

from __future__ import annotations

import hashlib
import os
import time
from pathlib import Path

import ipywidgets as widgets
import libtorrent as lt
from IPython.display import clear_output, display


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


def _build_session() -> lt.session:
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


def launch_torrent_panel(max_concurrent: int = 20, checkpoint_seconds: int = 5) -> None:
    """Lightning/Jupyter için widget tabanlı torrent panelini başlat."""

    base_dir = _resolve_base_dir()
    download_dir = base_dir / "Torrent"
    resume_dir = base_dir / ".torrent_resume"
    tmp_torrent_dir = base_dir / ".tmp_torrents"

    for p in (download_dir, resume_dir, tmp_torrent_dir):
        p.mkdir(parents=True, exist_ok=True)

    session = _build_session()

    queue: list[dict] = []
    active: list[tuple[lt.torrent_handle, dict]] = []

    def torrent_key(kind: str, data: str) -> str:
        return hashlib.sha1(f"{kind}:{data}".encode()).hexdigest()

    def resume_path(key: str) -> Path:
        return resume_dir / f"{key}.resume"

    def load_resume(key: str) -> bytes | None:
        path = resume_path(key)
        return path.read_bytes() if path.exists() else None

    def save_resume(handle: lt.torrent_handle, key: str) -> None:
        if not handle.is_valid():
            return
        data = lt.write_resume_data(handle)
        resume_path(key).write_bytes(data)

    def tune_handle(handle: lt.torrent_handle) -> None:
        handle.set_max_connections(1200)
        handle.set_max_uploads(800)
        handle.set_download_limit(0)
        handle.set_upload_limit(0)

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
            print(f"Kuyruk: {len(queue)}")
            for i, item in enumerate(queue[-12:], 1):
                print(f"{i:02d}. {item['name']}")

    def add_magnet(_):
        magnet = magnet_input.value.strip()
        if not magnet.startswith("magnet:?"):
            with queue_out:
                print("⚠️ Geçerli magnet girin.")
            return

        key = torrent_key("magnet", magnet)
        queue.append({"type": "magnet", "data": magnet, "key": key, "name": magnet[:80]})
        magnet_input.value = ""
        render_queue()

    def add_torrents(_):
        if not upload.value:
            with queue_out:
                print("⚠️ Önce .torrent dosyası yükleyin.")
            return

        for filename, meta in upload.value.items():
            save_file = tmp_torrent_dir / filename
            save_file.write_bytes(meta["content"])
            key = torrent_key("torrent", filename + str(len(meta["content"])))
            queue.append({"type": "torrent", "data": str(save_file), "key": key, "name": filename})

        upload.value.clear()
        upload._counter = 0
        render_queue()

    def run_download(_):
        if not queue and not active:
            with status_out:
                clear_output(wait=True)
                print("⚠️ Kuyruk boş.")
            return

        start_btn.disabled = True
        started = time.time()
        last_checkpoint = time.time()

        while queue or active:
            while queue and len(active) < max_concurrent:
                item = queue.pop(0)
                params = lt.add_torrent_params()
                params.save_path = str(download_dir)

                if item["type"] == "magnet":
                    params.url = item["data"]
                else:
                    params.ti = lt.torrent_info(item["data"])

                resume_data = load_resume(item["key"])
                if resume_data:
                    params.resume_data = resume_data

                handle = session.add_torrent(params)
                tune_handle(handle)
                active.append((handle, item))

            now = time.time()
            if now - last_checkpoint >= checkpoint_seconds:
                for handle, item in active:
                    if handle.is_valid() and not handle.is_seed():
                        save_resume(handle, item["key"])
                last_checkpoint = now

            total_speed = 0
            total_done = 0
            lines: list[str] = []

            for handle, item in active[:]:
                if not handle.is_valid():
                    active.remove((handle, item))
                    continue

                st = handle.status()
                if handle.is_seed():
                    save_resume(handle, item["key"])
                    session.remove_torrent(handle)
                    active.remove((handle, item))
                    continue

                pct = st.progress * 100
                speed = st.download_rate
                total_speed += speed
                total_done += st.total_done
                lines.append(f"{pct:5.1f}% | {speed/1024/1024:6.2f} MB/s | {item['name'][:55]}")

            with status_out:
                clear_output(wait=True)
                elapsed = int(time.time() - started)
                print(f"Süre: {elapsed//3600:02d}:{(elapsed%3600)//60:02d}:{elapsed%60:02d}")
                print(f"Aktif: {len(active)} | Kuyruk: {len(queue)}")
                print(f"Toplam hız: {total_speed/1024/1024:.2f} MB/s")
                print(f"İndirilen: {total_done/1024/1024/1024:.2f} GB")
                print("-" * 72)
                for row in lines[:20]:
                    print(row)

            time.sleep(1)

        with status_out:
            clear_output(wait=True)
            print("✅ Tüm indirmeler tamamlandı.")

        start_btn.disabled = False

    add_magnet_btn.on_click(add_magnet)
    add_torrent_btn.on_click(add_torrents)
    start_btn.on_click(run_download)

    panel = widgets.VBox(
        [
            widgets.HTML(f"<b>Base klasör:</b> {base_dir}"),
            widgets.HTML(f"<b>İndirme klasörü:</b> {download_dir}"),
            magnet_input,
            widgets.HBox([add_magnet_btn, upload, add_torrent_btn, start_btn]),
            queue_out,
            status_out,
        ]
    )

    display(panel)
    render_queue()


if __name__ == "__main__":
    print("Bu dosyayı notebook içinde import ederek çalıştırın:")
    print("from torrent_resume_lightning import launch_torrent_panel")
    print("launch_torrent_panel()")
