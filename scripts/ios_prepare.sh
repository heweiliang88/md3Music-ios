#!/usr/bin/env bash
# =============================================================================
# md3Music iOS 移植：生成 iOS 平台工程并打补丁
#
#   用法: ios_prepare.sh <app_dir> <port_dir>
#
# 做四件事：
#   1. 用 flutter create 在临时目录生成标准 iOS 工程模板，只拷 ios/ 进来
#      （避免 flutter create . 覆盖上游已有的 lib/ 与平台配置）
#   2. 用上游官方 assets/images/app_icon.png 生成 AppIcon.appiconset
#   3. 生成 kugou_server.podspec，把 Rust 静态库链进 Runner（App）target
#   4. 打补丁：部署目标、Info.plist 权限与后台播放
#
# 幂等：重复执行不会重复插入。
#
# ⚠️ 两个已经踩过的坑，改动时务必保留：
#
#   (1) 路径一律用绝对路径。
#       CocoaPods 求值 Podfile 时的 Dir.pwd 不可靠，之前用 '../..' 相对路径
#       判断 xcframework 是否存在 → 判断失败 → pod 被静默跳过，pod install
#       依然"成功"，但 Rust 库根本没进包。
#
#   (2) -force_load 必须通过 podspec 的 user_target_xcconfig 注入。
#       在 Podfile 的 post_install 里改 user target 的 build_settings
#       **不会写盘**（CocoaPods 只保存 Pods 工程），链路会静默失效。
# =============================================================================
set -euo pipefail

APP_DIR="${1:?用法: ios_prepare.sh <app_dir> <port_dir>}"
PORT_DIR="${2:?用法: ios_prepare.sh <app_dir> <port_dir>}"
APP_DIR="$(cd "$APP_DIR" && pwd)"
PORT_DIR="$(cd "$PORT_DIR" && pwd)"

IOS_DIR="$APP_DIR/ios"
RUST_DIR="$APP_DIR/kugou_api_server/rust"
XCFRAMEWORK="$RUST_DIR/build/KugouServer.xcframework"
DEVICE_LIB="$XCFRAMEWORK/ios-arm64/libkugou_server.a"

BUNDLE_ORG="com.md3music"
PROJECT_NAME="md3music"
DEPLOY_TARGET="15.0"

log() { printf '[ios-prepare] %s\n' "$*"; }

# -----------------------------------------------------------------------------
# 1. 生成 iOS 平台工程（模板生成在临时目录，只取 ios/）
# -----------------------------------------------------------------------------
if [[ -f "$IOS_DIR/Runner.xcodeproj/project.pbxproj" ]]; then
  log "ios/ 工程已存在，跳过模板生成"
else
  log "用 flutter create 生成 iOS 模板…"
  SCAFFOLD="$(mktemp -d)"
  flutter create \
    --platforms=ios \
    --org "$BUNDLE_ORG" \
    --project-name "$PROJECT_NAME" \
    --no-pub \
    "$SCAFFOLD/scaffold" >/dev/null
  rm -rf "$IOS_DIR"
  cp -R "$SCAFFOLD/scaffold/ios" "$IOS_DIR"
  rm -rf "$SCAFFOLD"
  log "ios/ 工程已生成"
fi

# -----------------------------------------------------------------------------
# 2. 应用图标：用上游官方图标生成 AppIcon
#    Xcode 14+ 支持单尺寸 AppIcon（1024x1024），由系统自动缩放生成各档尺寸
# -----------------------------------------------------------------------------
ICON_SRC=""
for cand in \
  "$APP_DIR/assets/images/app_icon.png" \
  "$APP_DIR/assets/images/app_icon_3.jpg"; do
  if [[ -f "$cand" ]]; then ICON_SRC="$cand"; break; fi
done

ICONSET="$IOS_DIR/Runner/Assets.xcassets/AppIcon.appiconset"
if [[ -n "$ICON_SRC" ]]; then
  log "用官方图标生成 AppIcon：$ICON_SRC"
  mkdir -p "$ICONSET"
  rm -f "$ICONSET"/*.png   # 清掉模板自带的 Flutter 默认图标

  ICON_OK=0
  if python3 -c 'import PIL' 2>/dev/null; then
    python3 - "$ICON_SRC" "$ICONSET/AppIcon-1024.png" <<'PY' && ICON_OK=1
import sys
from PIL import Image

src, dst = sys.argv[1], sys.argv[2]
im = Image.open(src)

# iOS 应用图标不允许带 alpha 通道，先合成到白底
if im.mode in ("RGBA", "LA", "P"):
    im = im.convert("RGBA")
    bg = Image.new("RGB", im.size, (255, 255, 255))
    bg.paste(im, mask=im.split()[-1])
    im = bg
else:
    im = im.convert("RGB")

# 居中裁剪为正方形，避免非等比拉伸导致图标变形
w, h = im.size
side = min(w, h)
im = im.crop(((w - side) // 2, (h - side) // 2,
              (w - side) // 2 + side, (h - side) // 2 + side))

im = im.resize((1024, 1024), Image.LANCZOS)
im.save(dst, format="PNG", optimize=True)
print(f"[ios-prepare] AppIcon 已生成 1024x1024（源图 {w}x{h}）")
PY
  fi

  if [[ "$ICON_OK" != "1" ]]; then
    log "未安装 Pillow，退回 sips 处理"
    sips -s format jpeg "$ICON_SRC" --out /tmp/md3_icon.jpg >/dev/null
    sips -s format png /tmp/md3_icon.jpg --out "$ICONSET/AppIcon-1024.png" >/dev/null
    sips --resampleHeightWidth 1024 1024 "$ICONSET/AppIcon-1024.png" >/dev/null
  fi

  cat > "$ICONSET/Contents.json" <<'JSON'
{
  "images" : [
    {
      "filename" : "AppIcon-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON
  ls -lh "$ICONSET"
  log "AppIcon.appiconset 已写入（单尺寸 1024）"
else
  log "⚠️ 未找到官方图标源文件，保留模板默认图标"
fi

# -----------------------------------------------------------------------------
# 3. Rust 静态库接入：生成 podspec（经 user_target_xcconfig 注入 -force_load）
# -----------------------------------------------------------------------------
cat > "$RUST_DIR/kugou_server.podspec" <<PODSPEC
# 由 md3music-ios 移植层自动生成，请勿手工修改。
#
# 这个 pod 不提供任何源码，唯一作用是给 Runner（App）target 注入
# -force_load，把 Rust 静态库整体链进主程序。
#
# 为什么必须 -force_load：
#   libkugou_server.a 里的 start_server / stop_server / is_server_running
#   是给 Dart FFI 在**运行时**用 DynamicLibrary.process() 查找的，
#   没有任何 Objective-C / Swift 代码静态引用它们。链接器默认按需取用
#   （archive 中不被引用的目标文件会被整体丢弃），导致符号在最终二进制里
#   不存在，App 启动本地 API 服务时必然失败。
Pod::Spec.new do |s|
  s.name             = 'kugou_server'
  s.version          = '0.1.0'
  s.summary          = 'MD3Music embedded Rust API server (static library linker flags)'
  s.description      = 'Injects -force_load for the Rust staticlib so Dart FFI can resolve start_server/stop_server/is_server_running on iOS.'
  s.homepage         = 'https://github.com/heweiliang88/md3Music-ios'
  s.license          = { :type => 'AGPL-3.0' }
  s.author           = { 'md3music-ios' => 'noreply@example.com' }
  s.source           = { :git => 'https://github.com/heweiliang88/md3Music-ios.git', :tag => '0.1.0' }
  s.ios.deployment_target = '$DEPLOY_TARGET'

  s.source_files   = []
  s.preserve_paths = 'build/KugouServer.xcframework'

  s.user_target_xcconfig = {
    'OTHER_LDFLAGS' => '\$(inherited) -force_load "$DEVICE_LIB"'
  }
end
PODSPEC
log "已生成 $RUST_DIR/kugou_server.podspec"

# -----------------------------------------------------------------------------
# 4. 部署目标
# -----------------------------------------------------------------------------
log "设置 IPHONEOS_DEPLOYMENT_TARGET = $DEPLOY_TARGET"
perl -pi -e 's/IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+;/IPHONEOS_DEPLOYMENT_TARGET = '"$DEPLOY_TARGET"';/g' \
  "$IOS_DIR/Runner.xcodeproj/project.pbxproj"

# -----------------------------------------------------------------------------
# 5. Info.plist：后台播放 + 各项权限文案
# -----------------------------------------------------------------------------
PLIST="$IOS_DIR/Runner/Info.plist"
python3 - "$PLIST" <<'PY'
import plistlib, sys, pathlib

plist_path = pathlib.Path(sys.argv[1])
data = plistlib.loads(plist_path.read_bytes())

# 后台音频：本地 API 服务器 + 播放器靠它保活
data["UIBackgroundModes"] = ["audio"]

data.setdefault("NSMicrophoneUsageDescription",
                "用于「听歌识曲」录制音频片段进行识别")
data.setdefault("NSCameraUsageDescription",
                "用于扫描酷狗登录二维码")
data.setdefault("NSPhotoLibraryUsageDescription",
                "用于导入外部歌单截图、选择图片作为全局背景")
data.setdefault("NSPhotoLibraryAddUsageDescription",
                "用于保存评论图片到你的相册")
data.setdefault("NSLocalNetworkUsageDescription",
                "用于在本地网络内访问内嵌 API 服务与投屏设备")
data.setdefault("NSAppleMusicUsageDescription",
                "用于读取媒体库信息以匹配本地音乐")
data.setdefault("NSAppTransportSecurity", {})
data["NSAppTransportSecurity"].setdefault("NSAllowsLocalNetworking", True)
data.setdefault("UIFileSharingEnabled", True)
data.setdefault("LSSupportsOpeningDocumentsInPlace", True)

plist_path.write_bytes(plistlib.dumps(data))
print("[ios-prepare] Info.plist 已写入后台音频与权限声明")
PY

# -----------------------------------------------------------------------------
# 6. Podfile：接入 kugou_server（存在 XCFramework 时），全部使用绝对路径
# -----------------------------------------------------------------------------
PODFILE="$IOS_DIR/Podfile"
if [[ -f "$PODFILE" ]]; then
  if grep -q 'md3music-ios' "$PODFILE"; then
    log "Podfile 已打过补丁，跳过"
  else
    log "给 Podfile 打补丁…"
    python3 - "$PODFILE" "$DEPLOY_TARGET" "$RUST_DIR" "$XCFRAMEWORK" <<'PY'
import pathlib, sys

podfile = pathlib.Path(sys.argv[1])
target = sys.argv[2]
rust_dir = sys.argv[3]
xcframework = sys.argv[4]
text = podfile.read_text(encoding="utf-8")

# 6.1 打开 platform 行
if "\nplatform :ios" not in text:
    for old in ("# platform :ios, '13.0'", "# platform :ios, '12.0'",
                "# platform :ios, '15.0'"):
        if old in text:
            text = text.replace(old, f"platform :ios, '{target}'", 1)
            break

# 6.2 在 target 'Runner' do 内插入本地 pod（绝对路径，避免 Dir.pwd 不可靠）
marker = "target 'Runner' do\n"
if marker not in text:
    raise SystemExit("[ios-prepare] Podfile 结构异常：找不到 target 'Runner' do")

insert = (
    marker
    + "\n"
    + "  # === md3music-ios: 嵌入 Rust API 服务器（静态库 linker flags）===\n"
    + "  # 未构建 XCFramework 时自动跳过，App 以「无本地 API」模式构建，CI 不会因此失败。\n"
    + f"  if File.directory?('{xcframework}')\n"
    + f"    pod 'kugou_server', :path => '{rust_dir}'\n"
    + "  else\n"
    + "    puts '[md3music-ios] KugouServer.xcframework 不存在，跳过 Rust 静态库链接'\n"
    + "  end\n"
)
text = text.replace(marker, insert, 1)
podfile.write_text(text, encoding="utf-8")
print(f"[ios-prepare] Podfile 已接入 kugou_server（绝对路径）")
PY
  fi
else
  log "警告：未找到 Podfile"
fi

# -----------------------------------------------------------------------------
# 7. .metadata：登记 ios 平台
# -----------------------------------------------------------------------------
META="$APP_DIR/.metadata"
if [[ -f "$META" ]] && ! grep -q "platform: ios" "$META"; then
  log "登记 ios 平台到 .metadata"
  python3 - "$META" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding="utf-8")
block = ("    - platform: ios\n"
         "      create_revision: 0000000000000000000000000000000000000000\n"
         "      base_revision: 0000000000000000000000000000000000000000\n")
key = "  platforms:\n"
if key in text:
    text = text.replace(key, key + block, 1)
    p.write_text(text, encoding="utf-8")
PY
fi

log "完成"
