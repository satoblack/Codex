#!/bin/bash
#
# qBittorrent to Google Drive Otomatik Yükleyici v2.0
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
║  qBittorrent → Google Drive Otomatik Yükleyici v2.0     ║
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
# ESKİ KURULUMU TEMİZLE
# ============================================================================

echo -e "${YELLOW}Eski kurulum kontrol ediliyor...${NC}"

if systemctl is-active --quiet qbit-gdrive.service 2>/dev/null; then
    echo "Eski servis durduruluyor..."
    systemctl stop qbit-gdrive.service
fi

if systemctl is-enabled --quiet qbit-gdrive.service 2>/dev/null; then
    echo "Eski servis devre dışı bırakılıyor..."
    systemctl disable qbit-gdrive.service
fi

if [ -f "/etc/systemd/system/qbit-gdrive.service" ]; then
    echo "Eski servis dosyası siliniyor..."
    rm -f /etc/systemd/system/qbit-gdrive.service
    systemctl daemon-reload
fi

if [ -f "/usr/local/bin/qbit_gdrive_uploader.py" ]; then
    echo "Eski script siliniyor..."
    rm -f /usr/local/bin/qbit_gdrive_uploader.py
fi

echo -e "${GREEN}✓ Temizlik tamamlandı${NC}"
echo ""

# ============================================================================
# ADIM 1: Gerekli Paketleri Kur
# ============================================================================

echo -e "${YELLOW}[1/6] Gerekli paketler kontrol ediliyor...${NC}"

if ! command -v python3 &> /dev/null; then
    echo "Python3 kuruluyor..."
    apt-get update -qq
    apt-get install -y python3 python3-pip curl net-tools >/dev/null 2>&1
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

if [ -z "$QBIT_PASS" ]; then
    echo -e "${YELLOW}Şifre boş bırakıldı, 'adminadmin' kullanılacak${NC}"
    QBIT_PASS="adminadmin"
fi

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

if ! rclone listremotes 2>/dev/null | grep -q "^${REMOTE_NAME}:"; then
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
        if ! rclone listremotes 2>/dev/null | grep -q "^${REMOTE_NAME}:"; then
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
    echo -e "${YELLOW}⚠ Google Drive'a bağlanılamadı (yetkilendirme gerekebilir)${NC}"
fi

# Upload dizinini oluştur
rclone mkdir "$GDRIVE_REMOTE" 2>/dev/null || true

# ============================================================================
# ADIM 4: qBittorrent Bağlantısını Test Et
# ============================================================================

echo ""
echo -e "${YELLOW}[4/6] qBittorrent bağlantısı test ediliyor...${NC}"

# Önce Web UI'nin çalışıp çalışmadığını kontrol et
if ! netstat -tlnp 2>/dev/null | grep -q ":${QBIT_PORT}"; then
    echo -e "${RED}✗ qBittorrent Web UI port ${QBIT_PORT} dinlenmiyor!${NC}"
    echo ""
    echo -e "${YELLOW}qBittorrent Web UI'yi etkinleştirmek için:${NC}"
    echo "  1. qBittorrent'i açın"
    echo "  2. Tools → Options → Web UI"
    echo "  3. 'Web User Interface (Remote control)' kutusunu işaretleyin"
    echo "  4. Port: ${QBIT_PORT}, Username: ${QBIT_USER}, Password ayarlayın"
    echo "  5. 'Bypass authentication for clients on localhost' işaretleyin"
    echo "  6. Apply ve OK tıklayın"
    echo ""
    read -p "Web UI'yi etkinleştirdiniz mi? Devam etmek için Enter'a basın..." 
fi

# Bağlantıyı test et
TEST_RESPONSE=$(curl -s --max-time 5 \
    --header "Referer: http://${QBIT_HOST}:${QBIT_PORT}" \
    --data "username=${QBIT_USER}&password=${QBIT_PASS}" \
    "http://${QBIT_HOST}:${QBIT_PORT}/api/v2/auth/login" 2>/dev/null || echo "Fail.")

if [[ "$TEST_RESPONSE" == "Ok." ]]; then
    echo -e "${GREEN}✓ qBittorrent bağlantısı başarılı${NC}"
else
    echo -e "${YELLOW}⚠ qBittorrent'e bağlanılamadı (şu an offline olabilir)${NC}"
    echo "Script yine de kurulacak, servis başladığında bağlanmayı deneyecek."
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
    MAX_RETRIES = 5
    RETRY_DELAY = 10

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
        return {'processed': {}, 'failed': {}, 'stats': {'uploads': 0, 'bytes': 0}}
    
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
        # Remove from failed if present
        self.data['failed'].pop(hash, None)
        self._save()
    
    def mark_failed(self, hash, name):
        if hash not in self.data['failed']:
            self.data['failed'][hash] = {'name': name, 'attempts': 0}
        self.data['failed'][hash]['attempts'] += 1
        self.data['failed'][hash]['last_attempt'] = datetime.now().isoformat()
        self._save()
    
    def get_failed_count(self, hash):
        return self.data['failed'].get(hash, {}).get('attempts', 0)

class QBit:
    def __init__(self):
        self.url = f"http://{Config.QBIT_HOST}:{Config.QBIT_PORT}/api/v2"
        self.session = requests.Session()
        self.logged_in = False
    
    def login(self):
        try:
            r = self.session.post(f"{self.url}/auth/login", 
                data={
                    'username': Config.QBIT_USERNAME,
                    'password': Config.QBIT_PASSWORD
                },
                timeout=10
            )
            if r.text == "Ok.":
                logger.info("✓ qBittorrent'e giriş yapıldı")
                self.logged_in = True
                return True
            else:
                logger.error(f"qBittorrent giriş hatası: {r.text}")
        except requests.exceptions.RequestException as e:
            logger.error(f"qBittorrent bağlantı hatası: {e}")
        except Exception as e:
            logger.error(f"qBittorrent giriş exception: {e}")
        self.logged_in = False
        return False
    
    def get_completed(self):
        if not self.logged_in:
            if not self.login():
                return []
        
        try:
            r = self.session.get(f"{self.url}/torrents/info", 
                params={'filter': 'completed'},
                timeout=10
            )
            r.raise_for_status()
            return r.json()
        except requests.exceptions.RequestException as e:
            logger.error(f"Torrent listesi alınamadı: {e}")
            self.logged_in = False  # Force re-login next time
        except Exception as e:
            logger.error(f"Torrent listesi exception: {e}")
        return []

def get_size(path):
    try:
        p = Path(path)
        if p.is_file():
            return p.stat().st_size
        return sum(f.stat().st_size for f in p.rglob('*') if f.is_file())
    except:
        return 0

def upload_rclone(local_path, name):
    logger.info(f"📤 Yükleniyor: {name}")
    try:
        cmd = ['rclone', 'copy', local_path, Config.RCLONE_REMOTE, 
               '--progress', '--transfers', '4', '--checkers', '8',
               '--stats', '30s', '--log-level', 'INFO']
        
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=86400)
        
        if result.returncode == 0:
            logger.info(f"✓ Yükleme başarılı: {name}")
            return True
        else:
            logger.error(f"✗ Yükleme hatası: {name}")
            if result.stderr:
                logger.error(f"rclone stderr: {result.stderr[:500]}")
    except subprocess.TimeoutExpired:
        logger.error(f"⏱ Yükleme timeout: {name}")
    except Exception as e:
        logger.error(f"Upload exception: {e}")
    return False

def delete_local(path):
    try:
        p = Path(path)
        if p.is_file():
            p.unlink()
            logger.info(f"🗑 Dosya silindi: {path}")
        elif p.is_dir():
            shutil.rmtree(path)
            logger.info(f"🗑 Dizin silindi: {path}")
        return True
    except Exception as e:
        logger.error(f"Silme hatası: {e}")
        return False

def main():
    logger.info("=" * 70)
    logger.info("qBittorrent → Google Drive Uploader v2.0 Başlatıldı")
    logger.info("=" * 70)
    logger.info(f"qBittorrent: http://{Config.QBIT_HOST}:{Config.QBIT_PORT}")
    logger.info(f"Google Drive: {Config.RCLONE_REMOTE}")
    logger.info(f"Kontrol Aralığı: {Config.CHECK_INTERVAL} saniye")
    logger.info("=" * 70)
    
    state = State()
    qbit = QBit()
    
    # Initial login attempt
    qbit.login()
    
    iteration = 0
    while True:
        try:
            iteration += 1
            logger.info(f"--- Kontrol #{iteration} ---")
            
            torrents = qbit.get_completed()
            
            if torrents:
                logger.info(f"Tamamlanan torrent sayısı: {len(torrents)}")
            
            for t in torrents:
                h, name = t['hash'], t['name']
                
                # Skip if already processed
                if state.is_processed(h):
                    continue
                
                # Check if failed too many times
                if state.get_failed_count(h) >= Config.MAX_RETRIES:
                    logger.warning(f"⚠ Çok fazla başarısız deneme, atlanıyor: {name}")
                    continue
                
                # Check if truly completed
                progress = t.get('progress', 0)
                if progress < 1.0:
                    logger.debug(f"Henüz tamamlanmamış (%{progress*100:.1f}): {name}")
                    continue
                
                local_path = os.path.join(t['save_path'], name)
                
                if not os.path.exists(local_path):
                    logger.warning(f"⚠ Dosya bulunamadı: {local_path}")
                    state.mark_failed(h, name)
                    continue
                
                logger.info(f"🔄 İşleniyor: {name}")
                size = get_size(local_path)
                logger.info(f"  📊 Boyut: {size / (1024**3):.2f} GB")
                logger.info(f"  📁 Yol: {local_path}")
                
                if upload_rclone(local_path, name):
                    if delete_local(local_path):
                        state.mark_done(h, name, size)
                        logger.info(f"✅ Tamamlandı: {name}")
                    else:
                        logger.warning(f"⚠ Dosya silinemedi ama yükleme başarılı: {name}")
                        state.mark_done(h, name, size)
                else:
                    state.mark_failed(h, name)
                    logger.error(f"❌ Yükleme başarısız: {name}")
            
            # Print statistics
            stats = state.data['stats']
            failed_count = len(state.data['failed'])
            logger.info(f"📊 İstatistikler: {stats['uploads']} yükleme, "
                       f"{stats['bytes'] / (1024**3):.2f} GB toplam, "
                       f"{failed_count} başarısız")
            
            logger.info(f"⏳ {Config.CHECK_INTERVAL} saniye bekleniyor...")
            time.sleep(Config.CHECK_INTERVAL)
            
        except KeyboardInterrupt:
            logger.info("👋 Kapatılıyor...")
            break
        except Exception as e:
            logger.error(f"❌ Beklenmeyen hata: {e}", exc_info=True)
            logger.info(f"⏳ {Config.RETRY_DELAY} saniye sonra yeniden denenecek...")
            time.sleep(Config.RETRY_DELAY)

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
read -p "Servisi şimdi başlat? (e/h) [e]: " -n 1 -r
echo

if [[ -z $REPLY ]] || [[ $REPLY =~ ^[Ee]$ ]]; then
    systemctl start qbit-gdrive.service
    sleep 3
    
    if systemctl is-active --quiet qbit-gdrive.service; then
        echo -e "${GREEN}✓ Servis çalışıyor!${NC}"
        echo ""
        echo "İlk birkaç log satırı:"
        tail -n 10 /var/log/qbit_gdrive.log
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
echo "  Canlı log izle:    tail -f /var/log/qbit_gdrive.log"
echo "  Servis durumu:     systemctl status qbit-gdrive"
echo "  Servisi durdur:    systemctl stop qbit-gdrive"
echo "  Servisi başlat:    systemctl start qbit-gdrive"
echo "  Servisi yeniden:   systemctl restart qbit-gdrive"
echo "  İstatistikler:     cat /var/lib/qbit_gdrive_state.json | python3 -m json.tool"
echo ""
echo -e "${YELLOW}⚠ ÖNEMLI: qBittorrent Web UI'nin aktif olduğundan emin olun!${NC}"
echo -e "${YELLOW}  Tools → Options → Web UI → 'Web User Interface' işaretli olmalı${NC}"
echo ""
echo -e "${GREEN}Hemen logları izlemek için:${NC}"
echo -e "${BLUE}  tail -f /var/log/qbit_gdrive.log${NC}"
echo ""
