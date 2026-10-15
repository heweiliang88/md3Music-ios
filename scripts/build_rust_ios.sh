#!/usr/bin/env bash
# =============================================================================
# md3Music iOS 移植：把嵌入式 Rust API 服务器编译为 iOS XCFramework
#
#   用法: build_rust_ios.sh <app_dir>
#   产物: <app_dir>/kugou_api_server/rust/build/KugouServer.xcframework
#
# 说明：
#   * 上游 Cargo.toml 只声明了 cdylib/rlib，patch_sources.py 会补上 staticlib。
#   * iOS 不允许 App 加载外来的 dylib，因此这里出**静态库**，
#     由 Dart 侧用 DynamicLibrary.process() 在进程空间解析符号。
#   * 需要 macOS + Xcode（ring/rustls 依赖 C 代码，交叉编译要 iOS SDK）。
# =============================================================================
set -euo pipefail

APP_DIR="${1:?用法: build_rust_ios.sh <app_dir>}"
APP_DIR="$(cd "$APP_DIR" && pwd)"

RUST_DIR="$APP_DIR/kugou_api_server/rust"
BUILD_DIR="$RUST_DIR/build"
DEVICE_TARGET="aarch64-apple-ios"
SIM_TARGET="aarch64-apple-ios-sim"
IOS_MIN="15.0"

log() { printf '[rust-ios] %s\n' "$*"; }

if ! command -v xcrun >/dev/null 2>&1; then
  log "非 macOS 环境，无法交叉编译 iOS 静态库，跳过"
  exit 0
fi

if [[ ! -f "$RUST_DIR/Cargo.toml" ]]; then
  log "找不到 $RUST_DIR/Cargo.toml"
  exit 1
fi

grep -q '"staticlib"' "$RUST_DIR/Cargo.toml" || {
  log "Cargo.toml 缺少 staticlib，请先运行 patch_sources.py"
  exit 1
}

log "安装 Rust iOS target"
rustup target add "$DEVICE_TARGET" "$SIM_TARGET"

# --- 设备（真机 arm64） ---
DEVICE_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
export SDKROOT="$DEVICE_SDK"
export CC_aarch64_apple_ios="$(xcrun --sdk iphoneos --find clang)"
export CXX_aarch64_apple_ios="$(xcrun --sdk iphoneos --find clang++)"
export CFLAGS_aarch64_apple_ios="-isysroot $DEVICE_SDK -arch arm64 -mios-version-min=$IOS_MIN"
export CXXFLAGS_aarch64_apple_ios="$CFLAGS_aarch64_apple_ios"

log "编译 $DEVICE_TARGET"
(cd "$RUST_DIR" && cargo build --release --target "$DEVICE_TARGET")

# --- 模拟器（arm64，供 Apple Silicon 本机调试） ---
SIM_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
export SDKROOT="$SIM_SDK"
export CC_aarch64_apple_ios_sim="$(xcrun --sdk iphonesimulator --find clang)"
export CXX_aarch64_apple_ios_sim="$(xcrun --sdk iphonesimulator --find clang++)"
export CFLAGS_aarch64_apple_ios_sim="-isysroot $SIM_SDK -arch arm64 -mios-version-min=$IOS_MIN"
export CXXFLAGS_aarch64_apple_ios_sim="$CFLAGS_aarch64_apple_ios_sim"

log "编译 $SIM_TARGET"
(cd "$RUST_DIR" && cargo build --release --target "$SIM_TARGET")

DEVICE_LIB="$RUST_DIR/target/$DEVICE_TARGET/release/libkugou_server.a"
SIM_LIB="$RUST_DIR/target/$SIM_TARGET/release/libkugou_server.a"

for f in "$DEVICE_LIB" "$SIM_LIB"; do
  [[ -f "$f" ]] || { log "缺少产物: $f"; exit 1; }
done

# --- 合并为 XCFramework ---
rm -rf "$BUILD_DIR/KugouServer.xcframework"
mkdir -p "$BUILD_DIR"

log "生成 XCFramework"
xcodebuild -create-xcframework \
  -library "$DEVICE_LIB" \
  -library "$SIM_LIB" \
  -output "$BUILD_DIR/KugouServer.xcframework"

log "产物："
find "$BUILD_DIR/KugouServer.xcframework" -maxdepth 2 -type f -exec ls -lh {} \;
log "完成"
