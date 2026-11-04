//
//  Tweak.x
//  DouyinHelperLite
//
//  【一】直播录制 —— 从 DouyinHelper 2.2-7 提取重写
//       原版 FFmpegRecorder 走 FFmpeg remux；本版走 AVFoundation 直通封装，
//       同样零转码，且不必把 17MB 的 FFmpeg 打进包。
//  【二】禁用热更新 —— 来自 DisableDouyinHotUpdate，hook 体原样保留
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "src/DHLLiveStreamResolver.h"
#import "src/DHLLiveRecorder.h"
#import "src/DHLRecordingsViewController.h"
#import "src/DHLRecordControl.h"

// ============================================================
// 全局状态
// ============================================================

static DHLLiveRecorder *gRecorder = nil;
static NSString        *gRoomID   = nil;
static UIWindow        *gOverlayWindow = nil;
static DHLRecordControl *gControl = nil;

static void DHLSetCurrentRoomID(NSString *rid) {
    if (rid.length) gRoomID = [rid copy];
}

static UIViewController *DHLTopViewController(void) {
    UIWindow *key = nil;
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            if (w.isKeyWindow) { key = w; break; }
        }
        if (key) break;
    }
    if (!key) key = [UIApplication sharedApplication].keyWindow;
    UIViewController *vc = key.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:[UINavigationController class]])
        vc = ((UINavigationController *)vc).visibleViewController;
    if ([vc isKindOfClass:[UITabBarController class]])
        vc = ((UITabBarController *)vc).selectedViewController;
    return vc;
}

static void DHLToast(NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = DHLTopViewController();
        if (!top) return;
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [top presentViewController:ac animated:YES completion:^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [ac dismissViewControllerAnimated:YES completion:nil];
            });
        }];
    });
}

static void DHLShowRecordings(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        DHLRecordingsViewController *vc = [DHLRecordingsViewController new];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.modalPresentationStyle = UIModalPresentationFullScreen;
        UIViewController *top = DHLTopViewController();
        if (top) [top presentViewController:nav animated:YES completion:nil];
    });
}


// ============================================================
// 录制代理：所有回调都汇到这里，不依赖任何业务控制器
// ============================================================

@interface DHLRecorderProxy : NSObject <DHLLiveRecorderDelegate>
@end

@implementation DHLRecorderProxy

- (void)recorderDidStart:(DHLLiveRecorder *)r {
    NSLog(@"[DHL] 录制开始 → %@", r.outputPath);
    dispatch_async(dispatch_get_main_queue(), ^{ [gControl setRecording:YES]; });
}

- (void)recorder:(DHLLiveRecorder *)r didFailWithError:(NSError *)e {
    NSLog(@"[DHL] 录制失败: %@", e);
    dispatch_async(dispatch_get_main_queue(), ^{
        [gControl setRecording:NO];
        DHLToast(e.localizedDescription ?: @"录制失败");
    });
}

- (void)recorder:(DHLLiveRecorder *)r didFinishToPath:(NSString *)path error:(NSError *)e {
    NSLog(@"[DHL] 录制结束 → %@ (err=%@)", path, e);
    dispatch_async(dispatch_get_main_queue(), ^{
        [gControl setRecording:NO];
        gRecorder = nil;
        if (path.length) {
            NSString *msg = [NSString stringWithFormat:@"已保存：%@", path.lastPathComponent];
            if (e) msg = [NSString stringWithFormat:@"%@\n%@", msg, e.localizedDescription ?: @""];
            DHLToast(msg);
        }
    });
}

@end

static DHLRecorderProxy *gProxy = nil;

static DHLRecorderProxy *DHLProxy(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gProxy = [DHLRecorderProxy new]; });
    return gProxy;
}


// ============================================================
// 录制流程
// ============================================================

static void DHLStartRecordingWithURL(NSString *url, NSString *qualityName) {
    if (gRecorder.isRecording) { DHLToast(@"已经在录制中"); return; }

    NSString *path = [DHLLiveRecorder newOutputPathForRoomID:gRoomID ?: @"live"];
    DHLLiveRecorder *rec = [[DHLLiveRecorder alloc] initWithStreamURL:url
                                                             quality:qualityName
                                                          outputPath:path];
    rec.delegate = DHLProxy();
    gRecorder = rec;

    [rec startRecording];
    NSLog(@"[DHL] 开始录制 %@ → %@", url, path);
    DHLToast([NSString stringWithFormat:@"开始录制 · %@", qualityName ?: @""]);
}

static void DHLStopRecording(void) {
    if (!gRecorder.isRecording) { DHLToast(@"当前没有在录制"); return; }
    [gRecorder stopRecording];
}

static void DHLStartRecordingWithCandidates(NSArray<DHLStreamCandidate *> *list) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (list.count == 0) { DHLToast(@"没有拿到可用的直播流"); return; }

        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"选择清晰度"
                                                                    message:nil
                                                             preferredStyle:UIAlertControllerStyleActionSheet];
        for (DHLStreamCandidate *c in list) {
            NSString *title = [NSString stringWithFormat:@"%@  (%@)",
                               DHLStreamQualityName(c.quality), c.protocol.uppercaseString];
            [ac addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
                DHLStartRecordingWithURL(c.url, DHLStreamQualityName(c.quality));
            }]];
        }
        [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

        UIViewController *top = DHLTopViewController();
        if (!top) return;
        if (ac.popoverPresentationController) {
            ac.popoverPresentationController.sourceView = top.view;
            ac.popoverPresentationController.sourceRect =
                CGRectMake(CGRectGetMidX(top.view.bounds), CGRectGetMidY(top.view.bounds), 1, 1);
            ac.popoverPresentationController.permittedArrowDirections = 0;
        }
        [top presentViewController:ac animated:YES completion:nil];
    });
}

static void DHLResolveAndPick(void);

static void DHLAskRoomID(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"输入直播间 ID"
                                                                    message:@"从直播间链接或分享里取数字部分"
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.keyboardType = UIKeyboardTypeNumberPad;
            tf.placeholder = @"roomID";
        }];
        [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [ac addAction:[UIAlertAction actionWithTitle:@"解析" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
            NSString *v = [ac.textFields.firstObject.text
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (v.length == 0) return;
            DHLSetCurrentRoomID(v);
            DHLResolveAndPick();
        }]];
        UIViewController *top = DHLTopViewController();
        if (top) [top presentViewController:ac animated:YES completion:nil];
    });
}

static void DHLResolveAndPick(void) {
    NSString *rid = gRoomID;
    if (rid.length == 0) { DHLAskRoomID(); return; }

    DHLToast(@"正在解析直播流…");
    [[DHLLiveStreamResolver sharedResolver] resolveRoomID:rid
                                               completion:^(NSArray<DHLStreamCandidate *> *c, NSError *e) {
        if (c.count == 0) {
            DHLToast(e.localizedDescription ?: @"解析失败");
            return;
        }
        DHLStartRecordingWithCandidates(c);
    }];
}

/// 悬浮球单击
void DHLControlTapped(void) {
    if (gRecorder.isRecording) DHLStopRecording();
    else                       DHLResolveAndPick();
}

/// 悬浮球长按
void DHLControlShowList(void) {
    DHLShowRecordings();
}


// ============================================================
// 悬浮球
// ============================================================

static void DHLInstallFloatingButton(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (gOverlayWindow) return;

        UIWindowScene *scene = nil;
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if ([sc isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)sc; break; }
        }

        UIWindow *win = scene ? [[UIWindow alloc] initWithWindowScene:scene]
                              : [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        win.frame = [UIScreen mainScreen].bounds;
        win.windowLevel = UIWindowLevelAlert + 100;
        win.backgroundColor = [UIColor clearColor];
        win.rootViewController = [UIViewController new];
        win.hidden = NO;

        DHLRecordControl *c = [[DHLRecordControl alloc] initWithFrame:CGRectMake(0, 0, 46, 46)];
        c.center = CGPointMake(win.bounds.size.width - 34, win.bounds.size.height * 0.62);
        [win.rootViewController.view addSubview:c];

        gOverlayWindow = win;
        gControl = c;
    });
}


// ============================================================
// 【二】禁用抖音热更新（来自 DisableDouyinHotUpdate，原样）
// ============================================================

%hook AWEDynamicPatchModel

- (void)setRawData:(NSData *)rawData {
    NSLog(@"[DisableHotUpdate] setRawData: 已拦截");
    %orig(nil);
}

- (void)setSourceRawData:(NSData *)sourceRawData {
    NSLog(@"[DisableHotUpdate] setSourceRawData: 已拦截");
    %orig(nil);
}

%end


// ============================================================
// 【一】进入直播间时抓 roomID
// ============================================================

%hook AWELiveNewPreStreamViewController

- (void)viewDidLoad {
    %orig;
    @try {
        id room = [self valueForKey:@"roomID"];
        if (!room) room = [self valueForKey:@"roomId"];
        if (room) DHLSetCurrentRoomID([room description]);
    } @catch (__unused NSException *e) {}
}

%end


%hook IESLiveAudienceViewController

- (void)viewDidLoad {
    %orig;
    @try {
        id room = [self valueForKey:@"roomID"];
        if (!room) room = [self valueForKey:@"roomId"];
        if (room) DHLSetCurrentRoomID([room description]);
    } @catch (__unused NSException *e) {}
}

%end


// ============================================================
// 启动
// ============================================================

%ctor {
    %init;
    NSLog(@"[DouyinHelperLite] loaded — 直播录制 + 禁热更新");

    if (!objc_getClass("AWEDynamicPatchModel")) {
        NSLog(@"[DisableHotUpdate] AWEDynamicPatchModel not found — 类未加载或已改名");
    } else {
        NSLog(@"[DisableHotUpdate] setRawData:/setSourceRawData: hooked");
    }

    DHLInstallFloatingButton();
}
