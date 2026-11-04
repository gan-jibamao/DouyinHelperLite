# 抖音助手 Lite — 直播录制提取 + 禁用热更新合并

从 `com.xuuz.douyinhelper_2.2-7_iphoneos-arm64.deb` 中提取直播录制功能，重写为独立工程，
并与 `DisableDouyinHotUpdate` 合并打包为 **一个 deb**。

- 仓库：https://github.com/gan-jibamao/DouyinHelperLite
- 包名：`com.xuuz.douyinhelper.lite`
- 版本：`1.0.0-1`
- 架构：`iphoneos-arm64`（rootless，dylib 落在 `/var/jb/`）

---

## 一、成品

`com.xuuz.douyinhelper.lite_1.0.0-1_iphoneos-arm64.deb`（42,718 字节）

```
sha256  dc9bc35ba5a99b95cfa970fde1a851ced209f1af8849c5f6a082ab81d55d82
md5     d4a5042d1406237d0eac2004e12e1045
```

包内结构：

```
/var/jb/Library/MobileSubstrate/DynamicLibraries/DouyinHelperLite.dylib   (275 KB, fat: arm64 + arm64e)
/var/jb/Library/MobileSubstrate/DynamicLibraries/DouyinHelperLite.plist
```

注入目标：`com.ss.iphone.ugc.Aweme`（国服）、`com.ss.iphone.ugc.AwemeLite`（极速版）、
`com.zhiliaoapp.musically`（国际版）。

---

## 二、原版是怎么录的（逆向结论）

从 `DouyinHelper.dylib` 2.2-7 提取的类与方法：

| 类 | 方法 | 作用 |
|---|---|---|
| `FFmpegRecorder` | `initWithStreamURL:` / `startRecording` / `stopRecording` | 单流录制 |
| `FFmpegRecorderManager` | `startRecordingWithStreamURL:` / `stopRecordingWithStreamURL:` / `stopAllRecordings` | 多流并发调度 |
| `MultiStreamRecorderViewController` | `toggleRecordingForURL:` / `showFullScreenPlayerForURL:` | 多窗口同时录制 + 播放 |
| `RecordingsViewController` | `loadRecordings` / `exportSelectedVideos` / `generateThumbnailForVideo:` | 录制列表 |
| `FFmpegRecorder` ivar | `_recording` / `_delegate` / `_streamURL` / `_outputPath` / `_thread` | — |
| `FFmpegRecorderManager` ivar | `_recorderDict` / `_syncQueue` | — |

**录制方式是纯 remux，不转码。** 反汇编 `startRecording` 的调用链是硬证据：

```
85798:  bl  _avformat_open_input
857b8:  bl  _avformat_find_stream_info
857f8:  bl  _avformat_alloc_output_context2
85840:  bl  _avcodec_parameters_copy
858a8:  bl  _avio_open
858c4:  bl  _avformat_write_header
858f4:  bl  _av_read_frame
859b4:  bl  _av_interleaved_write_frame
```

全程没有 `avcodec_send_packet` / `avcodec_receive_frame`——不解码、不编码，只换容器。

**取流两条路**（都在 dylib 字符串里）：

```
https://webcast.amemv.com/douyin/webcast/reflow/%@
"stream_data":\s*(\{.*?\})
<webcast-reflow-player[^>]+url="([^"]+)"[^>]+backupUrl="([^"]+)"[^>]*>
```

清晰度映射：`FULL_HD / HD / SD / LD / ORIGION` → URL 后缀 `_uhd / _hd / _sd / _ld / _or4`。

**输出**：`record_%@.mp4`，目录 `Documents/DYZSLiveAudio`。

---

## 三、为什么要重写而不是抽出来用

原版的 FFmpeg 是**静态链接进 dylib** 的（`_avformat_*`、`_avcodec_*`、`_sws_*` 全是内部符号，
不是动态依赖）。要复用就得把整个 17.8 MB 的 dylib 一起带走，那不是"提取"，那是"换个壳装原包"。

本版改成 **FLV 解析 + AVFoundation 直通封装**：

```
NSURLSession 收字节流
    → DHLFLVParser 切出 tag（type/ts/payload）
    → H.264 AVC NALU + AAC raw 直接灌进 AVAssetWriter
    → MP4
```

同样是零转码。代价是要自己实现 FLV 解复用和 AVCC 长度前缀处理，收益是
**整包 42 KB，原包 6.8 MB**，且不依赖任何第三方二进制。

---

## 四、代码结构

```
DouyinHelperLite/
├── Tweak.x                              入口、悬浮球、roomID 捕获、禁热更新 hook
├── src/
│   ├── DHLFLVParser.{h,m}               流式 FLV tag 解析
│   ├── DHLLiveStreamResolver.{h,m}      reflow 页面取流
│   ├── DHLLiveRecorder.{h,m}            FLV → MP4 录制核心
│   ├── DHLRecordControl.{h,m}           46pt 悬浮球
│   └── DHLRecordingsViewController.{h,m} 录制列表
├── Makefile                              THEOS_PACKAGE_SCHEME = rootless
├── control
├── DouyinHelperLite.plist
└── .github/workflows/build.yml           macos-latest + Theos
```

---

## 五、关键技术点与踩过的坑

### 5.1 原版取流正则的致命缺陷

原版用 `"stream_data":\s*(\{.*?\})` —— **非贪婪正则在嵌套 JSON 上会提前截断**。
实测对比（`Tests/resolvetest.c`）：

```
原版非贪婪正则取出 126 字节：
  {"data":[{"id":"...","stream_info":{"flv_pull_url":{"FULL_HD":"...","HD":"..."}
                                        ↑ 到这里就停了，括号没闭合

括号配平取出 159 字节：
  {"data":[{"id":"...","stream_info":{"flv_pull_url":{...}},"status":4}],"extra":{"k":"v"}}
```

原版取出的片段括号不闭合，`NSJSONSerialization` 会直接返回 nil —— **整条 JSON 路径失效**。

本版改用括号配平扫描（跳过字符串内的 `{` `}` 和转义），能吃到完整嵌套对象。
三级兜底：JSON 配平 → 老标签正则 → 裸 `.flv`/`.m3u8` 链。

### 5.2 FLV 解析零丢包

`DHLFLVParser` 用累积缓冲 + 按需消费，不假设 TCP 分包边界。
实测（`Tests/flvtest.c`）：

```
[A] 一次性喂入 124 字节       → 4 个 tag，consumed=124   ✅
[B] 每 7 字节喂一次（分包）   → 4 个 tag，无丢失          ✅
[C] 喂入 HTML 错误页          → rejected=1，正确拒绝       ✅
```

`consumed == 输入长度` 说明零字节误差。

### 5.3 AVCC 长度前缀

FLV 的 AVC 包理论上必带 4 字节大端长度前缀，但少数源不带。
`DHLNormalizeAVCC()` 用"整段能否被长度字段精确走完"来判定，两种情况都兼容。

### 5.4 时间戳倒退

直播流偶发时间戳回退，`AVAssetWriter` 遇到会直接报错终止。
本版在 `dhlHandleVideoTag:` / `dhlHandleAudioTag:` 里比对 `_lastVideoPTS`，
倒退的帧直接丢弃。

### 5.5 mp4 建不起来怎么办

`AVAssetWriter` 需要先拿到 `AVCDecoderConfigurationRecord` 才能建立视频轨。
如果流里迟迟没有（或编码不是 H.264），本版**边收边写同名的 `.flv` 原始文件**：

- mp4 成功 → 删除 `.flv`，交付 mp4
- mp4 失败 → 交付 `.flv`（完整录像，用户不丢数据）

### 5.6 rootless 包布局

第一次构建产物落在 `Library/MobileSubstrate/`（rootful），但 `control` 声明
`iphoneos-arm64`（rootless）—— **iOS 15+ 越狱设备会找不到 dylib**。
加 `THEOS_PACKAGE_SCHEME = rootless` 后正确落到 `/var/jb/`。

`LC_RPATH` 已与原版逐条对齐：

```
/var/jb/Library/Frameworks
/var/jb/usr/lib
@loader_path/.jbroot/Library/Frameworks
@loader_path/.jbroot/usr/lib
```

### 5.7 Logos 的 forward declaration 陷阱

`%hook` 只生成 `@class` 前置声明，hook 体内 `[self valueForKey:]` 会报
`receiver type ... for instance message is a forward declaration`。
必须自己补最小 `@interface`。

### 5.8 编译期踩到的具体错误

| 错误 | 修法 |
|---|---|
| `receiver type ... forward declaration` | 补 `@interface AWELiveNewPreStreamViewController : UIViewController @end` 等 |
| `use of undeclared identifier 'NSLineBreakByMiddleTruncation'` | 正确名是 `NSLineBreakByTruncatingMiddle` |
| `/bin/bash: ldid: command not found` | CI 里 `brew install ldid` |
| 产物路径是 rootful | `THEOS_PACKAGE_SCHEME = rootless` |

---

## 六、功能

### 6.1 直播录制

- **入口**：46pt 悬浮球，可拖动
  - 单击 = 开始 / 停止录制
  - 长按 = 打开录制列表
- 进入直播间时自动抓 `roomID`（hook `AWELiveNewPreStreamViewController` / `IESLiveAudienceViewController`）
- 抓不到时弹窗手输
- 解析出多档清晰度后弹 ActionSheet 选择（标注协议：FLV / HLS / RTMP）
- 录制中悬浮球呼吸闪动
- 保存路径：`<抖音沙盒>/Documents/DYZSLiveAudio/record_<roomID>_<时间戳>.mp4`

### 6.2 录制列表

- 缩略图（异步生成，`NSCache` 缓存）
- 文件大小 + 修改时间
- 点击播放（`AVPlayerViewController`）
- 左滑分享 / 删除

### 6.3 禁用热更新（原样保留）

```objc
%hook AWEDynamicPatchModel
- (void)setRawData:(NSData *)rawData       { %orig(nil); }
- (void)setSourceRawData:(NSData *)data    { %orig(nil); }
%end
```

`AWEDynamicPatchModel` 是抖音 AWE 框架的热补丁数据模型，服务端下发的补丁通过
这两个 setter 写入。置空后补丁静默失效，不崩溃不报错。

反汇编确认 `MSHookMessageEx` 是真导入、真调用（4 次注册），不是空壳字符串。

---

## 七、构建

### GitHub Actions（推荐）

推送到 `main` 自动触发，产物在 Actions → Artifacts → `douyinhelper-lite`。

### 本地

```sh
export THEOS=~/theos
make clean && make package FINAL=1 DEBUG=0
```

需要 Theos + iOS SDK。macOS 上 `install-theos` 会自动装 SDK；
Linux 上需手动放置 `$THEOS/sdks/iPhoneOS*.sdk`。

---

## 八、安装

```sh
# rootless 越狱（Dopamine / palera1n / unc0ver-rootless）
dpkg -i com.xuuz.douyinhelper.lite_1.0.0-1_iphoneos-arm64.deb
# 或
sileo install com.xuuz.douyinhelper.lite

# 装完必须彻底重启抖音
killall -9 Aweme
```

**不要与原版 `com.xuuz.douyinhelper` 同时安装**——两者会 hook 同一批方法，行为未定义。

---

## 九、已知限制

1. **只处理 H.264 + AAC。** 抖音直播目前都是这个组合；若遇到 H.265（`codecId == 12`），
   本版会走 FLV 兜底（保存原始文件），不会转码。
2. **单流录制。** 原版 `MultiStreamRecorderViewController` 支持多路同时录，
   本版暂未实现（单直播间单路）。
3. **取流依赖 reflow 页面结构。** 抖音改版会失效，已做三级兜底但仍可能全挂。
4. **未在真机验证。** 代码已通过真实 Theos 编译（arm64 + arm64e 全部链接成功），
   FLV 解析与 JSON 配平逻辑有独立单测，但**没有在越狱设备上跑过真实直播流**。

---

## 十、验证记录

| 项 | 方法 | 结果 |
|---|---|---|
| 编译 | GitHub Actions + Theos（macOS，iPhoneOS26.5 SDK） | arm64 + arm64e 全部编译链接通过 |
| 打包 | `make package` | 42,718 字节 deb，结构合法 |
| 架构 | `llvm-objdump --dylibs-used` | fat: arm64(0x4000) + arm64e(0x24000) |
| 布局 | `dpkg-deb -R` | `/var/jb/Library/MobileSubstrate/DynamicLibraries/` |
| rpath | `llvm-objdump --private-headers` | 4 条，与原版逐条一致 |
| hook | `llvm-objdump -d` | 4 次 `MSHookMessageEx` 调用 |
| FLV 解析 | `Tests/flvtest.c` | 3 场景全过，零丢包 |
| 取流解析 | `Tests/resolvetest.c` | 配平版比原版多取 33 字节，原版 JSON 不闭合 |
