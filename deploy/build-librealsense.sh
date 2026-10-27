#!/usr/bin/env bash
# 在 Raspberry Pi 5 (Pi OS Bookworm, aarch64) 上原生編譯 librealsense + pyrealsense2,
# 給 deploy/realsense_bridge.py 用 (PROGRESS.md「相機改為 RealSense D435f」)。
#
# 為什麼要自己編:Intel 的 apt repo 只有 x86_64,PyPI / piwheels 沒有 aarch64 的
# pyrealsense2 wheel。一次約 30–45 分鐘;編完用 cpack 做成 .deb,之後的機台直接
# `sudo dpkg -i librealsense2-*.deb` 不用再編。
#
# 用法 (在 Pi 上,一般使用者執行,需要 sudo 權限):
#   ./deploy/build-librealsense.sh [--version v2.56.3] [--jobs 4] [--dir ~/librealsense]
#
# 完成後驗證:
#   rs-enumerate-devices                     看得到 D435f
#   python3 -c "import pyrealsense2 as rs; print(rs.__version__)"
#   python3 /opt/spoonfull/realsense_bridge.py --probe
set -euo pipefail

VERSION="${LIBREALSENSE_VERSION:-v2.56.3}"
JOBS="$(nproc)"
SRC_DIR="$HOME/librealsense"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --dir) SRC_DIR="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ $EUID -eq 0 ]]; then
  echo "請用一般使用者執行 (腳本內需要 sudo 的地方會自己呼叫)" >&2
  exit 1
fi

PY="$(command -v python3)"
PY_VER="$($PY -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")')"
echo "== librealsense $VERSION,python $PY_VER,$JOBS 個工作"

echo "== 1/5 建置相依"
sudo apt-get update
sudo apt-get install -y git cmake build-essential pkg-config libssl-dev libusb-1.0-0-dev \
  libudev-dev libgtk-3-dev libglfw3-dev libgl1-mesa-dev libglu1-mesa-dev \
  python3-dev python3-numpy python3-opencv

echo "== 2/5 原始碼"
if [[ ! -d "$SRC_DIR/.git" ]]; then
  git clone --depth 1 --branch "$VERSION" https://github.com/IntelRealSense/librealsense.git "$SRC_DIR"
else
  git -C "$SRC_DIR" fetch --depth 1 origin "$VERSION"
  git -C "$SRC_DIR" checkout -q FETCH_HEAD
fi

echo "== 3/5 udev 規則 (不用 sudo 也能開相機)"
sudo install -m 644 "$SRC_DIR/config/99-realsense-libusb.rules" /etc/udev/rules.d/99-realsense-libusb.rules
sudo udevadm control --reload-rules && sudo udevadm trigger

echo "== 4/5 編譯 (RSUSB backend,不改 kernel;Python 綁定)"
mkdir -p "$SRC_DIR/build"
cd "$SRC_DIR/build"
cmake .. \
  -DCMAKE_BUILD_TYPE=Release \
  -DFORCE_RSUSB_BACKEND=ON \
  -DBUILD_PYTHON_BINDINGS=ON \
  -DPYTHON_EXECUTABLE="$PY" \
  -DBUILD_EXAMPLES=OFF \
  -DBUILD_GRAPHICAL_EXAMPLES=OFF \
  -DBUILD_WITH_CUDA=OFF \
  -DCMAKE_INSTALL_PREFIX=/usr/local
make -j"$JOBS"

echo "== 5/5 安裝"
sudo make install
sudo ldconfig
# pyrealsense2 裝在 /usr/local/lib/python3.X/dist-packages 或 site-packages;
# Pi OS 的 python3 預設只找 dist-packages,補一個 .pth 保險。
SITE="$($PY -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
for d in /usr/local/lib/python${PY_VER}/site-packages /usr/local/lib/python${PY_VER}/dist-packages /usr/local/lib; do
  if ls "$d"/pyrealsense2*.so >/dev/null 2>&1; then
    echo "$d" | sudo tee "$SITE/pyrealsense2.pth" >/dev/null
    break
  fi
done
$PY -c "import pyrealsense2 as rs; print('pyrealsense2', rs.__version__)"

echo "== 打包 .deb 給下一台機台 (可略過失敗)"
cpack -G DEB 2>/dev/null && ls -1 "$SRC_DIR"/build/*.deb || echo "   cpack 失敗,略過 (不影響這台)"

echo
echo "完成。接上 D435f (USB 3 埠) 後:rs-enumerate-devices 應列出相機。"
echo "再執行 sudo ./deploy/install-device.sh 安裝 App 與 realsense_bridge.py。"
