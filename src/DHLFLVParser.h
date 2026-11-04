//
//  DHLFLVParser.h
//  DouyinHelperLite — FLV 字节流解析器
//
//  FLV 结构（全部大端）：
//    Header: 'FLV'(3) + version(1) + flags(1) + headerSize(4)
//    PreviousTagSize0(4)
//    Tag:    type(1) + dataSize(3) + timestamp(3) + tsExt(1) + streamID(3) + data + prevTagSize(4)
//
//  type: 8=audio 9=video 18=script
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

typedef NS_ENUM(uint8_t, DHLFLVTagType) {
    DHLFLVTagTypeAudio  = 8,
    DHLFLVTagTypeVideo  = 9,
    DHLFLVTagTypeScript = 18,
};

@interface DHLFLVTag : NSObject
/// 8 audio / 9 video / 18 script
@property (nonatomic, assign) DHLFLVTagType type;
/// 毫秒，已合并 timestampExtended 高 8 位
@property (nonatomic, assign) uint32_t timestamp;
/// tag 原始负载（不含 11 字节头与尾部 prevTagSize）
@property (nonatomic, strong) NSData *payload;
@end


@interface DHLFLVParser : NSObject

/// 喂入一段字节；返回本次能完整解析出的 tag（可能为空数组）。
/// 返回 nil 表示流不是合法 FLV —— 调用方应当中止录制。
- (NSArray<DHLFLVTag *> *)appendData:(NSData *)data;

/// 已丢弃的字节总数（诊断用）
@property (nonatomic, readonly) unsigned long long consumedBytes;
/// 是否已通过 FLV header 校验
@property (nonatomic, readonly) BOOL headerValidated;

- (void)reset;

@end
