#!/usr/bin/env bash
# 构建用于本地侧载的 ipa。需要完整 Xcode（非 Command Line Tools）。
# 产物仅做 ad-hoc 签名，安装时仍需由 Sideloadly 等工具重签。
# 用法：./build_ipa.sh
set -euo pipefail

cd "$(dirname "$0")"

# 未选 Xcode 时，自动回退到已安装的 Xcode(-beta)，免 sudo xcode-select。
if ! xcode-select -p 2>/dev/null | grep -q Xcode; then
  for x in /Applications/Xcode.app /Applications/Xcode-beta.app; do
    [ -d "$x/Contents/Developer" ] && export DEVELOPER_DIR="$x/Contents/Developer" && break
  done
fi

xcodebuild -project AFUScale.xcodeproj -scheme AFUScale -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build

APP=build/Build/Products/Release-iphoneos/AFUScale.app
# ad-hoc 签名并嵌入 entitlements，让 Sideloadly 能识别 HealthKit 并在重签时启用。
codesign --force --sign - --entitlements App/AFUScale.entitlements "$APP"

cd build/Build/Products/Release-iphoneos
rm -rf Payload
mkdir Payload
cp -R AFUScale.app Payload/
OUT="$OLDPWD/build/AFUScale-local.ipa"
rm -f "$OUT"
zip -qry "$OUT" Payload
echo "ipa: $OUT"
