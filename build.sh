#!/bin/zsh
# 编译 PowerBar.app 并安装到 /Applications
set -e
cd "${0:A:h}"
APP=PowerBar.app
rm -rf $APP && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
swiftc -O -swift-version 5 -import-objc-header smc.h smc.swift main.swift -o $APP/Contents/MacOS/PowerBar
swiftc -O -swift-version 5 -import-objc-header smc.h smc.swift helper/main.swift -o $APP/Contents/Resources/powerbar-fan
cat > $APP/Contents/Info.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>PowerBar</string>
  <key>CFBundleIdentifier</key><string>io.github.mikefengnanhe.powerbar</string>
  <key>CFBundleExecutable</key><string>PowerBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force --sign - $APP
rm -rf /Applications/$APP && cp -R $APP /Applications/
echo "已安装到 /Applications/$APP"
