# Codex

Bu repo, Google Colab için hazırlanmış torrent notebook'unun Lightning.ai üzerinde çalışacak Python sürümünü içerir.

## Dosyalar
- `Torrent_Resume_Complete.ipynb`: Orijinal Colab notebook.
- `torrent_resume_lightning.py`: Lightning.ai/Jupyter uyumlu Python sürümü.

## Lightning.ai üzerinde kullanım
1. Gerekli paketleri kurun:
   ```bash
   pip install --upgrade pip setuptools wheel
   pip install libtorrent==2.0.11 ipywidgets
   ```
2. Notebook hücresinde çalıştırın:
   ```python
   from torrent_resume_lightning import launch_torrent_panel
   launch_torrent_panel()
   ```
3. İsterseniz veri konumunu `TORRENT_BASE_DIR` ile özelleştirin:
   ```python
   import os
   os.environ["TORRENT_BASE_DIR"] = "/teamspace/studios/this_studio"
   ```

Varsayılan olarak `/teamspace/studios/this_studio` varsa orayı, yoksa mevcut çalışma dizinini kullanır.
