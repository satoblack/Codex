#!/bin/bash
#
# qBittorrent to Google Drive Otomatik Yükleyici
# Tamamlanan torrent'leri otomatik olarak Google Drive'a yükler ve yerel dosyaları siler
#
# Kurulum: sudo bash qbit_gdrive_auto.sh
#

set -e

# Renkler
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}"
cat << "EOF"
╔══════════════════════════════════════════════════════════╗
║  qBittorrent → Google Drive Otomatik Yükleyici          ║
║  Torrent tamamlandığında otomatik GDrive upload         ║
╚══════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

# Root kontrolü
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Lütfen root olarak çalıştırın: sudo bash $0${NC}"
    exit 1
fi

# ============================================================================
# ADIM 1: Gerekli Paketleri Kur
# ============================================================================

echo -e "${YELLOW}[1/6] Gerekli paketler kontrol ediliyor...${NC}"

if ! command -v python3 &> /dev/null; then
    echo "Python3 kuruluyor..."
    apt-get update -qq
    apt-get install -y python3 python3-pip curl >/dev/null 2>&1
fi

if ! python3 -c "import requests" 2>/dev/null; then
    echo "Python requests modülü kuruluyor..."
    pip3 install requests >/dev/null 2>&1
fi

if ! command -v rclone &> /dev/null; then
    echo "rclone kuruluyor..."
    curl -s https://rclone.org/install.sh | bash >/dev/null 2>&1
fi

echo -e "${GREEN}✓ Tüm paketler hazır${NC}"

# ============================================================================
# ADIM 2: Kullanıcıdan Bilgileri Al
# ============================================================================

echo ""
echo -e "${YELLOW}[2/6] Yapılandırma bilgileri${NC}"

# qBittorrent ayarları
read -p "qBittorrent Web UI Host [localhost]: " QBIT_HOST
QBIT_HOST=${QBIT_HOST:-localhost}

read -p "qBittorrent Web UI Port [8080]: " QBIT_PORT
QBIT_PORT=${QBIT_PORT:-8080}

read -p "qBittorrent Kullanıcı Adı [admin]: " QBIT_USER
QBIT_USER=${QBIT_USER:-admin}

read -sp "qBittorrent Şifre: " QBIT_PASS
echo ""

# İndirme dizini
DEFAULT_DIR="/root/Downloads/[1TB]-LGL.V42.All.Guns.Blazing-LGL/"
read -p "İndirme Dizini [$DEFAULT_DIR]: " DOWNLOAD_DIR
DOWNLOAD_DIR=${DOWNLOAD_DIR:-$DEFAULT_DIR}

# Google Drive uzak yol
read -p "Google Drive Remote Yolu [gdrive:/LGL_UPLOAD]: " GDRIVE_REMOTE
GDRIVE_REMOTE=${GDRIVE_REMOTE:-gdrive:/LGL_UPLOAD}

# Kontrol aralığı
read -p "Kontrol Aralığı (saniye) [60]: " CHECK_INTERVAL
CHECK_INTERVAL=${CHECK_INTERVAL:-60}

echo -e "${GREEN}✓ Yapılandırma alındı${NC}"

# ============================================================================
# ADIM 3: rclone Kontrolü ve Yapılandırması
# ============================================================================

echo ""
echo -e "${YELLOW}[3/6] rclone kontrol ediliyor...${NC}"

REMOTE_NAME=$(echo "$GDRIVE_REMOTE" | cut -d':' -f1)

if ! rclone listremotes | grep -q "^${REMOTE_NAME}:"; then
    echo -e "${RED}rclone remote '${REMOTE_NAME}' bulunamadı!${NC}"
    echo ""
    echo "Lütfen önce rclone'u yapılandırın:"
    echo "  1. Başka bir terminal açın"
    echo "  2. 'rclone config' komutunu çalıştırın"
    echo "  3. 'n' ile yeni remote ekleyin"
    echo "  4. Remote adı: ${REMOTE_NAME}"
    echo "  5. Google Drive seçin ve kimlik doğrulama yapın"
    echo ""
    read -p "rclone config'i şimdi açmak ister misiniz? (e/h): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Ee]$ ]]; then
        rclone config
        if ! rclone listremotes | grep -q "^${REMOTE_NAME}:"; then
            echo -e "${RED}Remote hala yapılandırılmamış. Çıkılıyor.${NC}"
            exit 1
        fi
    else
        echo -e "${RED}rclone yapılandırması gerekli. Çıkılıyor.${NC}"
        exit 1
    fi
fi

# Google Drive bağlantısını test et
if rclone lsd "${REMOTE_NAME}:" >/dev/null 2>&1; then
    echo -e "${GREEN}✓ Google Drive bağlantısı başarılı${NC}"
else
    echo -e "${RED}✗ Google Drive'a bağlanılamadı${NC}"
    echo "rclone yetkilendirmesini yenilemeniz gerekebilir"
    read -p "Devam etmek istiyor musunuz? (e/h): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Ee]$ ]]; then
        exit 1
    fi
fi

# Upload dizinini oluştur
rclone mkdir "$GDRIVE_REMOTE" 2>/dev/null || true

# ============================================================================
# ADIM 4: qBittorrent Bağlantısını Test Et
# ============================================================================

echo ""
echo -e "${YELLOW}[4/6] qBittorrent bağlantısı test ediliyor...${NC}"

TEST_RESPONSE=$(curl -s --header "Referer: http://${QBIT_HOST}:${QBIT_PORT}" \
    --data "username=${QBIT_USER}&password=${QBIT_PASS}" \
    "http://${QBIT_HOST}:${QBIT_PORT}/api/v2/auth/login" 2>/dev/null || echo "Fail.")

if [[ "$TEST_RESPONSE" == "Ok." ]]; then
    echo -e "${GREEN}✓ qBittorrent bağlantısı başarılı${NC}"
else
    echo -e "${RED}✗ qBittorrent'e bağlanılamadı${NC}"
    echo "Lütfen kontrol edin:"
    echo "  - qBittorrent çalışıyor mu?"
    echo "  - Web UI etkin mi? (Araçlar → Seçenekler → Web UI)"
    echo "  - Kullanıcı adı ve şifre doğru mu?"
    read -p "Yine de devam etmek istiyor musunuz? (e/h): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Ee]$ ]]; then
        exit 1
    fi
fi

# ============================================================================
# ADIM 5: Python Scriptini Oluştur
# ============================================================================

echo ""
echo -e "${YELLOW}[5/6] Script oluşturuluyor...${NC}"

SCRIPT_PATH="/usr/local/bin/qbit_gdrive_uploader.py"

cat > "$SCRIPT_PATH" << 'PYTHON_SCRIPT_EOF'
#!/usr/bin/env python3
import os, sys, time, logging, subprocess, json, shutil, requests
from datetime import datetime
from pathlib import Path

class Config:
    QBIT_HOST = "PLACEHOLDER_QBIT_HOST"
    QBIT_PORT = PLACEHOLDER_QBIT_PORT
    QBIT_USERNAME = "PLACEHOLDER_QBIT_USER"
    QBIT_PASSWORD = "PLACEHOLDER_QBIT_PASS"
    DOWNLOAD_DIR = "PLACEHOLDER_DOWNLOAD_DIR"
    RCLONE_REMOTE = "PLACEHOLDER_GDRIVE_REMOTE"
    CHECK_INTERVAL = PLACEHOLDER_CHECK_INTERVAL
    LOG_FILE = "/var/log/qbit_gdrive.log"
    STATE_FILE = "/var/lib/qbit_gdrive_state.json"

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(Config.LOG_FILE),
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger('QbitGDrive')

class State:
    def __init__(self):
        self.file = Config.STATE_FILE
        self.data = self._load()
    
    def _load(self):
        if os.path.exists(self.file):
            try:
                with open(self.file) as f:
                    return json.load(f)
            except:
                pass
        return {'processed': {}, 'stats': {'uploads': 0, 'bytes': 0}}
    
    def _save(self):
        os.makedirs(os.path.dirname(self.file), exist_ok=True)
        with open(self.file, 'w') as f:
            json.dump(self.data, f, indent=2)
    
    def is_processed(self, hash):
        return hash in self.data['processed']
    
    def mark_done(self, hash, name, size):
        self.data['processed'][hash] = {
            'name': name,
            'time': datetime.now().isoformat(),
            'size': size
        }
        self.data['stats']['uploads'] += 1
        self.data['stats']['bytes'] += size
        self._save()

class QBit:
    def __init__(self):
        self.url = f"http://{Config.QBIT_HOST}:{Config.QBIT_PORT}/api/v2"
        self.session = requests.Session()
        self.login()
    
    def login(self):
        try:
            r = self.session.post(f"{self.url}/auth/login", data={
                'username': Config.QBIT_USERNAME,
                'password': Config.QBIT_PASSWORD
            })
            if r.text == "Ok.":
                logger.info("qBittorrent'e giriş yapıldı")
                return True
        except Exception as e:
            logger.error(f"qBittorrent giriş hatası: {e}")
        return False
    
    def get_completed(self):
        try:
            r = self.session.get(f"{self.url}/torrents/info", params={'filter': 'completed'})
            return r.json()
        except Exception as e:
            logger.error(f"Torrent listesi alınamadı: {e}")
            return []

def get_size(path):
    p = Path(path)
    if p.is_file():
        return p.stat().st_size
    return sum(f.stat().st_size for f in p.rglob('*') if f.is_file())

def upload_rclone(local_path, name):
    logger.info(f"Yükleniyor: {name}")
    try:
        cmd = ['rclone', 'copy', local_path, Config.RCLONE_REMOTE, 
               '--progress', '--transfers', '4']
        result = subprocess.run(cmd, capture_output=True, timeout=86400)
        if result.returncode == 0:
            logger.info(f"✓ Yükleme başarılı: {name}")
            return True
        logger.error(f"✗ Yükleme hatası: {name}")
    except Exception as e:
        logger.error(f"Upload exception: {e}")
    return False

def delete_local(path):
    try:
        p = Path(path)
        if p.is_file():
            p.unlink()
        elif p.is_dir():
            shutil.rmtree(path)
        logger.info(f"Silindi: {path}")
        return True
    except Exception as e:
        logger.error(f"Silme hatası: {e}")
        return False

def main():
    logger.info("=" * 60)
    logger.info("qBittorrent → Google Drive Uploader Başlatıldı")
    logger.info("=" * 60)
    
    state = State()
    qbit = QBit()
    
    iteration = 0
    while True:
        try:
            iteration += 1
            logger.info(f"--- Kontrol #{iteration} ---")
            
            torrents = qbit.get_completed()
            logger.info(f"Tamamlanan torrent: {len(torrents)}")
            
            for t in torrents:
                h, name = t['hash'], t['name']
                
                if state.is_processed(h):
                    continue
                
                if t['progress'] < 1.0:
                    continue
                
                local_path = os.path.join(t['save_path'], name)
                if not os.path.exists(local_path):
                    logger.warning(f"Dosya bulunamadı: {local_path}")
                    continue
                
                logger.info(f"İşleniyor: {name}")
                size = get_size(local_path)
                logger.info(f"  Boyut: {size / (1024**3):.2f} GB")
                
                if upload_rclone(local_path, name):
                    if delete_local(local_path):
                        state.mark_done(h, name, size)
                        logger.info(f"✓ Tamamlandı: {name}")
                    else:
                        logger.warning(f"Dosya silinemedi: {name}")
            
            stats = state.data['stats']
            logger.info(f"İstatistikler: {stats['uploads']} yükleme, "
                       f"{stats['bytes'] / (1024**3):.2f} GB toplam")
            
            time.sleep(Config.CHECK_INTERVAL)
            
        except KeyboardInterrupt:
            logger.info("Kapatılıyor...")
            break
        except Exception as e:
            logger.error(f"Hata: {e}")
            time.sleep(60)

if __name__ == "__main__":
    main()
PYTHON_SCRIPT_EOF

# Placeholder'ları değiştir
sed -i "s|PLACEHOLDER_QBIT_HOST|${QBIT_HOST}|g" "$SCRIPT_PATH"
sed -i "s|PLACEHOLDER_QBIT_PORT|${QBIT_PORT}|g" "$SCRIPT_PATH"
sed -i "s|PLACEHOLDER_QBIT_USER|${QBIT_USER}|g" "$SCRIPT_PATH"
sed -i "s|PLACEHOLDER_QBIT_PASS|${QBIT_PASS}|g" "$SCRIPT_PATH"
sed -i "s|PLACEHOLDER_DOWNLOAD_DIR|${DOWNLOAD_DIR}|g" "$SCRIPT_PATH"
sed -i "s|PLACEHOLDER_GDRIVE_REMOTE|${GDRIVE_REMOTE}|g" "$SCRIPT_PATH"
sed -i "s|PLACEHOLDER_CHECK_INTERVAL|${CHECK_INTERVAL}|g" "$SCRIPT_PATH"

chmod +x "$SCRIPT_PATH"
chmod 600 "$SCRIPT_PATH"

echo -e "${GREEN}✓ Script oluşturuldu: $SCRIPT_PATH${NC}"

# ============================================================================
# ADIM 6: Systemd Servisi Oluştur
# ============================================================================

echo ""
echo -e "${YELLOW}[6/6] Systemd servisi kuruluyor...${NC}"

SERVICE_FILE="/etc/systemd/system/qbit-gdrive.service"

cat > "$SERVICE_FILE" << EOF
[Unit]
Description=qBittorrent to Google Drive Auto Uploader
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 $SCRIPT_PATH
Restart=always
RestartSec=30
StandardOutput=append:/var/log/qbit_gdrive.log
StandardError=append:/var/log/qbit_gdrive.log

[Install]
WantedBy=multi-user.target
EOF

# Systemd'yi yenile ve servisi başlat
systemctl daemon-reload
systemctl enable qbit-gdrive.service

echo -e "${GREEN}✓ Servis etkinleştirildi${NC}"

# ============================================================================
# Servisi Başlat
# ============================================================================

echo ""
echo -e "${BLUE}Servis başlatılsın mı?${NC}"
read -p "Servisi şimdi başlat? (e/h): " -n 1 -r
echo

if [[ $REPLY =~ ^[Ee]$ ]]; then
    systemctl start qbit-gdrive.service
    sleep 2
    
    if systemctl is-active --quiet qbit-gdrive.service; then
        echo -e "${GREEN}✓ Servis çalışıyor!${NC}"
    else
        echo -e "${RED}✗ Servis başlatılamadı${NC}"
        echo "Logları kontrol edin: journalctl -u qbit-gdrive -n 50"
    fi
fi

# ============================================================================
# Özet ve Komutlar
# ============================================================================

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║              KURULUM TAMAMLANDI! ✓                       ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}Yapılandırma:${NC}"
echo "  qBittorrent: http://${QBIT_HOST}:${QBIT_PORT}"
echo "  İndirme Dizini: ${DOWNLOAD_DIR}"
echo "  Google Drive: ${GDRIVE_REMOTE}"
echo "  Kontrol Aralığı: ${CHECK_INTERVAL} saniye"
echo ""
echo -e "${GREEN}Kullanışlı Komutlar:${NC}"
echo "  Servis durumu:     systemctl status qbit-gdrive"
echo "  Log görüntüle:     tail -f /var/log/qbit_gdrive.log"
echo "  Servisi durdur:    systemctl stop qbit-gdrive"
echo "  Servisi başlat:    systemctl start qbit-gdrive"
echo "  Servisi yeniden:   systemctl restart qbit-gdrive"
echo "  İstatistikler:     cat /var/lib/qbit_gdrive_state.json"
echo ""
echo -e "${YELLOW}Not: Torrent'ler %100'e ulaştığında otomatik olarak${NC}"
echo -e "${YELLOW}     Google Drive'a yüklenecek ve yerel dosyalar silinecek.${NC}"
echo ""
