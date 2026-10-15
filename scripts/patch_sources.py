#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
对上游 md3Music 源码做 iOS 移植改造（幂等、可校验）。

改造点：
  1) kugou_api_server/rust/Cargo.toml   : crate-type 增加 "staticlib"（iOS 静态链接必需）
  2) lib/services/kugou_server.dart     : 增加 iOS 分支 —— 静态链接场景下用
                                          DynamicLibrary.process() 解析符号，
                                          而不是 DynamicLibrary.open('libkugou_server.so')

本脚本被 apply_overlay.sh / CI 调用，任何一处模式匹配失败都会直接非 0 退出，
避免"静默改不动"导致 CI 编出来的 App 悄悄失去本地 API 能力。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ERRORS: list[str] = []
DONE: list[str] = []


def read(path: Path) -> str:
    if not path.is_file():
        ERRORS.append(f"文件不存在: {path}")
        return ""
    return path.read_text(encoding="utf-8")


def write(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")


# --------------------------------------------------------------------------
# 1) Cargo.toml : crate-type 增加 staticlib
# --------------------------------------------------------------------------
def patch_cargo(app: Path) -> None:
    path = app / "kugou_api_server" / "rust" / "Cargo.toml"
    text = read(path)
    if not text:
        return

    if '"staticlib"' in text:
        DONE.append("Cargo.toml: staticlib 已存在，跳过")
        return

    pattern = re.compile(
        r'^crate-type\s*=\s*\[\s*"cdylib"\s*,\s*"rlib"\s*\]\s*$',
        re.MULTILINE,
    )
    replacement = 'crate-type = ["cdylib", "rlib", "staticlib"]'
    new_text, count = pattern.subn(replacement, text, count=1)

    if count != 1:
        ERRORS.append(
            "Cargo.toml: 未找到 `crate-type = [\"cdylib\", \"rlib\"]`，"
            "上游可能已改动，请人工确认后更新补丁"
        )
        return

    if "# iOS" not in new_text:
        new_text = new_text.replace(
            replacement,
            replacement + "  # staticlib: iOS 静态链接（Dart FFI 走 DynamicLibrary.process()）",
            1,
        )

    write(path, new_text)
    DONE.append("Cargo.toml: 已为 iOS 增加 staticlib")


# --------------------------------------------------------------------------
# 2) kugou_server.dart : 增加 iOS 分支
# --------------------------------------------------------------------------
MARKER = "// [md3music-ios] iOS 移植"

IOS_WORKERS = '''
// [md3music-ios] iOS 静态链接专用 worker。
// iOS 不允许加载非内嵌 dylib，Rust 侧以 staticlib 链接进主程序，
// 因此必须用 DynamicLibrary.process() 在进程空间内解析符号，
// 而不能像 Android 那样 DynamicLibrary.open('libkugou_server.so')。
List<int> _startServerInWorkerIos(String dataDirPath) {
  final loadClock = Stopwatch()..start();
  final lib = DynamicLibrary.process();
  final loadMs = loadClock.elapsedMilliseconds;

  final lookupClock = Stopwatch()..start();
  final startServer = lib.lookupFunction<StartServerNative, StartServer>(
    'start_server',
  );
  lookupClock.stop();

  final nativePath = dataDirPath.toNativeUtf8();
  late final int port;
  final startClock = Stopwatch()..start();
  try {
    port = startServer(0, nativePath);
  } finally {
    calloc.free(nativePath);
  }
  final startMs = startClock.elapsedMilliseconds;
  if (port <= 0) throw StateError('start_server failed with code $port');
  return [port, loadMs, lookupClock.elapsedMilliseconds, startMs];
}

void _stopServerInWorkerIos() {
  final lib = DynamicLibrary.process();
  final stopServer = lib.lookupFunction<StopServerNative, StopServer>(
    'stop_server',
  );
  stopServer();
}

bool _isServerRunningInWorkerIos() {
  final lib = DynamicLibrary.process();
  final isRunning = lib.lookupFunction<IsRunningNative, IsRunning>(
    'is_server_running',
  );
  return isRunning() == 1;
}

'''


def patch_dart(app: Path) -> None:
    path = app / "lib" / "services" / "kugou_server.dart"
    text = read(path)
    if not text:
        return

    if MARKER in text:
        DONE.append("kugou_server.dart: iOS 分支已存在，跳过")
        return

    # --- 2.1 插入 iOS worker 函数（放在第一个 _stopServerInWorker 之前） ---
    anchor = "/// 在独立 isolate 加载动态库并停止服务器"
    if anchor not in text:
        ERRORS.append("kugou_server.dart: 未找到 _stopServerInWorker 注释锚点")
        return
    text = text.replace(anchor, IOS_WORKERS.lstrip("\n") + anchor, 1)

    # --- 2.2 _libraryName(): iOS 提前返回 ---
    old_libname = """  static String _libraryName() {
    if (Platform.isWindows) return 'kugou_server.dll';"""
    new_libname = """  static String _libraryName() {
    // [md3music-ios] iOS 为静态链接，符号在主程序内，不存在独立库文件。
    if (Platform.isIOS) return '';
    if (Platform.isWindows) return 'kugou_server.dll';"""
    if old_libname not in text:
        ERRORS.append("kugou_server.dart: 未找到 _libraryName() 锚点")
        return
    text = text.replace(old_libname, new_libname, 1)

    # --- 2.3 _loadLib(): iOS 用 DynamicLibrary.process() ---
    old_loadlib = """  static DynamicLibrary _loadLib() {
    _lib ??= DynamicLibrary.open(_libraryName());
    return _lib!;
  }"""
    new_loadlib = """  static DynamicLibrary _loadLib() {
    // [md3music-ios] iOS：staticlib 已链入主程序，用 process() 取进程句柄。
    _lib ??= Platform.isIOS
        ? DynamicLibrary.process()
        : DynamicLibrary.open(_libraryName());
    return _lib!;
  }"""
    if old_loadlib not in text:
        ERRORS.append("kugou_server.dart: 未找到 _loadLib() 锚点")
        return
    text = text.replace(old_loadlib, new_loadlib, 1)

    # --- 2.4 _startViaFfi(): Android 分支后追加 iOS 分支 ---
    old_start = """      return nativeTimes[0];
    }

    final lib = _loadLib();"""
    new_start = """      return nativeTimes[0];
    }

    // [md3music-ios] iOS：同样放到 worker isolate，避免 dlopen/Rust 启动占住 UI isolate。
    if (Platform.isIOS) {
      final appDir = await getApplicationSupportDirectory();
      final nativeTimes = await Isolate.run(
        () => _startServerInWorkerIos(appDir.path),
      );
      print(
        '[Startup] phase=ffi_start_complete(ios) '
        'lookup_ms=${nativeTimes[1]} start_server_ms=${nativeTimes[3]}',
      );
      return nativeTimes[0];
    }

    final lib = _loadLib();"""
    if old_start not in text:
        ERRORS.append("kugou_server.dart: 未找到 _startViaFfi() 分支锚点")
        return
    text = text.replace(old_start, new_start, 1)

    # --- 2.5 isRunning(): 增加 iOS 分支 ---
    old_isrunning = """      if (Platform.isAndroid) {
        running = await Isolate.run(
          () => _isServerRunningInWorker(_libraryName()),
        );
      } else {"""
    new_isrunning = """      if (Platform.isAndroid) {
        running = await Isolate.run(
          () => _isServerRunningInWorker(_libraryName()),
        );
      } else if (Platform.isIOS) {
        // [md3music-ios] iOS 静态链接：process() 解析符号。
        running = await Isolate.run(_isServerRunningInWorkerIos);
      } else {"""
    if old_isrunning not in text:
        ERRORS.append("kugou_server.dart: 未找到 isRunning() 分支锚点")
        return
    text = text.replace(old_isrunning, new_isrunning, 1)

    # --- 2.6 _stopNativeServer(): 增加 iOS 分支 ---
    old_stop = """        print('KugouApiServer stopped via background FFI isolate');
        return;
      }
      final lib = _loadLib();"""
    new_stop = """        print('KugouApiServer stopped via background FFI isolate');
        return;
      }
      if (Platform.isIOS) {
        // [md3music-ios] iOS 静态链接：在 worker isolate 里 stop，避免主线程被 join 阻塞。
        await Isolate.run(_stopServerInWorkerIos);
        print('KugouApiServer stopped via background FFI isolate (ios)');
        return;
      }
      final lib = _loadLib();"""
    if old_stop not in text:
        ERRORS.append("kugou_server.dart: 未找到 _stopNativeServer() 分支锚点")
        return
    text = text.replace(old_stop, new_stop, 1)

    # --- 2.7 FFI 失败时的兜底提示区分 iOS ---
    old_fallback = """      if (!Platform.isAndroid) {
        print(
          'dart:ffi start failed and no fallback on this platform '
          '(missing ${_libraryName()}?): $e',
        );
        rethrow;
      }"""
    new_fallback = """      if (!Platform.isAndroid) {
        // [md3music-ios] iOS 上该失败通常意味着 Rust staticlib 未链入
        // （CI 未构建 XCFramework，或链接器把符号裁掉了），App 会以
        // "无本地 API 服务" 模式继续运行。
        print(
          'dart:ffi start failed and no fallback on this platform '
          '(missing static library?): $e',
        );
        rethrow;
      }"""
    if old_fallback in text:
        text = text.replace(old_fallback, new_fallback, 1)

    write(path, text)
    DONE.append("kugou_server.dart: 已注入 iOS 分支（7 处）")


def main() -> int:
    if len(sys.argv) != 2:
        print("用法: patch_sources.py <app_dir>", file=sys.stderr)
        return 2

    app = Path(sys.argv[1]).resolve()
    if not (app / "pubspec.yaml").is_file():
        print(f"[port] 不是有效的 md3Music 目录: {app}", file=sys.stderr)
        return 2

    patch_cargo(app)
    patch_dart(app)

    for line in DONE:
        print(f"[port] ✓ {line}")
    for line in ERRORS:
        print(f"[port] ✗ {line}", file=sys.stderr)

    if ERRORS:
        print(f"[port] 移植改造失败，共 {len(ERRORS)} 处不匹配", file=sys.stderr)
        return 1
    print(f"[port] 移植改造完成，共 {len(DONE)} 项")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
