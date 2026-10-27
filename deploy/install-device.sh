#!/usr/bin/env bash
# 機台 (Raspberry Pi 5;Jetson Orin Nano 次要) 一次性安裝腳本 (ARCHITECTURE.md §5)。
#
# 做的事:
#   1. 安裝 RealSense bridge 的 Python 相依 (numpy / OpenCV)、libsecret (token 儲存)、GTK 執行期
#      (librealsense + pyrealsense2 要先用 deploy/build-librealsense.sh 編好,或 dpkg -i 之前編的 .deb)
#   2. 開放 RealSense (USB)、/dev/hidraw* (USB HID 秤)、/dev/ttyUSB*、/dev/ttyACM* (序列埠秤) 權限
#   3. 啟用 NTP 自動校時 (capture_time 要可信)
#   4. 下載最新版 App 到 /opt/spoonfull (已經有就略過),安裝 kiosk systemd 服務
#      (開機自動全螢幕啟動 App,自動更新失敗時退回上一版);同時放一份 realsense_bridge.py
#   5. (選用) HX711 GPIO bridge 服務
#
# 用法 (在機台上):
#   sudo ./install-device.sh [--user <登入帳號>] [--hx711] [--skip-download]
#
# 預設會從 GitHub Release 下載 CI 編譯的版本,這樣才會自動更新;
# 自己 flutter build 的版本 (APP_BUILD=0) 不會自動更新,只適合開發。
set -euo pipefail

APP_USER="${SUDO_USER:-$(id -un)}"
WITH_HX711=0
DOWNLOAD=1
RELEASE_URL="${SPOONFULL_RELEASE_URL:-https://github.com/alianlbj23/spoonfull-flutter-app/releases/latest/download}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) APP_USER="$2"; shift 2 ;;
    --hx711) WITH_HX711=1; shift ;;
    --skip-download) DOWNLOAD=0; shift ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR=/opt/spoonfull

if [[ $EUID -ne 0 ]]; then
  echo "請用 sudo 執行" >&2
  exit 1
fi

echo "== 1/5 套件"
apt-get update
apt-get install -y \
  python3 python3-numpy python3-opencv \
  libsecret-1-0 libjsoncpp25 libgtk-3-0 libusb-1.0-0 \
  systemd-timesyncd curl || apt-get install -y \
  python3 python3-numpy python3-opencv \
  libsecret-1-0 libgtk-3-0 libusb-1.0-0 curl

if sudo -u "$APP_USER" python3 -c "import pyrealsense2" 2>/dev/null; then
  echo "   pyrealsense2 已安裝"
else
  echo "   注意:找不到 pyrealsense2。RealSense D435f 需要它:"
  echo "         Raspberry Pi → 以一般使用者執行 $HERE/build-librealsense.sh (約 30–45 分鐘),"
  echo "         或 dpkg -i 之前機台編好的 librealsense2-*.deb;x86_64 → pip install pyrealsense2"
fi

echo "== 2/5 裝置權限 (udev)"
install -m 644 "$HERE/99-spoonfull-hardware.rules" /etc/udev/rules.d/99-spoonfull-hardware.rules
usermod -aG video,dialout,plugdev "$APP_USER" 2>/dev/null || usermod -aG video,dialout "$APP_USER"
udevadm control --reload-rules && udevadm trigger

echo "== 3/5 NTP 校時"
timedatectl set-ntp true || true

echo "== 4/5 App 與 kiosk 服務"
mkdir -p "$INSTALL_DIR"
if [[ ! -x "$INSTALL_DIR/spoonfull_flutter_app" && $DOWNLOAD -eq 1 ]]; then
  case "$(uname -m)" in
    aarch64|arm64) ARCH=arm64 ;;
    x86_64|amd64) ARCH=x64 ;;
    *) echo "   不支援的架構 $(uname -m)" >&2; exit 1 ;;
  esac
  echo "   下載 $RELEASE_URL/spoonfull-linux-$ARCH.tar.gz"
  TMP="$(mktemp -d)"
  curl -fL --retry 3 -o "$TMP/app.tar.gz" "$RELEASE_URL/spoonfull-linux-$ARCH.tar.gz"
  tar -xzf "$TMP/app.tar.gz" -C "$TMP"
  cp -a "$TMP/bundle/." "$INSTALL_DIR/"
  rm -rf "$TMP"
fi
if [[ ! -x "$INSTALL_DIR/spoonfull_flutter_app" ]]; then
  echo "   注意:$INSTALL_DIR 裡還沒有 App。請把 bundle/* 複製進去 (見 deploy/README.md)。"
fi
install -m 755 "$HERE/spoonfull-recover.sh" "$INSTALL_DIR/spoonfull-recover.sh"
# RealSense 擷取程式:App 會先用 bundle 內 data/flutter_assets/deploy/ 的版本 (隨自動更新),
# 這份是 bundle 缺檔時的後備 (lib/services/hardware/camera_service.dart)
install -m 755 "$HERE/realsense_bridge.py" "$INSTALL_DIR/realsense_bridge.py"
# App 以 $APP_USER 執行,自動更新要能替換這個資料夾裡的檔案 (lib/services/update_service.dart)
chown -R "$APP_USER" "$INSTALL_DIR"
sed "s/__USER__/$APP_USER/g" "$HERE/spoonfull-kiosk.service" > /etc/systemd/system/spoonfull-kiosk.service
systemctl daemon-reload
systemctl enable spoonfull-kiosk.service

if [[ $WITH_HX711 -eq 1 ]]; then
  echo "== 5/5 HX711 GPIO bridge"
  install -m 755 "$HERE/hx711_bridge.py" "$INSTALL_DIR/hx711_bridge.py"
  sed "s/__USER__/$APP_USER/g" "$HERE/spoonfull-hx711.service" > /etc/systemd/system/spoonfull-hx711.service
  systemctl daemon-reload
  systemctl enable spoonfull-hx711.service
  echo "   先校正:sudo -u $APP_USER python3 $INSTALL_DIR/hx711_bridge.py --calibrate 500"
  echo "   然後在 App 硬體設定選「HX711 (GPIO bridge)」,位址 127.0.0.1:9100"
else
  echo "== 5/5 (略過 HX711 bridge,需要時加 --hx711)"
fi

echo
echo "完成。重新開機後 App 會全螢幕啟動;現在可用 sudo systemctl start spoonfull-kiosk 先試跑。"
echo "請重新登入 $APP_USER 讓群組 (plugdev / video / dialout) 生效。"
echo "相機:把 D435f 接到 USB 3 埠,執行 python3 $INSTALL_DIR/realsense_bridge.py --probe 應印出序號;"
echo "      App 的硬體設定 → 相機來源「RealSense D435f (RGB-D)」→「偵測相機」→「測試拍照」。"
