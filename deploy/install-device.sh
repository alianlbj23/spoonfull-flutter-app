#!/usr/bin/env bash
# 機台 (Jetson Orin Nano / Raspberry Pi 5) 一次性安裝腳本 (ARCHITECTURE.md §5)。
#
# 做的事:
#   1. 安裝 GStreamer (相機擷取)、v4l-utils、libsecret (token 儲存)、GTK 執行期
#   2. 開放 /dev/hidraw* (USB HID 秤)、/dev/ttyUSB*、/dev/ttyACM* (序列埠秤) 權限
#   3. 啟用 NTP 自動校時 (capture_time 要可信)
#   4. 安裝 kiosk systemd 服務 (開機自動全螢幕啟動 App)
#   5. (選用) HX711 GPIO bridge 服務
#
# 用法 (在機台上,先把 flutter build linux 的 bundle 複製到 /opt/spoonfull):
#   sudo ./install-device.sh [--user <登入帳號>] [--hx711]
set -euo pipefail

APP_USER="${SUDO_USER:-$(id -un)}"
WITH_HX711=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) APP_USER="$2"; shift 2 ;;
    --hx711) WITH_HX711=1; shift ;;
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
  gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
  v4l-utils libsecret-1-0 libjsoncpp25 libgtk-3-0 \
  systemd-timesyncd python3 || apt-get install -y \
  gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
  v4l-utils libsecret-1-0 libgtk-3-0 python3

if [[ -f /etc/nv_tegra_release ]]; then
  echo "   偵測到 Jetson:CSI 相機請在 App 硬體設定選「Jetson CSI 相機」(nvarguscamerasrc 由 JetPack 提供)"
fi
if grep -qi "raspberry pi" /proc/device-tree/model 2>/dev/null; then
  echo "   偵測到 Raspberry Pi:CSI 相機請安裝 rpicam-apps (apt-get install -y rpicam-apps)"
fi

echo "== 2/5 裝置權限 (udev)"
install -m 644 "$HERE/99-spoonfull-hardware.rules" /etc/udev/rules.d/99-spoonfull-hardware.rules
usermod -aG video,dialout,plugdev "$APP_USER" 2>/dev/null || usermod -aG video,dialout "$APP_USER"
udevadm control --reload-rules && udevadm trigger

echo "== 3/5 NTP 校時"
timedatectl set-ntp true || true

echo "== 4/5 kiosk 服務"
mkdir -p "$INSTALL_DIR"
if [[ ! -x "$INSTALL_DIR/spoonfull_flutter_app" ]]; then
  echo "   注意:$INSTALL_DIR 裡還沒有 App。請把 build/linux/<arch>/release/bundle/* 複製進去。"
fi
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
echo "請重新登入 $APP_USER 讓群組 (video / dialout) 生效。"
