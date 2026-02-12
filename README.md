# Codex

Bu repo, Google Colab için hazırlanmış torrent notebook'unun Lightning.ai üzerinde çalışacak Python sürümünü içerir.

## Dosyalar
- `Torrent_Resume_Complete.ipynb`: Orijinal Colab notebook.
- `torrent_resume_lightning.py`: Lightning.ai/Jupyter uyumlu Python sürümü.

## Kurulum
```bash
pip install --upgrade pip setuptools wheel
pip install libtorrent==2.0.11 ipywidgets
```

## Lightning.ai üzerinde kullanım (Notebook / Widget panel)
```python
from torrent_resume_lightning import launch_torrent_panel
launch_torrent_panel()
```

## Saf Python kullanım (widget olmadan)
```python
from torrent_resume_lightning import TorrentDownloader

dl = TorrentDownloader(max_concurrent=20, checkpoint_seconds=5)
dl.enqueue_magnet("magnet:?xt=urn:btih:...")
# veya: dl.enqueue_torrent_file("/path/to/file.torrent")
dl.run()
```

## Veri dizini
İsterseniz veri konumunu `TORRENT_BASE_DIR` ile özelleştirebilirsiniz:
```python
import os
os.environ["TORRENT_BASE_DIR"] = "/teamspace/studios/this_studio"
```

Varsayılan olarak `/teamspace/studios/this_studio` varsa orayı, yoksa mevcut çalışma dizinini kullanır.
