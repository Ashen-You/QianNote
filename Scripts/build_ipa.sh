#!/bin/bash
# 在有 Xcode 的 Mac 上运行，产出未签名 IPA（之后自行用 Sideloadly / AltStore / 爱思助手签名安装）
#
#   bash Scripts/build_ipa.sh            # 未签名 IPA
#   bash Scripts/build_ipa.sh --signed   # 用本机证书导出已签名 IPA（需已登录开发者账号）
#
set -euo pipefail

cd "$(dirname "$0")/.."
SCHEME="QianNote"
PROJECT="QianNote.xcodeproj"
BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/QianNote.xcarchive"
IPA_UNSIGNED="$BUILD_DIR/QianNote-unsigned.ipa"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "错误：未找到 xcodebuild。请在装有 Xcode 的 macOS 上运行本脚本。" >&2
  exit 1
fi

echo "==> 清理旧产物"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

if [[ "${1:-}" == "--signed" ]]; then
  # ---------------- 已签名导出 ----------------
  TEAM_ID="${TEAM_ID:-}"
  if [[ -z "$TEAM_ID" ]]; then
    echo "错误：请先设置 TEAM_ID 环境变量，例如 TEAM_ID=ABCDE12345 bash Scripts/build_ipa.sh --signed" >&2
    exit 1
  fi

  echo "==> 归档（Team: $TEAM_ID）"
  xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Automatic \
    -allowProvisioningUpdates

  cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>development</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>stripSwiftSymbols</key>
    <true/>
    <key>compileBitcode</key>
    <false/>
</dict>
</plist>
PLIST

  echo "==> 导出 IPA"
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$BUILD_DIR/export" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
    -allowProvisioningUpdates

  echo
  echo "完成：$(find "$BUILD_DIR/export" -name '*.ipa' | head -1)"
  exit 0
fi

# ---------------- 未签名 IPA ----------------
echo "==> 归档（不签名）"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_BITCODE=NO \
  ONLY_ACTIVE_ARCH=NO

APP="$ARCHIVE/Products/Applications/QianNote.app"
if [[ ! -d "$APP" ]]; then
  echo "错误：归档里没有 QianNote.app，编译失败了。" >&2
  exit 1
fi

echo "==> 打包 Payload"
mkdir -p "$BUILD_DIR/Payload"
cp -R "$APP" "$BUILD_DIR/Payload/"
( cd "$BUILD_DIR" && zip -qry "QianNote-unsigned.ipa" Payload )

echo
echo "完成：$IPA_UNSIGNED（$(du -h "$IPA_UNSIGNED" | cut -f1)）"
echo "下一步：用 Sideloadly / AltStore / 爱思助手 导入该 IPA，填自己的 Apple ID 签名后装到 iPad。"
