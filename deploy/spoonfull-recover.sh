#!/bin/sh
# 自動更新的退路,由 spoonfull-kiosk.service 在每次啟動 App 前執行 (ExecStartPre)。
# 搭配 lib/services/update_service.dart:安裝新版時,被換掉的舊檔會改名成
# *.spoonfull-old 留著,新版順利跑滿 60 秒 App 才會刪掉它們。
#
#   .update-in-progress 還在 → 上次安裝到一半被中斷 (斷電):換回舊檔。
#   .update-pending 還在     → 新版還沒確認正常:每次啟動計數,第 4 次啟動
#                              (前 3 次都沒撐過 60 秒) 就換回舊檔,並把這個版本
#                              記到 .update-bad-build,App 不會再安裝它。
#
# 用法:spoonfull-recover.sh [安裝目錄,預設 /opt/spoonfull]
DIR="${1:-/opt/spoonfull}"
MAX_BOOTS=3
cd "$DIR" 2>/dev/null || exit 0

restore() {
  find . -type f -name '*.spoonfull-old' | while IFS= read -r old; do
    mv -f "$old" "${old%.spoonfull-old}"
  done
}

if [ -f .update-in-progress ]; then
  echo "spoonfull-recover: interrupted update, restoring previous version" >&2
  restore
  rm -f .update-in-progress .boot-count
  exit 0
fi

if [ -f .update-pending ]; then
  boots=$(cat .boot-count 2>/dev/null)
  case "$boots" in ''|*[!0-9]*) boots=0 ;; esac
  boots=$((boots + 1))
  if [ "$boots" -gt "$MAX_BOOTS" ]; then
    echo "spoonfull-recover: build $(cat .update-pending) keeps failing, rolling back" >&2
    restore
    mv -f .update-pending .update-bad-build
    rm -f .boot-count
  else
    echo "$boots" > .boot-count
  fi
fi
exit 0
