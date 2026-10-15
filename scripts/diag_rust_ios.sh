#!/usr/bin/env bash
# =============================================================================
# 诊断：Rust 静态库在 iOS 上的符号导出链路
#
#   用法: diag_rust_ios.sh <app_dir>
#
# 逐段验证符号在哪一步消失：
#   A. 最小复现 crate（同 crate-type / 同 profile）-> 判定 rustc 是否为 iOS 目标
#      产出 #[no_mangle] extern "C" 符号
#   B. cargo 原始产物 libkugou_server.a（未经 xcodebuild 打包）
#   C. xcodebuild -create-xcframework 之后的副本
#
# 注意：以 `bash script.sh` 方式调用，脚本自己控制 set 选项，
# 不受 runner 外层 `bash -e` 影响（之前就是因为外层 -e + pipefail + head
# 触发 SIGPIPE，导致诊断被腰斩）。
# =============================================================================
set +e
set -uo pipefail

APP_DIR="${1:?用法: diag_rust_ios.sh <app_dir>}"
APP_DIR="$(cd "$APP_DIR" && pwd)"
RUST_DIR="$APP_DIR/kugou_api_server/rust"
ORIGINAL="$RUST_DIR/target/aarch64-apple-ios/release/libkugou_server.a"
XCFW="$RUST_DIR/build/KugouServer.xcframework/ios-arm64/libkugou_server.a"

hr() { printf '\n===== %s =====\n' "$*"; }

dump_symbols() {
  local label="$1" lib="$2"
  hr "$label"
  if [ ! -f "$lib" ]; then echo "文件不存在: $lib"; return; fi
  echo "路径: $lib"
  echo "大小: $(du -h "$lib" | cut -f1)"
  echo "-- 匹配 server 的 nm 全局符号（不假设前导下划线）--"
  nm -gU "$lib" 2>/dev/null | grep -i -E 'start_server|stop_server|is_server_running|get_server_port' | head -20
  echo "-- nm 全局符号总数 --"
  nm -gU "$lib" 2>/dev/null | wc -l
  echo "-- 本体 crate 的归档成员 --"
  ar t "$lib" 2>/dev/null | grep -i kugou | head -10
  echo "-- strings 兜底（原始符号名字符串）--"
  strings -a "$lib" 2>/dev/null | grep -E '^_?(start|stop)_server$|^_?is_server_running$|^_?get_server_port$' | sort -u | head -10
  echo "-- 是否含 Rust FFI 相关字符串（判断代码有没有进去）--"
  strings -a "$lib" 2>/dev/null | grep -c -i 'kugou' | head -1
}

# ---------------------------------------------------------------------------
# A. 最小复现：同 crate-type / 同 profile，看 rustc 是否为 iOS 导出符号
# ---------------------------------------------------------------------------
hr "A. 最小复现 crate（aarch64-apple-ios）"
EXP="$(mktemp -d)"
mkdir -p "$EXP/src"
cat > "$EXP/Cargo.toml" <<'TOML'
[package]
name = "kugou_exp"
version = "0.1.0"
edition = "2021"

[lib]
name = "kugou_exp"
crate-type = ["cdylib", "rlib", "staticlib"]

[profile.release]
opt-level = 3
lto = true
panic = "abort"
TOML
cat > "$EXP/src/lib.rs" <<'RS'
use std::os::raw::{c_char, c_int};

#[no_mangle]
pub unsafe extern "C" fn start_server(_port: c_int, _dir: *const c_char) -> c_int { 0 }

#[no_mangle]
pub extern "C" fn stop_server() {}

#[no_mangle]
pub extern "C" fn is_server_running() -> c_int { 0 }
RS
(
  cd "$EXP" || exit 1
  cargo build --release --target aarch64-apple-ios 2>&1 | tail -5
) 
EXP_LIB="$EXP/target/aarch64-apple-ios/release/libkugou_exp.a"
if [ -f "$EXP_LIB" ]; then
  echo "-- 最小 crate 静态库中的 C 符号 --"
  nm -gU "$EXP_LIB" 2>/dev/null | grep -E 'start_server|stop_server|is_server_running' | head -10
  echo "-- 最小 crate 全局符号总数 --"
  nm -gU "$EXP_LIB" 2>/dev/null | wc -l
else
  echo "最小 crate 未产出静态库"
fi
echo
echo "-- 上游 Cargo.toml 的 crate-type --"
grep -n 'crate-type' "$RUST_DIR/Cargo.toml" 2>/dev/null
echo "-- 上游 Cargo.toml 的 profile.release --"
sed -n '/\[profile.release\]/,$p' "$RUST_DIR/Cargo.toml" 2>/dev/null | head -20
echo "-- 上游 lib.rs 中 C FFI 导出符号定义 --"
grep -n -B2 -A2 'no_mangle' "$RUST_DIR/src/lib.rs" 2>/dev/null | head -40
rm -rf "$EXP"

# ---------------------------------------------------------------------------
# B / C. 真实产物：cargo 原始 vs xcframework 副本
# ---------------------------------------------------------------------------
dump_symbols "B. cargo 原始产物（未经 xcodebuild 打包）" "$ORIGINAL"
dump_symbols "C. xcframework 中的副本" "$XCFW"

hr "诊断结束"
exit 0
