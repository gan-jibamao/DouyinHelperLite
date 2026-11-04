//
//  DHLLiveRecorder.h
//  DouyinHelperLite — 直播录制器
//
//  设计：与 DouyinHelper 2.2-7 的 FFmpegRecorder 等效 —— 零转码。
//  原版走 FFmpeg remux（avformat_open_input → av_interleaved_write_frame）。
//  这里走 AVFoundation：解析 FLV 后把 H.264/AAC 直接灌进 AVAssetWriter，
//  同样是"不解码、只换容器"，CPU 占用与原版同量级。
//

#import <Foundation/Foundation.h>

@class DHLLiveRecorder;

@protocol DHLLiveRecorderDelegate <NSObject>
@optional
- (void)recorderDidStart:(DHLLiveRecorder *)recorder;
- (void)recorder:(DHLLiveRecorder *)recorder didUpdateDuration:(NSTimeInterval)seconds bytes:(unsigned long long)bytes;
- (void)recorder:(DHLLiveRecorder *)recorder didFinishToPath:(NSString *)path error:(NSError *)error;
- (void)recorder:(DHLLiveRecorder *)recorder didFailWithError:(NSError *)error;
@end


@interface DHLLiveRecorder : NSObject

- (instancetype)initWithStreamURL:(NSString *)url
                          quality:(NSString *)qualityName
                       outputPath:(NSString *)outputPath;

@property (nonatomic, weak) id<DHLLiveRecorderDelegate> delegate;
@property (nonatomic, readonly) BOOL isRecording;
@property (nonatomic, readonly) NSString *outputPath;
@property (nonatomic, readonly) NSString *streamURL;
@property (nonatomic, readonly) NSTimeInterval duration;
@property (nonatomic, readonly) unsigned long long receivedBytes;

- (void)startRecording;
/// 幂等；返回时会保证 writer 已 finishWriting（文件可播）
- (void)stopRecording;

/// 录制根目录：<App Documents>/DYZSLiveAudio
+ (NSString *)recordingsDirectory;
/// 生成一个新的输出路径 record_<roomID>_<时间戳>.mp4
+ (NSString *)newOutputPathForRoomID:(NSString *)roomID;

@end
