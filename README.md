# md3Music iOS 移植（Flutter + Rust）

把 [zzyoxml/md3Music](https://github.com/zzyoxml/md3Music)（Android 音乐客户端）移植到 iOS 的**移植层**仓库。

构建时不依赖本地环境：CI 从上游拉取源码 → 叠加本仓库的移植改造 → 在 macOS runner 上编译出 **未签名 IPA**。

> 上游基准：`https://github.com/zzyoxml/md3Music` @ `rust-local-force`
> 上游许可证：**AGPL-3.0**（本仓库同样遵循，见下方「许可与署名」）

---

## 为什么是「移植层」而不是完整源码副本

上游仓库 271 MB，其中包含 4 个 ABI 的预编译 `.so`、vendored crates、大量截图。
把整份源码复制进本仓库，会让每次上游更新都要重新搬运一次。

因此本仓库只承载**移植改造本身**（源码补丁 + iOS 平台工程生成脚本 + CI），
构建时由 CI 在 GitHub 内网以秒级速度拉取上游，再叠加改造。这样：

- 上游更新只需改一个 `UPSTREAM_REF`，不用重新搬 270 MB
- 改造点全部是**有断言的脚本**，上游结构一变就立刻报错，不会静默编出错误产物
- 仓库体积小、clone 快

---

## 移植改造清单

全部改造集中在 `scripts/patch_sources.py` 与 `scripts/ios_prepare.sh`，均为幂等 + 断言校验。

### 1. Rust API 服务器：cdylib → 增加 staticlib

```toml
# kugou_api_server/rust/Cargo.toml
crate-type = ["cdylib", "rlib", "staticlib"]
```

iOS 不允许 App 加载外来的 `.dylib`，所以必须改成静态库，链接进主程序。

### 2. Dart FFI：`DynamicLibrary.open` → `DynamicLibrary.process()`

上游 `lib/services/kugou_server.dart` 在 Android 上这样加载：

```dart
_lib ??= DynamicLibrary.open('libkugou_server.so');   // Android
```

iOS 上静态库的符号就在主程序里，没有独立库文件可打开，必须改成：

```dart
_lib ??= Platform.isIOS
    ? DynamicLibrary.process()
    : DynamicLibrary.open(_libraryName());
```

同时在 worker isolate 内新增了 3 个 iOS 专用函数
（`_startServerInWorkerIos` / `_stopServerInWorkerIos` / `_isServerRunningInWorkerIos`），
并在 `_startViaFfi` / `isRunning` / `_stopNativeServer` 三处补齐 iOS 分支。

> 上游原本的 JNI 兜底（`MethodChannel`）在 iOS 上无意义，iOS 分支不依赖它。

### 3. 符号裁剪问题：`-force_load`

Rust 导出的 `start_server` / `stop_server` / `is_server_running` **没有任何原生代码静态引用它们**，
链接器默认会把对应目标文件整个裁掉，导致运行时 `DynamicLibrary.process()` 查不到符号。

因此 `ios/Podfile` 会被注入 `post_install` 钩子，对 Runner target 追加：

```ruby
-force_load ".../KugouServer.xcframework/ios-arm64/libkugou_server.a"
```

### 4. iOS 平台工程

用 `flutter create --platforms=ios` 在临时目录生成模板（**不直接在上游工程里生成**，
避免覆盖上游已有的 `lib/` 与平台配置），只把 `ios/` 拷进来，然后打补丁：

| 补丁 | 内容 |
| --- | --- |
| 部署目标 | `IPHONEOS_DEPLOYMENT_TARGET = 14.0` |
| 后台播放 | `UIBackgroundModes = [audio]`（本地 API 服务器靠它保活） |
| 权限文案 | 麦克风（听歌识曲）、相机（扫码登录）、相册读写、本地网络、媒体库 |
| 网络 | `NSAllowsLocalNetworking`（放行 `127.0.0.1` 本地服务） |
| 文件共享 | `UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace` |
| CocoaPods | 接入本地 `kugou_server` pod（**仅在 XCFramework 已构建时**） |

---

## CI 流水线

### `.github/workflows/ios-release.yml` — 出 IPA

| 触发 | 行为 |
| --- | --- |
| 推送 `v*` 标签 | 构建 IPA + 创建 GitHub Release 并附上 ipa |
| 手动 `workflow_dispatch` | 只构建并上传 Artifact |

流程：拉取上游 → 叠加移植层 → 编译 Rust 为 XCFramework →
`flutter build ios --release --no-codesign` → 打包 `Payload/` 为 `.ipa` → 上传/发布。

**Rust 步骤是 best-effort**：`continue-on-error: true`。
即使 Rust 编译失败也会照常产出 IPA（App 以「无本地 API 服务」模式运行），
产物名会体现这一点：

```
MD3Music-<版本>-ios-with-rust-server-unsigned.ipa   # 已链接 Rust 服务
MD3Music-<版本>-ios-standard-unsigned.ipa           # 未链接
```

### `.github/workflows/ci.yml` — 移植校验 / 分析 / 测试

在 Ubuntu runner 上跑：叠加移植层（含锚点断言）→ 校验改造结果 → `flutter pub get` →
`flutter analyze` → `flutter test`，结果汇总到 Job Summary。

> 未链接 Rust 原生库，依赖本地 API 服务的用例会失败，属预期范围。

---

## 怎么用

```bash
# 手动触发一次构建
gh workflow run "iOS Release (unsigned IPA)" --repo heweiliang88/md3Music-ios

# 或者打标签发版
git tag v6.0.1-ios.1 && git push origin v6.0.1-ios.1
```

构建完成后的 ipa 在 **Actions → 对应 run → Artifacts**，或标签触发的 **Releases** 里。

### 关于签名

**产物未做任何签名**，无法直接装到未越狱设备。需要自行处理：

- AltStore / Sideloadly + 免费 Apple ID（7 天有效）
- 开发者证书重签（$99/年，1 年有效）
- TrollStore（仅特定系统版本）

---

## 已知限制

- **上游 Android 专属能力在 iOS 上不存在**，本次移植只是让工程能编译、能出包，
  并未实现 iOS 侧的替代方案。详见「功能分级」：
  - V1 可直接实现：内容/播放/歌词/个性化四大主线
  - V2 需换技术实现：小组件（WidgetKit）、锁屏歌词（Live Activity）、均衡器（AVAudioEngine）等
  - V3 无解：USB 独占输出、桌面悬浮歌词、Flyme 状态栏歌词、DLNA 组播、Android TV 遥控等
- 上游 `android/`、`windows/` 平台代码仍在仓库内（CI 不编译它们）。
- 视频/媒体等依赖 CocoaPods 首次安装较慢，macOS job 首次运行约 10–20 分钟。

---

## 许可与署名

本项目是 [zzyoxml/md3Music](https://github.com/zzyoxml/md3Music) 的移植，遵循上游的
**GNU AGPL-3.0** 许可证。上游版权归原作者所有。

分发本移植产物时，必须：

1. 保留上游的 `LICENSE`（AGPL-3.0）与版权声明
2. 保留上游的 `DISCLAIMER.md`
3. 以相同许可证开放本移植层源码

上游明确声明「仅供学习，请勿用于商业用途」；同时这是一个基于第三方音乐平台
未公开接口的客户端，**无法通过 App Store 审核**，请自行评估合规风险。
