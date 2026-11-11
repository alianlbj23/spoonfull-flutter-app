#!/usr/bin/env bash
# 在 Raspberry Pi 5 (Pi OS Bookworm, aarch64) 上原生編譯 librealsense + pyrealsense2,
# 給 deploy/realsense_bridge.py 用 (PROGRESS.md「相機改為 RealSense D435f」)。
#
# 為什麼要自己編:Intel 的 apt repo 只有 x86_64,PyPI / piwheels 沒有 aarch64 的
# pyrealsense2 wheel。一次約 30–45 分鐘;編完用 cpack 做成 .deb,之後的機台直接
# `sudo dpkg -i librealsense2-*.deb` 不用再編。
#
# 版本:預設一律用 GitHub 上最新的正式版 (releases/latest,不含 beta / RC)。
#   librealsense 已從 IntelRealSense/librealsense 搬到 realsenseai/librealsense (2026-11 確認)。
#   要固定版本:--version v2.59.1 或環境變數 LIBREALSENSE_VERSION=v2.59.1。
#   已安裝的 pyrealsense2 已經是這個版本時會直接結束,不重編 (--force 強制重編)。
#
# 用法 (在 Pi 上,一般使用者執行,需要 sudo 權限):
#   ./deploy/build-librealsense.sh [--version vX.Y.Z] [--jobs 4] [--dir ~/librealsense] [--force]
#   ./deploy/build-librealsense.sh --build-only   只下載與編譯 (不用 sudo、不安裝);
#                                                 之後再跑一次不加參數就只剩安裝,幾分鐘完成
#
# 完成後驗證:
#   rs-enumerate-devices                     看得到 D435f
#   python3 -c "import pyrealsense2 as rs; print(rs.__version__)"
#   python3 /opt/spoonfull/realsense_bridge.py --probe
set -euo pipefail

REPO="realsenseai/librealsense"
REPO_URL="https://github.com/$REPO.git"
VERSION="${LIBREALSENSE_VERSION:-latest}"
JOBS="$(nproc)"
SRC_DIR="$HOME/librealsense"
BUILD_ONLY=0
FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --dir) SRC_DIR="$2"; shift 2 ;;
    --build-only) BUILD_ONLY=1; shift ;;
    --force) FORCE=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

# 最新正式版:releases/latest 會轉址到 .../releases/tag/vX.Y.Z (GitHub 不把 pre-release 當 latest)。
# 轉址抓不到時改列出所有 tag,取 vX.Y.Z 格式 (排除 -beta / -rc) 中最大的。
latest_version() {
  local v
  v="$(curl -fsSIL -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest" 2>/dev/null \
       | sed -n 's#.*/releases/tag/\(v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$#\1#p')"
  if [[ -z "$v" ]]; then
    v="$(git ls-remote --tags --refs "$REPO_URL" | awk -F/ '{print $3}' \
         | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"
  fi
  [[ -n "$v" ]] || { echo "查不到 librealsense 最新版本 (網路?);可用 --version vX.Y.Z 指定" >&2; exit 1; }
  echo "$v"
}
if [[ "$VERSION" == "latest" ]]; then
  VERSION="$(latest_version)"
  echo "== 最新正式版:$VERSION"
fi

if [[ $EUID -eq 0 ]]; then
  echo "請用一般使用者執行 (腳本內需要 sudo 的地方會自己呼叫)" >&2
  exit 1
fi

PY="$(command -v python3)"
PY_VER="$($PY -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")')"
echo "== librealsense $VERSION,python $PY_VER,$JOBS 個工作"

INSTALLED="$($PY -c "import pyrealsense2 as rs; m = rs if hasattr(rs, '__version__') else rs.pyrealsense2; print(m.__version__)" 2>/dev/null || true)"
if [[ "$FORCE" -eq 0 && "$BUILD_ONLY" -eq 0 && -n "$INSTALLED" && "v$INSTALLED" == "$VERSION" ]]; then
  echo "已安裝的 pyrealsense2 已經是 $VERSION,不需要重編 (要強制重編請加 --force)。"
  exit 0
fi
[[ -n "$INSTALLED" ]] && echo "   目前安裝的是 v$INSTALLED"

echo "== 1/5 建置相依"
if [[ "$BUILD_ONLY" -eq 1 ]]; then
  echo "   --build-only:略過 apt (需要 sudo);缺套件時 cmake 會報錯,請改跑完整流程"
else
  sudo apt-get update
  sudo apt-get install -y git cmake build-essential pkg-config libssl-dev libusb-1.0-0-dev \
    libudev-dev libgtk-3-dev libglfw3-dev libgl1-mesa-dev libglu1-mesa-dev \
    python3-dev python3-numpy python3-opencv curl
fi

echo "== 2/5 原始碼"
if [[ ! -d "$SRC_DIR/.git" ]]; then
  git clone --depth 1 --branch "$VERSION" "$REPO_URL" "$SRC_DIR"
elif [[ "$(git -C "$SRC_DIR" describe --tags --exact-match 2>/dev/null || true)" == "$VERSION" ]]; then
  echo "   $SRC_DIR 已經是 $VERSION"  # 不重新 checkout,保留檔案時間,make 才不會整個重編
else
  # 用 REPO_URL 而不是 origin:舊的 clone 的 origin 可能還指向搬家前的 IntelRealSense/librealsense
  git -C "$SRC_DIR" fetch --depth 1 "$REPO_URL" tag "$VERSION"
  git -C "$SRC_DIR" checkout -q "$VERSION"
fi

if [[ "$BUILD_ONLY" -eq 0 ]]; then
  echo "== 3/5 udev 規則 (不用 sudo 也能開相機)"
  sudo install -m 644 "$SRC_DIR/config/99-realsense-libusb.rules" /etc/udev/rules.d/99-realsense-libusb.rules
  sudo udevadm control --reload-rules && sudo udevadm trigger
fi

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

if [[ "$BUILD_ONLY" -eq 1 ]]; then
  echo
  echo "編譯完成 ($VERSION),尚未安裝。請執行 ./deploy/build-librealsense.sh (不加 --build-only) 安裝,"
  echo "會沿用這次的編譯結果,只剩安裝步驟。"
  exit 0
fi

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
$PY -c "import pyrealsense2 as rs; m = rs if hasattr(rs, '__version__') else rs.pyrealsense2; print('pyrealsense2', m.__version__)"

echo "== 打包 .deb 給下一台機台 (可略過失敗)"
cpack -G DEB 2>/dev/null && ls -1 "$SRC_DIR"/build/*.deb || echo "   cpack 失敗,略過 (不影響這台)"

echo
echo "完成 (librealsense $VERSION)。接上 D435f (USB 3 埠) 後:rs-enumerate-devices 應列出相機。"
echo "新版 SDK 可能建議較新的相機韌體:python3 deploy/realsense_tool.py → 選單 2 查看、選單 15 更新。"
echo "再執行 python3 deploy/spoonfull.py,選「安裝 / 更新機台」安裝 App 與 realsense_bridge.py。"
