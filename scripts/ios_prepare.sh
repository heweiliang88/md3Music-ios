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
# 直接对 cargo 产出的静态库做 -force_load，**不经过 xcodebuild -create-xcframework 的副本**，
# 少一个可能改动/丢符号的环节（诊断时曾观察到 xcframework 副本里找不到 C 符号）。
DEVICE_LIB="$RUST_DIR/target/aarch64-apple-ios/release/libkugou_server.a"

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
  PYBIN="${MD3_PYTHON:-python3}"
  if "$PYBIN" -c 'import PIL' 2>/dev/null; then
    "$PYBIN" - "$ICON_SRC" "$ICONSET/AppIcon-1024.png" <<'PY' && ICON_OK=1
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
    # jpeg 中转可去掉 alpha 通道（iOS 图标不允许透明）
    W=$(sips -g pixelWidth "$ICON_SRC" | awk '/pixelWidth/{print $2}')
    H=$(sips -g pixelHeight "$ICON_SRC" | awk '/pixelHeight/{print $2}')
    S=$(( W < H ? W : H ))
    sips -s format jpeg "$ICON_SRC" --out /tmp/md3_icon.jpg >/dev/null
    sips -s format png /tmp/md3_icon.jpg --out "$ICONSET/AppIcon-1024.png" >/dev/null
    sips -c "$S" "$S" "$ICONSET/AppIcon-1024.png" >/dev/null   # 居中裁剪为正方形
    sips -z 1024 1024 "$ICONSET/AppIcon-1024.png" >/dev/null   # 缩放到 1024
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
# 为什么必须 -force_load + -u：
#   libkugou_server.a 里的 start_server / stop_server / is_server_running
#   是给 Dart FFI 在**运行时**用 DynamicLibrary.process() 查找的，
#   没有任何 Objective-C / Swift 代码静态引用它们。这会导致两个连锁问题：
#
#     1) 链接器按需取用，archive 里不被引用的目标文件直接丢弃  -> -force_load
#     2) 即便 force_load 把目标文件读进来了，-dead_strip 仍会把
#        "无人引用"的代码整个剔除（实测：二进制里只剩该 .a 的 OSO 调试映射，
#        813 个全局符号里找不到 _start_server）              -> -u <symbol>
#
#   -Wl,-u,<symbol> 把符号声明为"必须解析的未定义引用"，链接器就会把它当作
#   死代码消除的根节点，连同它可达的整条调用链（tiny_http / ureq / rustls ...）
#   一起保留，并作为全局符号导出到主程序，dlsym 才能查到。
#
#   ⚠️ 必须写成 -Wl,-u,_start_server，不能写成 "-u _start_server"：
#   clang 的 -u 是连写形式，分开写时它会把 _start_server 当成链接输入文件，
#   报 "No such file or directory: '_start_server'"（已实测踩过）。
Pod::Spec.new do |s|
  s.name             = 'kugou_server'
  s.version          = '0.1.0'
  s.summary          = 'MD3Music embedded Rust API server (static library linker flags)'
  s.description      = 'Injects -force_load/-u for the Rust staticlib so Dart FFI can resolve start_server/stop_server/is_server_running on iOS.'
  s.homepage         = 'https://github.com/heweiliang88/md3Music-ios'
  s.license          = { :type => 'AGPL-3.0' }
  s.author           = { 'md3music-ios' => 'noreply@example.com' }
  s.source           = { :git => 'https://github.com/heweiliang88/md3Music-ios.git', :tag => '0.1.0' }
  s.ios.deployment_target = '$DEPLOY_TARGET'

  s.source_files   = []
  s.preserve_paths = 'target/aarch64-apple-ios/release/libkugou_server.a'

  s.user_target_xcconfig = {
    'OTHER_LDFLAGS' => '\$(inherited)' \\
      ' -force_load "$DEVICE_LIB"' \\
      ' -Wl,-u,_start_server' \\
      ' -Wl,-u,_stop_server' \\
      ' -Wl,-u,_is_server_running' \\
      ' -Wl,-u,_get_server_port'
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
#
# ⚠️ 坑（第三次踩）：flutter create **不会**生成 ios/Podfile，
#    Flutter 要到 `flutter build ios` 阶段才从 SDK 模板生成它。
#    如果不在补丁前先把 Podfile 建好，补丁就打在空气上，
#    pod install 依然会"成功"，但 Rust 库永远不会被链接。
#    这里先从 Flutter SDK 自带模板拷一份，再打补丁。
# -----------------------------------------------------------------------------
PODFILE="$IOS_DIR/Podfile"

if [[ ! -f "$PODFILE" ]]; then
  POD_TEMPLATE=""
  FR_CANDIDATE="${FLUTTER_ROOT:-}"
  if [[ -z "$FR_CANDIDATE" ]] && command -v flutter >/dev/null 2>&1; then
    FR_CANDIDATE="$(dirname "$(dirname "$(readlink -f "$(command -v flutter)")")")"
  fi

  if [[ -n "$FR_CANDIDATE" ]]; then
    for name in Podfile-ios-swift Podfile-ios-objc Podfile-ios; do
      if [[ -f "$FR_CANDIDATE/packages/flutter_tools/templates/cocoapods/$name" ]]; then
        POD_TEMPLATE="$FR_CANDIDATE/packages/flutter_tools/templates/cocoapods/$name"
        break
      fi
    done
    if [[ -z "$POD_TEMPLATE" ]]; then
      POD_TEMPLATE="$(find "$FR_CANDIDATE/packages/flutter_tools/templates" -maxdepth 3 -name 'Podfile-ios*' -type f 2>/dev/null | head -1 || true)"
    fi
  fi

  if [[ -n "$POD_TEMPLATE" && -f "$POD_TEMPLATE" ]]; then
    cp "$POD_TEMPLATE" "$PODFILE"
    log "已从 Flutter SDK 模板创建 Podfile：$POD_TEMPLATE"
  else
    log "✗ 无法定位 Flutter 的 Podfile 模板（FLUTTER_ROOT=${FLUTTER_ROOT:-未设置}）"
    log "  没有 Podfile 就无法把 Rust 静态库链进 App"
    exit 1
  fi
fi

if grep -q 'md3music-ios' "$PODFILE"; then
  log "Podfile 已打过补丁，跳过"
else
  log "给 Podfile 打补丁…"
  python3 - "$PODFILE" "$DEPLOY_TARGET" "$RUST_DIR" "$DEVICE_LIB" <<'PY'
import pathlib, sys

podfile = pathlib.Path(sys.argv[1])
target = sys.argv[2]
rust_dir = sys.argv[3]
device_lib = sys.argv[4]
text = podfile.read_text(encoding="utf-8")

# 6.1 打开 platform 行
if "\nplatform :ios" not in text:
    for old in ("# platform :ios, '13.0'", "# platform :ios, '12.0'",
                "# platform :ios, '15.0'", "# platform :ios, '11.0'"):
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
    + f"  if File.exist?('{device_lib}')\n"
    + f"    pod 'kugou_server', :path => '{rust_dir}'\n"
    + "  else\n"
    + "    puts '[md3music-ios] KugouServer.xcframework 不存在，跳过 Rust 静态库链接'\n"
    + "  end\n"
)
text = text.replace(marker, insert, 1)
podfile.write_text(text, encoding="utf-8")
print("[ios-prepare] Podfile 已接入 kugou_server（绝对路径）")
PY
fi

# 6.3 硬断言：补丁必须真的落地
if ! grep -q "kugou_server" "$PODFILE"; then
  log "✗ Podfile 中没有找到 kugou_server —— 补丁未生效"
  exit 1
fi
log "✓ Podfile 已确认接入 kugou_server"

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
