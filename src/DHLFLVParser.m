//
//  DHLFLVParser.m
//  DouyinHelperLite
//

#import "DHLFLVParser.h"

static const NSUInteger kFLVHeaderSize = 9;      // 'FLV' + ver + flags + headerSize(4)
static const NSUInteger kFLVTagHeaderSize = 11;  // type + size(3) + ts(3) + tsExt + streamID(3)
static const NSUInteger kFLVTagTrailerSize = 4;  // PreviousTagSize

@implementation DHLFLVTag
- (NSString *)description {
    return [NSString stringWithFormat:@"<FLVTag type=%u ts=%u len=%lu>",
            self.type, self.timestamp, (unsigned long)self.payload.length];
}
@end


@implementation DHLFLVParser {
    NSMutableData *_buf;
    BOOL _validated;
    BOOL _rejected;
    BOOL _sawFirstPrevTagSize;
}

- (instancetype)init {
    if ((self = [super init])) {
        _buf = [NSMutableData dataWithCapacity:256 * 1024];
    }
    return self;
}

- (void)reset {
    [_buf setLength:0];
    _validated = NO;
    _rejected = NO;
    _sawFirstPrevTagSize = NO;
    _consumedBytes = 0;
}

- (BOOL)headerValidated { return _validated; }

- (NSArray<DHLFLVTag *> *)appendData:(NSData *)data {
    if (_rejected) return @[];
    if (data.length) [_buf appendData:data];

    NSMutableArray<DHLFLVTag *> *tags = [NSMutableArray array];

    // ---- 1. header ----
    if (!_validated) {
        if (_buf.length < kFLVHeaderSize) return tags;
        const uint8_t *p = _buf.bytes;
        if (memcmp(p, "FLV", 3) != 0) {
            // 抖音部分 CDN 会先吐 TS 分片或 302 页面，直接判定非法
            _rejected = YES;
            return tags;
        }
        uint32_t headerSize = ((uint32_t)p[5] << 24) | ((uint32_t)p[6] << 16) |
                              ((uint32_t)p[7] << 8)  | (uint32_t)p[8];
        if (headerSize < kFLVHeaderSize || headerSize > 1024) headerSize = kFLVHeaderSize;
        if (_buf.length < headerSize) return tags;
        [_buf replaceBytesInRange:NSMakeRange(0, headerSize) withBytes:NULL length:0];
        _consumedBytes += headerSize;
        _validated = YES;
    }

    // ---- 2. 首个 PreviousTagSize0 ----
    if (!_sawFirstPrevTagSize) {
        if (_buf.length < 4) return tags;
        [_buf replaceBytesInRange:NSMakeRange(0, 4) withBytes:NULL length:0];
        _consumedBytes += 4;
        _sawFirstPrevTagSize = YES;
    }

    // ---- 3. 逐个 tag ----
    while (_buf.length >= kFLVTagHeaderSize) {
        const uint8_t *p = _buf.bytes;

        uint8_t  type      = p[0] & 0x1F;   // 低 5 位才是 tag type，高位是 reserved/encryption
        uint32_t dataSize  = ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
        uint32_t tsLow     = ((uint32_t)p[4] << 16) | ((uint32_t)p[5] << 8) | (uint32_t)p[6];
        uint32_t tsExt     = (uint32_t)p[7];
        uint32_t timestamp = (tsExt << 24) | tsLow;

        // 防御：dataSize 超过 16MB 一定是流错位，放弃
        if (dataSize > 16u * 1024u * 1024u) {
            _rejected = YES;
            return tags;
        }

        NSUInteger need = kFLVTagHeaderSize + dataSize + kFLVTagTrailerSize;
        if (_buf.length < need) break;   // 等更多数据

        NSData *payload = [_buf subdataWithRange:NSMakeRange(kFLVTagHeaderSize, dataSize)];

        if (type == DHLFLVTagTypeAudio || type == DHLFLVTagTypeVideo || type == DHLFLVTagTypeScript) {
            DHLFLVTag *t = [DHLFLVTag new];
            t.type = (DHLFLVTagType)type;
            t.timestamp = timestamp;
            t.payload = payload;
            [tags addObject:t];
        }
        // 其它 type 静默丢弃（FLV 规范里 0/1/2 保留）

        [_buf replaceBytesInRange:NSMakeRange(0, need) withBytes:NULL length:0];
        _consumedBytes += need;
    }

    return tags;
}

@end
