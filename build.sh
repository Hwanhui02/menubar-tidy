#!/bin/zsh
# MenuBarTidy.app 빌드 → /Applications 설치
#   ./build.sh        빌드 + 이 Mac에 설치
#   ./build.sh dist   빌드 + 배포용 dist/MenuBarTidy-<버전>.zip 생성(설치 안 함)
set -e
cd "$(dirname "$0")"
APP=MenuBarTidy.app
VER=1.0
rm -rf $APP && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp AppIcon.icns $APP/Contents/Resources/  # make_icon.swift로 생성
# 애플 실리콘 + 인텔 겸용, macOS 14(Sonoma) 이상
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos14 main.swift -o /tmp/MenuBarTidy-$arch
done
lipo -create /tmp/MenuBarTidy-arm64 /tmp/MenuBarTidy-x86_64 -output $APP/Contents/MacOS/MenuBarTidy
rm -f /tmp/MenuBarTidy-arm64 /tmp/MenuBarTidy-x86_64
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.hwanhui.menubartidy</string>
<key>CFBundleName</key><string>MenuBarTidy</string>
<key>CFBundleExecutable</key><string>MenuBarTidy</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VER</string>
<key>CFBundleVersion</key><string>$VER</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>CFBundleIconFile</key><string>AppIcon</string>
</dict></plist>
PLIST
# 고정 인증서로 서명해야 재빌드해도 손쉬운 사용·화면 기록 권한이 유지된다. 없으면 ad-hoc.
ID="MenuBarTidy Dev"
security find-certificate -c "$ID" >/dev/null 2>&1 || ID=-
codesign -s "$ID" --force $APP

if [[ "$1" == dist ]]; then
  mkdir -p dist
  rm -f dist/MenuBarTidy-$VER.zip
  ditto -c -k --keepParent $APP dist/MenuBarTidy-$VER.zip
  cp 사용법.md dist/
  echo "배포 파일: dist/MenuBarTidy-$VER.zip, dist/사용법.md"
  exit 0
fi
pkill -x MenuBarTidy || true
rm -rf /Applications/$APP && mkdir -p /Applications && cp -R $APP /Applications/
echo "설치: /Applications/$APP"
