//
//  DHLLiveStreamResolver.h
//  DouyinHelperLite — 直播拉流地址解析
//

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, DHLStreamQuality) {
    DHLStreamQualityOrigin = 0,   // 原画  _or4
    DHLStreamQualityUHD    = 1,   // 蓝光  _uhd
    DHLStreamQualityHD     = 2,   // 高清  _hd
    DHLStreamQualitySD     = 3,   // 标清  _sd
    DHLStreamQualityLD     = 4,   // 流畅  _ld
};

extern NSString *DHLStreamQualityName(DHLStreamQuality q);

@interface DHLStreamCandidate : NSObject
@property (nonatomic, assign) DHLStreamQuality quality;
/// flv / hls / rtmp
@property (nonatomic, copy) NSString *protocol;
@property (nonatomic, copy) NSString *url;
@end


@interface DHLLiveStreamResolver : NSObject

+ (instancetype)sharedResolver;

/// 拉 reflow 页面并解析出全部可用流地址。
/// roomID 可为纯数字，或 rtmp 里那种带下划线的复合 ID。
- (void)resolveRoomID:(NSString *)roomID
           completion:(void (^)(NSArray<DHLStreamCandidate *> *candidates, NSError *error))completion;

/// 仅解析 HTML 文本（单元测试 / 离线调试用）
+ (NSArray<DHLStreamCandidate *> *)parseHTML:(NSString *)html;

@end
