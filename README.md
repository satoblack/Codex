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

## Hızlı kullanım (senin torrent dosyan ile)
```python
from torrent_resume_lightning import launch_torrent_panel
launch_torrent_panel(auto_torrent_path="/teamspace/studios/this_studio/128b-Batocera.41.Mini-Honda.torrent")
```

## Notebook / Widget panel
```python
from torrent_resume_lightning import launch_torrent_panel
launch_torrent_panel()
```

> Eğer `ipywidgets` yoksa, `launch_torrent_panel` artık hata fırlatmak yerine konsol moduna düşer.
> Bu modda indirme başlatmak için `auto_torrent_path` verin.

## Saf Python kullanım (widget olmadan)
```python
from torrent_resume_lightning import TorrentDownloader

dl = TorrentDownloader(max_concurrent=20, checkpoint_seconds=5)
dl.enqueue_torrent_file("/teamspace/studios/this_studio/128b-Batocera.41.Mini-Honda.torrent")
dl.run()
```


## Script olarak çalıştırma (.py)
```bash
python torrent_resume_lightning.py --torrent /teamspace/studios/this_studio/128b-Batocera.41.Mini-Honda.torrent
```

> `--torrent` verilmezse ve yukarıdaki varsayılan dosya mevcutsa otomatik kullanılır.

## Veri dizini
İsterseniz veri konumunu `TORRENT_BASE_DIR` ile özelleştirebilirsiniz:
```python
import os
os.environ["TORRENT_BASE_DIR"] = "/teamspace/studios/this_studio"
```

Varsayılan olarak `/teamspace/studios/this_studio` varsa orayı, yoksa mevcut çalışma dizinini kullanır.
