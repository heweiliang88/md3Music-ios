#!/usr/bin/env bash
# =============================================================================
# md3Music iOS 移植：生成 iOS 平台工程并打补丁
#
#   用法: ios_prepare.sh <app_dir> <port_dir>
#
# 做三件事：
#   1. 用 flutter create 在临时目录生成标准 iOS 工程模板，只拷 ios/ 进来
#      （避免 flutter create . 覆盖上游已有的 lib/ 与平台配置）
#   2. 给 ios/ 打补丁：部署目标、Info.plist 权限与后台播放、Podfile 接入
#      Rust 静态库
#   3. 把 ios 平台登记进 .metadata，保证后续 flutter 命令识别
#
# 幂等：重复执行不会重复插入。
# =============================================================================
set -euo pipefail

APP_DIR="${1:?用法: ios_prepare.sh <app_dir> <port_dir>}"
PORT_DIR="${2:?用法: ios_prepare.sh <app_dir> <port_dir>}"
APP_DIR="$(cd "$APP_DIR" && pwd)"
PORT_DIR="$(cd "$PORT_DIR" && pwd)"

IOS_DIR="$APP_DIR/ios"
BUNDLE_ORG="com.md3music"
PROJECT_NAME="md3music"
DEPLOY_TARGET="14.0"

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
# 2. 部署目标：全局提到 DEPLOY_TARGET
# -----------------------------------------------------------------------------
log "设置 IPHONEOS_DEPLOYMENT_TARGET = $DEPLOY_TARGET"
perl -pi -e 's/IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+;/IPHONEOS_DEPLOYMENT_TARGET = '"$DEPLOY_TARGET"';/g' \
  "$IOS_DIR/Runner.xcodeproj/project.pbxproj"

# -----------------------------------------------------------------------------
# 3. Info.plist：后台播放 + 各项权限文案
# -----------------------------------------------------------------------------
PLIST="$IOS_DIR/Runner/Info.plist"
python3 - "$PLIST" <<'PY'
import plistlib, sys, pathlib

plist_path = pathlib.Path(sys.argv[1])
data = plistlib.loads(plist_path.read_bytes())

# 后台音频：iOS 上本地 API 服务器 + 播放器依赖它保活
data["UIBackgroundModes"] = ["audio"]

# 权限文案（缺失会在上架 / 运行时被系统拒绝）
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
# 允许 HTTP 访问 127.0.0.1（ATS 对 localhost 默认放行，这里显式声明更稳）
data.setdefault("NSAppTransportSecurity", {})
data["NSAppTransportSecurity"].setdefault("NSAllowsLocalNetworking", True)
# 声明支持的文件类型（本地音乐/音频文件关联）
data.setdefault("UIFileSharingEnabled", True)
data.setdefault("LSSupportsOpeningDocumentsInPlace", True)

plist_path.write_bytes(plistlib.dumps(data))
print("[ios-prepare] Info.plist 已写入后台音频与权限声明")
PY

# -----------------------------------------------------------------------------
# 4. Podfile：接入 Rust 静态库（仅在 XCFramework 存在时）
# -----------------------------------------------------------------------------
PODFILE="$IOS_DIR/Podfile"
if [[ -f "$PODFILE" ]]; then
  if grep -q 'md3music-ios' "$PODFILE"; then
    log "Podfile 已打过补丁，跳过"
  else
    log "给 Podfile 打补丁…"
    python3 - "$PODFILE" "$DEPLOY_TARGET" <<'PY'
import pathlib, sys

podfile = pathlib.Path(sys.argv[1])
target = sys.argv[2]
text = podfile.read_text(encoding="utf-8")

# 4.1 打开 platform 行
if "\nplatform :ios" not in text:
    text = text.replace("# platform :ios, '13.0'",
                        f"platform :ios, '{target}'", 1)
    text = text.replace("# platform :ios, '12.0'",
                        f"platform :ios, '{target}'", 1)

# 4.2 在 target 'Runner' do 内插入本地 pod（仅当 XCFramework 已构建）
marker = "target 'Runner' do\n"
if marker not in text:
    raise SystemExit("[ios-prepare] Podfile 结构异常：找不到 target 'Runner' do")
insert = marker + """
  # === md3music-ios: 嵌入 Rust API 服务器（静态 XCFramework） ===
  # 未构建 XCFramework 时自动跳过，App 以「无本地 API」模式构建，CI 不会因此失败。
  if File.directory?(File.join(Dir.pwd, '..', 'kugou_api_server', 'rust', 'build', 'KugouServer.xcframework'))
    pod 'kugou_server', :path => '../kugou_api_server/rust'
  end
"""
text = text.replace(marker, insert, 1)

# 4.3 追加 post_install 钩子：强制加载静态库符号
#     （Dart FFI 在运行时用 dlsym 查符号，链接器默认会裁掉无人引用的目标文件）
text += """

# === md3music-ios: Rust 静态库必须 -force_load ===
# 上游 Rust 导出的 start_server / stop_server / is_server_running 没有任何
# 原生代码静态引用，若不强制加载，链接器会剔除该目标文件，
# 导致 DynamicLibrary.process() 在运行时查不到符号。
post_install do |installer|
  rust_lib = File.join(Dir.pwd, '..', 'kugou_api_server', 'rust', 'build',
                       'KugouServer.xcframework', 'ios-arm64', 'libkugou_server.a')
  if File.exist?(rust_lib)
    puts \"[md3music-ios] force_load Rust staticlib: #{rust_lib}\"
    installer.aggregate_targets.each do |aggregate_target|
      aggregate_target.user_targets.each do |user_target|
        user_target.build_configurations.each do |config|
          flags = config.build_settings['OTHER_LDFLAGS'] || ['$(inherited)']
          flags = [flags] if flags.is_a?(String)
          flags = flags.reject { |f| f.to_s.include?('libkugou_server.a') }
          flags << \"-force_load \\\"#{rust_lib}\\\"\"
          config.build_settings['OTHER_LDFLAGS'] = flags
        end
      end
    end
  else
    puts '[md3music-ios] KugouServer.xcframework 不存在，跳过 Rust 静态库链接'
  end
end
"""
podfile.write_text(text, encoding="utf-8")
print("[ios-prepare] Podfile 已接入 kugou_server pod")
PY
  fi
else
  log "警告：未找到 Podfile"
fi

# -----------------------------------------------------------------------------
# 5. .metadata：登记 ios 平台
# -----------------------------------------------------------------------------
META="$APP_DIR/.metadata"
if [[ -f "$META" ]] && ! grep -q "platform: ios" "$META"; then
  log "登记 ios 平台到 .metadata"
  python3 - "$META" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding="utf-8")
block = "    - platform: ios\n      create_revision: 0000000000000000000000000000000000000000\n      base_revision: 0000000000000000000000000000000000000000\n"
key = "  platforms:\n"
if key in text:
    text = text.replace(key, key + block, 1)
    p.write_text(text, encoding="utf-8")
PY
fi

log "完成"
