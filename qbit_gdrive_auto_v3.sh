#!/bin/bash
#
# qBittorrent to Google Drive Otomatik Yükleyici v3.0 (İYİLEŞTİRİLMİŞ)
# Tamamlanan torrent'leri otomatik olarak Google Drive'a yükler ve yerel dosyaları siler
#
# Kurulum: sudo bash qbit_gdrive_auto_v3.sh
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
║  qBittorrent → Google Drive Otomatik Yükleyici v3.0     ║
║  Torrent tamamlandığında otomatik GDrive upload         ║
║  (İyileştirilmiş debug ve hata çözümü)                  ║
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

# Google Drive uzak yol
read -p "Google Drive Remote Yolu [gdrive:/LGL_UPLOAD]: " GDRIVE_REMOTE
GDRIVE_REMOTE=${GDRIVE_REMOTE:-gdrive:/LGL_UPLOAD}

# Kontrol aralığı
read -p "Kontrol Aralığı (saniye) [30]: " CHECK_INTERVAL
CHECK_INTERVAL=${CHECK_INTERVAL:-30}

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
# ADIM 5: Python Scriptini Oluştur (İYİLEŞTİRİLMİŞ)
# ============================================================================

echo ""
echo -e "${YELLOW}[5/6] İyileştirilmiş script oluşturuluyor...${NC}"

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
    RCLONE_REMOTE = "PLACEHOLDER_GDRIVE_REMOTE"
    CHECK_INTERVAL = PLACEHOLDER_CHECK_INTERVAL
    LOG_FILE = "/var/log/qbit_gdrive.log"
    STATE_FILE = "/var/lib/qbit_gdrive_state.json"
    MAX_RETRIES = 3
    RETRY_DELAY = 60
    # Minimum progress to consider complete (99.5%)
    MIN_PROGRESS = 0.995

# Logging
os.makedirs(os.path.dirname(Config.LOG_FILE), exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(Config.LOG_FILE),
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger(__name__)

class State:
    def __init__(self):
        self.path = Config.STATE_FILE
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        self.data = self._load()
    
    def _load(self):
        if os.path.exists(self.path):
            try:
                with open(self.path, 'r') as f:
                    return json.load(f)
            except:
                pass
        return {'done': {}, 'failed': {}, 'stats': {'uploads': 0, 'bytes': 0}}
    
    def _save(self):
        try:
            with open(self.path, 'w') as f:
                json.dump(self.data, f, indent=2)
        except Exception as e:
            logger.error(f"State kayıt hatası: {e}")
    
    def is_processed(self, hash):
        return hash in self.data['done']
    
    def mark_done(self, hash, name, size):
        self.data['done'][hash] = {
            'name': name,
            'size': size,
            'time': datetime.now().isoformat()
        }
        self.data['stats']['uploads'] += 1
        self.data['stats']['bytes'] += size
        if hash in self.data['failed']:
            del self.data['failed'][hash]
        self._save()
    
    def mark_failed(self, hash, name):
        if hash not in self.data['failed']:
            self.data['failed'][hash] = {'name': name, 'count': 0, 'last': None}
        self.data['failed'][hash]['count'] += 1
        self.data['failed'][hash]['last'] = datetime.now().isoformat()
        self._save()
    
    def get_failed_count(self, hash):
        return self.data['failed'].get(hash, {}).get('count', 0)

class QBit:
    def __init__(self):
        self.base = f"http://{Config.QBIT_HOST}:{Config.QBIT_PORT}/api/v2"
        self.session = requests.Session()
        self.session.headers.update({'Referer': f"http://{Config.QBIT_HOST}:{Config.QBIT_PORT}"})
        self.logged_in = False
    
    def login(self):
        try:
            r = self.session.post(f"{self.base}/auth/login", 
                data={'username': Config.QBIT_USERNAME, 'password': Config.QBIT_PASSWORD},
                timeout=10)
            if r.text == "Ok.":
                self.logged_in = True
                logger.info("✓ qBittorrent girişi başarılı")
                return True
            else:
                logger.error(f"✗ qBittorrent giriş hatası: {r.text}")
                return False
        except Exception as e:
            logger.error(f"qBittorrent bağlantı hatası: {e}")
            return False
    
    def get_completed(self):
        if not self.logged_in:
            if not self.login():
                return []
        
        try:
            # Get ALL torrents, we'll filter by completion
            r = self.session.get(f"{self.base}/torrents/info", timeout=10)
            r.raise_for_status()
            torrents = r.json()
            
            # Log all torrents for debugging
            logger.debug(f"Toplam torrent sayısı: {len(torrents)}")
            
            completed = []
            for t in torrents:
                hash_val = t.get('hash', '')
                name = t.get('name', '')
                state = t.get('state', '')
                progress = t.get('progress', 0)
                
                # Debug: Show all torrents
                logger.debug(f"Torrent: {name[:50]}, State: {state}, Progress: {progress*100:.2f}%")
                
                # Consider "seeding" or progress >= 99.5% as completed
                # Common states: downloading, uploading, pausedUP, pausedDL, 
                # queuedUP, queuedDL, checkingUP, checkingDL, 
                # stalledUP, stalledDL, metaDL, forcedUP, forcedDL,
                # allocating, moving, missingFiles, error
                if progress >= Config.MIN_PROGRESS or state in ['uploading', 'stalledUP', 'queuedUP', 'pausedUP', 'forcedUP']:
                    logger.info(f"✓ Tamamlanmış torrent bulundu: {name} (Progress: {progress*100:.2f}%, State: {state})")
                    completed.append(t)
            
            return completed
            
        except requests.exceptions.RequestException as e:
            logger.error(f"Torrent listesi alınamadı: {e}")
            self.logged_in = False
            return []
        except Exception as e:
            logger.error(f"Beklenmeyen hata: {e}")
            return []

def get_size(path):
    try:
        if os.path.isfile(path):
            return os.path.getsize(path)
        total = 0
        for root, dirs, files in os.walk(path):
            for f in files:
                fp = os.path.join(root, f)
                if os.path.exists(fp):
                    total += os.path.getsize(fp)
        return total
    except:
        return 0

def upload_rclone(local_path, name):
    logger.info(f"📤 Yükleniyor: {name}")
    logger.info(f"   Kaynak: {local_path}")
    logger.info(f"   Hedef: {Config.RCLONE_REMOTE}")
    
    try:
        cmd = ['rclone', 'copy', local_path, Config.RCLONE_REMOTE, 
               '--progress', '--transfers', '4', '--checkers', '8',
               '--stats', '30s', '--log-level', 'INFO', '-v']
        
        # Show the command being run
        logger.debug(f"rclone komutu: {' '.join(cmd)}")
        
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=86400)
        
        if result.returncode == 0:
            logger.info(f"✓ Yükleme başarılı: {name}")
            return True
        else:
            logger.error(f"✗ Yükleme hatası (return code: {result.returncode}): {name}")
            if result.stdout:
                logger.error(f"rclone stdout: {result.stdout[:1000]}")
            if result.stderr:
                logger.error(f"rclone stderr: {result.stderr[:1000]}")
            return False
    except subprocess.TimeoutExpired:
        logger.error(f"⏱ Yükleme timeout (24 saat): {name}")
        return False
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
    logger.info("qBittorrent → Google Drive Uploader v3.0 Başlatıldı")
    logger.info("=" * 70)
    logger.info(f"qBittorrent: http://{Config.QBIT_HOST}:{Config.QBIT_PORT}")
    logger.info(f"Google Drive: {Config.RCLONE_REMOTE}")
    logger.info(f"Kontrol Aralığı: {Config.CHECK_INTERVAL} saniye")
    logger.info(f"Minimum Progress: {Config.MIN_PROGRESS*100}%")
    logger.info("=" * 70)
    
    state = State()
    qbit = QBit()
    
    # Initial login attempt
    qbit.login()
    
    iteration = 0
    while True:
        try:
            iteration += 1
            logger.info(f"")
            logger.info(f"{'='*70}")
            logger.info(f"Kontrol #{iteration} - {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
            logger.info(f"{'='*70}")
            
            torrents = qbit.get_completed()
            
            if torrents:
                logger.info(f"✓ Tamamlanan torrent sayısı: {len(torrents)}")
            else:
                logger.info(f"ℹ Tamamlanmış torrent bulunamadı")
            
            for t in torrents:
                h, name = t['hash'], t['name']
                state_str = t.get('state', 'unknown')
                progress = t.get('progress', 0)
                
                # Skip if already processed
                if state.is_processed(h):
                    logger.debug(f"⏭ Zaten işlenmiş, atlanıyor: {name}")
                    continue
                
                # Check if failed too many times
                failed_count = state.get_failed_count(h)
                if failed_count >= Config.MAX_RETRIES:
                    logger.warning(f"⚠ Çok fazla başarısız deneme ({failed_count}), atlanıyor: {name}")
                    continue
                
                # Get the actual file path
                save_path = t.get('save_path', '')
                content_path = t.get('content_path', '')
                
                # Try content_path first (full path), then construct from save_path + name
                if content_path and os.path.exists(content_path):
                    local_path = content_path
                elif save_path:
                    local_path = os.path.join(save_path, name)
                else:
                    logger.warning(f"⚠ Dosya yolu belirlenemedi: {name}")
                    logger.debug(f"   save_path: {save_path}")
                    logger.debug(f"   content_path: {content_path}")
                    state.mark_failed(h, name)
                    continue
                
                if not os.path.exists(local_path):
                    logger.warning(f"⚠ Dosya/dizin bulunamadı: {local_path}")
                    state.mark_failed(h, name)
                    continue
                
                logger.info(f"")
                logger.info(f"🔄 İşleniyor: {name}")
                logger.info(f"   Durum: {state_str}")
                logger.info(f"   Progress: {progress*100:.2f}%")
                
                size = get_size(local_path)
                logger.info(f"   📊 Boyut: {size / (1024**3):.2f} GB")
                logger.info(f"   📁 Yerel yol: {local_path}")
                
                if failed_count > 0:
                    logger.info(f"   ⚠ Önceki başarısız deneme sayısı: {failed_count}")
                
                if upload_rclone(local_path, name):
                    if delete_local(local_path):
                        state.mark_done(h, name, size)
                        logger.info(f"✅ BAŞARILI - Yüklendi ve silindi: {name}")
                    else:
                        logger.warning(f"⚠ Dosya silinemedi ama yükleme başarılı: {name}")
                        state.mark_done(h, name, size)
                else:
                    state.mark_failed(h, name)
                    logger.error(f"❌ BAŞARISIZ - Yükleme hatası: {name}")
            
            # Print statistics
            stats = state.data['stats']
            failed_count = len(state.data['failed'])
            logger.info(f"")
            logger.info(f"📊 İSTATİSTİKLER:")
            logger.info(f"   Toplam yükleme: {stats['uploads']}")
            logger.info(f"   Toplam veri: {stats['bytes'] / (1024**3):.2f} GB")
            logger.info(f"   Başarısız: {failed_count}")
            
            logger.info(f"")
            logger.info(f"⏳ {Config.CHECK_INTERVAL} saniye bekleniyor...")
            logger.info(f"{'='*70}")
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
sed -i "s|PLACEHOLDER_GDRIVE_REMOTE|${GDRIVE_REMOTE}|g" "$SCRIPT_PATH"
sed -i "s|PLACEHOLDER_CHECK_INTERVAL|${CHECK_INTERVAL}|g" "$SCRIPT_PATH"

chmod +x "$SCRIPT_PATH"
chmod 600 "$SCRIPT_PATH"

echo -e "${GREEN}✓ İyileştirilmiş script oluşturuldu: $SCRIPT_PATH${NC}"

# ============================================================================
# ADIM 6: Systemd Servisi Oluştur
# ============================================================================

echo ""
echo -e "${YELLOW}[6/6] Systemd servisi kuruluyor...${NC}"

SERVICE_FILE="/etc/systemd/system/qbit-gdrive.service"

cat > "$SERVICE_FILE" << EOF
[Unit]
Description=qBittorrent to Google Drive Auto Uploader v3.0
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
        tail -n 20 /var/log/qbit_gdrive.log
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
echo -e "${BLUE}║                   (v3.0 - İyileştirilmiş)                ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}Yapılandırma:${NC}"
echo "  qBittorrent: http://${QBIT_HOST}:${QBIT_PORT}"
echo "  Google Drive: ${GDRIVE_REMOTE}"
echo "  Kontrol Aralığı: ${CHECK_INTERVAL} saniye"
echo ""
echo -e "${GREEN}YENİ ÖZELLİKLER (v3.0):${NC}"
echo "  ✓ Geliştirilmiş debug logging"
echo "  ✓ Tüm torrent durumlarını gösterir"
echo "  ✓ Otomatik dosya yolu algılama (content_path + save_path)"
echo "  ✓ %99.5+ progress = tamamlanmış sayılır"
echo "  ✓ Seeding durumundaki torrentler de işlenir"
echo ""
echo -e "${GREEN}Kullanışlı Komutlar:${NC}"
echo "  Canlı log izle:    tail -f /var/log/qbit_gdrive.log"
echo "  Son 50 log:        tail -n 50 /var/log/qbit_gdrive.log"
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
echo -e "${YELLOW}DEBUG MODU:${NC}"
echo "Eğer hala çalışmazsa, detaylı log için:"
echo "  1. systemctl stop qbit-gdrive"
echo "  2. python3 $SCRIPT_PATH"
echo "  (Manuel çalıştırarak tüm detayları görebilirsiniz)"
echo ""
