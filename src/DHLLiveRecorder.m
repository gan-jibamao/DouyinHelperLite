//
//  DHLLiveRecorder.m
//  DouyinHelperLite
//

#import "DHLLiveRecorder.h"
#import "DHLFLVParser.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>

static NSString *const kDHLRecorderErrorDomain = @"DHLRecorder";

#pragma mark - 音频配置解析

static const uint32_t kAACSampleRates[16] = {
    96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
    16000, 12000, 11025, 8000, 7350, 0, 0, 0
};

typedef struct {
    double sampleRate;
    uint32_t channelCount;
    uint8_t objectType;
} DHLAACConfig;

/// AudioSpecificConfig: 5bit objectType | 4bit freqIndex | 4bit channelConfig
static BOOL DHLParseAudioSpecificConfig(const uint8_t *p, NSUInteger n, DHLAACConfig *out) {
    if (n < 2) return NO;
    uint32_t bits = ((uint32_t)p[0] << 8) | p[1];
    uint8_t objectType = (bits >> 11) & 0x1F;
    uint8_t freqIndex  = (bits >> 7) & 0x0F;
    uint8_t chanCfg    = (bits >> 3) & 0x0F;

    double rate = 0;
    if (freqIndex == 0x0F) {
        if (n < 5) return NO;
        uint32_t b2 = ((uint32_t)p[2] << 24) | ((uint32_t)p[3] << 16) | ((uint32_t)p[4] << 8);
        rate = (double)((b2 >> 8) & 0xFFFFFF);
    } else {
        rate = (double)kAACSampleRates[freqIndex & 0x0F];
    }
    if (rate <= 0) rate = 44100;
    if (chanCfg == 0) chanCfg = 2;

    out->objectType   = objectType ? objectType : 2;
    out->sampleRate   = rate;
    out->channelCount = chanCfg;
    return YES;
}


#pragma mark - AVCC 长度前缀修正

/// FLV 的 AVC 包用的是 AVCC 格式（每个 NAL 前 4 字节大端长度）。
/// 少数源不带前缀，这里用"整段能否被长度字段精确走完"来判定，两种情况都兼容。
static NSData *DHLNormalizeAVCC(NSData *src) {
    const uint8_t *p = src.bytes;
    NSUInteger n = src.length;
    if (n == 0) return nil;

    // 尝试按 [4字节长度][NAL]... 完整走一遍
    NSUInteger off = 0;
    BOOL looksPrefixed = (n >= 4);
    while (off + 4 <= n) {
        uint32_t len = ((uint32_t)p[off] << 24) | ((uint32_t)p[off + 1] << 16) |
                       ((uint32_t)p[off + 2] << 8) | (uint32_t)p[off + 3];
        if (len == 0) { looksPrefixed = NO; break; }
        if (off + 4 + len > n) { looksPrefixed = NO; break; }
        off += 4 + len;
        if (off == n) break;
    }
    if (off != n) looksPrefixed = NO;

    if (looksPrefixed) return src;

    // 当成单个裸 NAL，补 4 字节长度前缀
    NSMutableData *md = [NSMutableData dataWithCapacity:n + 4];
    uint8_t hdr[4] = { (uint8_t)(n >> 24), (uint8_t)(n >> 16), (uint8_t)(n >> 8), (uint8_t)n };
    [md appendBytes:hdr length:4];
    [md appendData:src];
    return md;
}


#pragma mark -

@interface DHLLiveRecorder () <NSURLSessionDataDelegate>
@property (nonatomic, readwrite) BOOL isRecording;
@property (nonatomic, readwrite) NSString *outputPath;
@property (nonatomic, readwrite) NSString *streamURL;
@property (nonatomic, readwrite) NSTimeInterval duration;
@property (nonatomic, readwrite) unsigned long long receivedBytes;
@end


@implementation DHLLiveRecorder {
    NSString *_qualityName;

    NSURLSession *_session;
    NSURLSessionDataTask *_task;

    DHLFLVParser *_parser;

    // 原始字节备份（AVAssetWriter 建立失败时的兜底）
    NSFileHandle *_rawHandle;
    NSString *_rawPath;

    // AVAssetWriter 管线
    AVAssetWriter *_writer;
    AVAssetWriterInput *_videoIn;
    AVAssetWriterInput *_audioIn;
    BOOL _writerReady;
    BOOL _sessionStarted;

    CMVideoFormatDescriptionRef _videoFmt;
    CMAudioFormatDescriptionRef _audioFmt;

    CMTime _lastVideoPTS;
    CMTime _lastAudioPTS;
    CMTime _firstDTS;

    dispatch_queue_t _q;
    BOOL _stopping;
    BOOL _finished;
}

#pragma mark - 路径

+ (NSString *)recordingsDirectory {
    NSArray<NSString *> *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *base = docs.firstObject ?: NSTemporaryDirectory();
    NSString *dir = [base stringByAppendingPathComponent:@"DYZSLiveAudio"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    return dir;
}

+ (NSString *)newOutputPathForRoomID:(NSString *)roomID {
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyyMMdd_HHmmss";
    NSString *stamp = [df stringFromDate:[NSDate date]];
    NSString *safeRoom = [roomID?:@"live" stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    NSString *name = [NSString stringWithFormat:@"record_%@_%@.mp4", safeRoom, stamp];
    return [[self recordingsDirectory] stringByAppendingPathComponent:name];
}

#pragma mark - init

- (instancetype)initWithStreamURL:(NSString *)url
                          quality:(NSString *)qualityName
                       outputPath:(NSString *)outputPath {
    if ((self = [super init])) {
        _streamURL = [url copy];
        _qualityName = [qualityName copy] ?: @"";
        _outputPath = [outputPath copy];
        _parser = [DHLFLVParser new];
        _q = dispatch_queue_create("com.xuuz.dhl.recorder", DISPATCH_QUEUE_SERIAL);
        _lastVideoPTS = kCMTimeInvalid;
        _lastAudioPTS = kCMTimeInvalid;
    }
    return self;
}

- (void)dealloc {
    [_session invalidateAndCancel];
    @try { [_rawHandle closeFile]; } @catch (__unused NSException *e) {}
    if (_videoFmt) { CFRelease(_videoFmt); _videoFmt = NULL; }
    if (_audioFmt) { CFRelease(_audioFmt); _audioFmt = NULL; }
}

#pragma mark - 生命周期

- (void)startRecording {
    if (self.isRecording) return;
    self.isRecording = YES;
    self.receivedBytes = 0;
    self.duration = 0;

    // 原始 FLV 备份：与 mp4 同名，成功后再删
    _rawPath = [[self.outputPath stringByDeletingPathExtension] stringByAppendingPathExtension:@"flv"];
    [[NSFileManager defaultManager] createFileAtPath:_rawPath contents:nil attributes:nil];
    _rawHandle = [NSFileHandle fileHandleForWritingAtPath:_rawPath];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:self.streamURL]];
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)" forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"https://www.douyin.com/" forHTTPHeaderField:@"Referer"];
    req.timeoutInterval = 20.0;

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest = 20.0;
    cfg.timeoutIntervalForResource = 24 * 3600;   // 直播可长达数小时

    _session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
    _task = [_session dataTaskWithRequest:req];
    [_task resume];

    if ([self.delegate respondsToSelector:@selector(recorderDidStart:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate recorderDidStart:self];
        });
    }
}

- (void)stopRecording {
    if (!self.isRecording) {
        // 已经停过：保证 finish 语义（幂等）
        if (!_finished) [self dhlFinishWithError:nil];
        return;
    }
    _stopping = YES;
    self.isRecording = NO;
    [_task cancel];
    [_session invalidateAndCancel];
    _session = nil;
    [self dhlFinishWithError:nil];
}

#pragma mark - 收数据

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    if (data.length == 0) return;

    self.receivedBytes += data.length;

    // 原始备份
    @try { [_rawHandle writeData:data]; } @catch (__unused NSException *e) {}

    // 解析
    NSArray<DHLFLVTag *> *tags = [_parser appendData:data];
    if (tags.count == 0) {
        if (!_parser.headerValidated && _parser.consumedBytes == 0 && !self.isRecording && !_stopping) return;
        return;
    }

    for (DHLFLVTag *t in tags) {
        [self dhlHandleTag:t];
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    if (_stopping) return;                 // 主动停止，正常路径
    if (!self.isRecording) return;

    // 服务端断流 / 网络中断
    self.isRecording = NO;
    [self dhlFinishWithError:error];
}

#pragma mark - tag → sample

- (void)dhlHandleTag:(DHLFLVTag *)tag {
    if (tag.payload.length == 0) return;

    if (tag.type == DHLFLVTagTypeVideo) {
        [self dhlHandleVideoTag:tag];
    } else if (tag.type == DHLFLVTagTypeAudio) {
        [self dhlHandleAudioTag:tag];
    } else if (tag.type == DHLFLVTagTypeScript) {
        // onMetaData：尝试取 duration 等信息，录制不依赖它
        return;
    }
}

- (void)dhlHandleVideoTag:(DHLFLVTag *)tag {
    const uint8_t *p = tag.payload.bytes;
    NSUInteger n = tag.payload.length;
    if (n < 5) return;

    uint8_t frameType = (p[0] >> 4) & 0x0F;
    uint8_t codecId   = p[0] & 0x0F;
    if (codecId != 7) return;              // 只处理 AVC/H.264
    if (frameType == 5) return;            // 视频信息帧，无画面

    uint8_t avcPacketType = p[1];
    int32_t cts = 0;
    if (n >= 5) {
        cts = ((int32_t)(int8_t)p[2] << 16) | ((int32_t)p[3] << 8) | (int32_t)p[4];
    }

    if (avcPacketType == 0) {
        // AVCDecoderConfigurationRecord → 建立 format description
        [self dhlConfigureVideoWithAVCC:[tag.payload subdataWithRange:NSMakeRange(5, n - 5)]];
        return;
    }
    if (avcPacketType != 1) return;        // 2 = end of sequence

    if (!_writerReady || !_videoIn) return;

    NSData *nalu = DHLNormalizeAVCC([tag.payload subdataWithRange:NSMakeRange(5, n - 5)]);
    if (nalu.length == 0) return;

    CMTime dts = CMTimeMake((int64_t)tag.timestamp, 1000);
    CMTime pts = CMTimeAdd(dts, CMTimeMake(cts, 1000));

    if (CMTIME_IS_VALID(_lastVideoPTS) && CMTimeCompare(pts, _lastVideoPTS) <= 0) {
        // 时间戳倒退：丢弃，否则 AVAssetWriter 直接报错
        return;
    }

    CMSampleBufferRef sb = [self dhlSampleBufferWithData:nalu
                                                   pts:pts
                                                   dts:dts
                                            formatDesc:_videoFmt];
    if (!sb) return;

    if (!_sessionStarted) [self dhlBeginSessionWithTime:dts];

    if ([_videoIn isReadyForMoreMediaData] && [_videoIn appendSampleBuffer:sb]) {
        _lastVideoPTS = pts;
    }
    CFRelease(sb);
}

- (void)dhlHandleAudioTag:(DHLFLVTag *)tag {
    const uint8_t *p = tag.payload.bytes;
    NSUInteger n = tag.payload.length;
    if (n < 2) return;

    uint8_t soundFormat = (p[0] >> 4) & 0x0F;
    if (soundFormat != 10) return;         // 只处理 AAC

    uint8_t aacPacketType = p[1];
    if (aacPacketType == 0) {
        [self dhlConfigureAudioWithASC:[tag.payload subdataWithRange:NSMakeRange(2, n - 2)]];
        return;
    }
    if (aacPacketType != 1) return;

    if (!_writerReady || !_audioIn || !_audioFmt) return;

    CMTime ts = CMTimeMake((int64_t)tag.timestamp, 1000);
    if (CMTIME_IS_VALID(_lastAudioPTS) && CMTimeCompare(ts, _lastAudioPTS) <= 0) return;

    NSData *raw = [tag.payload subdataWithRange:NSMakeRange(2, n - 2)];
    CMSampleBufferRef sb = [self dhlSampleBufferWithData:raw pts:ts dts:ts formatDesc:_audioFmt];
    if (!sb) return;

    if (!_sessionStarted) [self dhlBeginSessionWithTime:ts];

    if ([_audioIn isReadyForMoreMediaData] && [_audioIn appendSampleBuffer:sb]) {
        _lastAudioPTS = ts;
    }
    CFRelease(sb);
}

#pragma mark - 格式描述

- (void)dhlConfigureVideoWithAVCC:(NSData *)avcc {
    if (_videoFmt || avcc.length < 7) return;

    const uint8_t *p = avcc.bytes;
    NSUInteger n = avcc.length;
    if (p[0] != 1) return;

    uint8_t numSPS = p[5] & 0x1F;
    if (numSPS == 0) return;

    NSUInteger off = 6;
    NSMutableArray *params = [NSMutableArray array];
    for (uint8_t i = 0; i < numSPS; i++) {
        if (off + 2 > n) return;
        uint16_t len = ((uint16_t)p[off] << 8) | p[off + 1];
        off += 2;
        if (off + len > n) return;
        [params addObject:[avcc subdataWithRange:NSMakeRange(off, len)]];
        off += len;
    }
    if (off >= n) return;
    uint8_t numPPS = p[off];
    off += 1;
    for (uint8_t i = 0; i < numPPS; i++) {
        if (off + 2 > n) return;
        uint16_t len = ((uint16_t)p[off] << 8) | p[off + 1];
        off += 2;
        if (off + len > n) return;
        [params addObject:[avcc subdataWithRange:NSMakeRange(off, len)]];
        off += len;
    }

    if (params.count < 2) return;

    const uint8_t *ptrs[8];
    size_t sizes[8];
    for (NSUInteger i = 0; i < params.count && i < 8; i++) {
        NSData *d = params[i];
        ptrs[i] = d.bytes;
        sizes[i] = d.length;
    }

    CMVideoFormatDescriptionRef fd = NULL;
    OSStatus st = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault,
                                                                     (size_t)MIN(params.count, (NSUInteger)8),
                                                                     ptrs, sizes, 4, &fd);
    if (st == noErr && fd) {
        _videoFmt = fd;
        [self dhlSetupWriterIfPossible];
    }
}

- (void)dhlConfigureAudioWithASC:(NSData *)asc {
    if (_audioFmt || asc.length < 2) return;

    DHLAACConfig cfg;
    if (!DHLParseAudioSpecificConfig(asc.bytes, asc.length, &cfg)) return;

    AudioStreamBasicDescription asbd = {0};
    asbd.mSampleRate = cfg.sampleRate;
    asbd.mFormatID = kAudioFormatMPEG4AAC;
    asbd.mFormatFlags = 0;
    asbd.mFramesPerPacket = 1024;
    asbd.mChannelsPerFrame = cfg.channelCount;
    asbd.mBitsPerChannel = 0;
    asbd.mBytesPerPacket = 0;
    asbd.mBytesPerFrame = 0;

    CMAudioFormatDescriptionRef fd = NULL;
    OSStatus st = CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, NULL,
                                                 asc.length, asc.bytes, NULL, &fd);
    if (st == noErr && fd) {
        _audioFmt = fd;
        [self dhlSetupWriterIfPossible];
    }
}

- (void)dhlSetupWriterIfPossible {
    if (_writerReady || _writer) return;
    if (!_videoFmt) return;                 // 至少要视频才能建 mp4

    NSError *err = nil;
    NSURL *outURL = [NSURL fileURLWithPath:self.outputPath];
    [[NSFileManager defaultManager] removeItemAtURL:outURL error:NULL];

    _writer = [AVAssetWriter assetWriterWithURL:outURL fileType:AVFileTypeMPEG4 error:&err];
    if (!_writer) {
        [self dhlFailWriterWithError:err];
        return;
    }

    _videoIn = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                 outputSettings:nil
                                               sourceFormatHint:_videoFmt];
    _videoIn.expectsMediaDataInRealTime = YES;
    if ([_writer canAddInput:_videoIn]) [_writer addInput:_videoIn];

    if (_audioFmt) {
        _audioIn = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                                    outputSettings:nil
                                                  sourceFormatHint:_audioFmt];
        _audioIn.expectsMediaDataInRealTime = YES;
        if ([_writer canAddInput:_audioIn]) [_writer addInput:_audioIn];
    }

    if (![_writer startWriting]) {
        [self dhlFailWriterWithError:_writer.error];
        return;
    }
    _writerReady = YES;
}

- (void)dhlBeginSessionWithTime:(CMTime)t {
    if (_sessionStarted) return;
    _sessionStarted = YES;
    _firstDTS = t;
    [_writer startSessionAtSourceTime:t];
}

#pragma mark - 兜底

- (void)dhlFailWriterWithError:(NSError *)err {
    // mp4 管线建不起来 → 保留原始 FLV，用户拿到的仍是完整录像
    _videoIn = nil;
    _audioIn = nil;
    _writer = nil;
    _writerReady = NO;
    NSLog(@"[DHL] AVAssetWriter 建立失败，改为保留原始 FLV: %@", err);
}

#pragma mark - 收尾

- (void)dhlFinishWithError:(NSError *)error {
    if (_finished) return;
    _finished = YES;

    @try { [_rawHandle synchronizeFile]; [_rawHandle closeFile]; } @catch (__unused NSException *e) {}
    _rawHandle = nil;

    NSString *finalPath = self.outputPath;
    NSError *finalErr = error;

    if (_writerReady && _writer) {
        [_videoIn markAsFinished];
        if (_audioIn) [_audioIn markAsFinished];

        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block BOOL ok = NO;
        [_writer finishWritingWithCompletionHandler:^{
            ok = (self->_writer.status == AVAssetWriterStatusCompleted);
            dispatch_semaphore_signal(sem);
        }];
        // 给 writer 最多 15 秒收尾
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
        if (!ok) {
            finalErr = _writer.error ?: error;
            finalPath = _rawPath;           // mp4 失败 → 交付 flv
        } else {
            // mp4 成功，删掉备份
            [[NSFileManager defaultManager] removeItemAtPath:_rawPath error:NULL];
        }
    } else {
        // 完全没建起来 → 交付 flv
        finalPath = _rawPath;
        if (!finalErr) {
            finalErr = [NSError errorWithDomain:kDHLRecorderErrorDomain code:-10
                userInfo:@{NSLocalizedDescriptionKey:
                    @"没有解析到可用的 H.264/AAC 流，已保存原始 FLV"}];
        }
    }

    // 空文件不交付
    unsigned long long sz = [[[NSFileManager defaultManager] attributesOfItemAtPath:finalPath ?: @"" error:NULL]
                             fileSize];
    if (sz < 1024) {
        [[NSFileManager defaultManager] removeItemAtPath:finalPath error:NULL];
        finalPath = nil;
    }

    BOOL hasErr = (finalErr != nil);
    NSString *path = finalPath;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (hasErr) {
            if ([self.delegate respondsToSelector:@selector(recorder:didFailWithError:)]) {
                [self.delegate recorder:self didFailWithError:finalErr];
            }
        }
        if ([self.delegate respondsToSelector:@selector(recorder:didFinishToPath:error:)]) {
            [self.delegate recorder:self didFinishToPath:path error:hasErr ? finalErr : nil];
        }
    });
}

#pragma mark - sample buffer

- (CMSampleBufferRef)dhlSampleBufferWithData:(NSData *)data
                                         pts:(CMTime)pts
                                         dts:(CMTime)dts
                                  formatDesc:(CMFormatDescriptionRef)fd {
    // fd 由 recorder 持有，这里只借用、不释放
    if (!fd || data.length == 0) {
        return NULL;
    }

    CMBlockBufferRef block = NULL;
    OSStatus st = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL,
                                                     data.length, kCFAllocatorDefault,
                                                     NULL, 0, data.length,
                                                     kCMBlockBufferAssureMemoryNowFlag,
                                                     &block);
    if (st != noErr || !block) { return NULL; }

    st = CMBlockBufferReplaceDataBytes(data.bytes, block, 0, data.length);
    if (st != noErr) { CFRelease(block); return NULL; }

    CMSampleTimingInfo timing = { .duration = kCMTimeInvalid, .presentationTimeStamp = pts, .decodeTimeStamp = dts };

    size_t sampleSize = data.length;
    CMSampleBufferRef sb = NULL;
    st = CMSampleBufferCreateReady(kCFAllocatorDefault, block, fd,
                                   1, 1, &timing, 1, &sampleSize, &sb);
    CFRelease(block);

    return (st == noErr) ? sb : NULL;
}

@end
