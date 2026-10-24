#!/bin/bash
# 构建 讲座助手.app 并安装到 /Applications
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP="build/讲座助手.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LectureAssistant "$APP/Contents/MacOS/LectureAssistant"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ ! -f Resources/AppIcon.icns ]; then
  rm -rf build/AppIcon.iconset
  swift scripts/make_icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp scripts/asr_server.py "$APP/Contents/Resources/asr_server.py"

codesign --force --sign - "$APP"
codesign --verify "$APP"

if [ "${1:-}" = "--install" ]; then
  # 正在运行就先退出（会触发正常保存）
  osascript -e 'tell application id "io.github.fhy12130-afk.LectureAssistant" to quit' >/dev/null 2>&1 || true
  sleep 1
  rm -rf "/Applications/讲座助手.app"
  cp -R "$APP" "/Applications/讲座助手.app"
  echo "已安装到 /Applications/讲座助手.app"
fi
