//
//  DHLLiveStreamResolver.m
//  DouyinHelperLite
//
//  取流两条路，与原版 DouyinHelper 2.2-7 对齐：
//    ① 新网页结构：页面内嵌 "stream_data":{ ... }  —— 主路
//    ② 老网页结构：<webcast-reflow-player url="..." backupUrl="...">  —— 兜底
//
//  原版对 ① 用的是 "stream_data":\s*(\{.*?\})，非贪婪正则在嵌套 JSON 上会提前截断。
//  这里改用括号配平扫描，能吃到完整的嵌套对象。
//

#import "DHLLiveStreamResolver.h"

NSString *DHLStreamQualityName(DHLStreamQuality q) {
    switch (q) {
        case DHLStreamQualityOrigin: return @"原画";
        case DHLStreamQualityUHD:    return @"蓝光";
        case DHLStreamQualityHD:     return @"高清";
        case DHLStreamQualitySD:     return @"标清";
        case DHLStreamQualityLD:     return @"流畅";
    }
    return @"未知";
}

@implementation DHLStreamCandidate
- (NSString *)description {
    return [NSString stringWithFormat:@"<流 %@ %@ %@>",
            DHLStreamQualityName(self.quality), self.protocol, self.url];
}
@end


@implementation DHLLiveStreamResolver

+ (instancetype)sharedResolver {
    static DHLLiveStreamResolver *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [DHLLiveStreamResolver new]; });
    return s;
}

#pragma mark - 网络

- (void)resolveRoomID:(NSString *)roomID
           completion:(void (^)(NSArray<DHLStreamCandidate *> *, NSError *))completion {
    if (roomID.length == 0) {
        if (completion) completion(@[], [NSError errorWithDomain:@"DHL" code:-1
                                                       userInfo:@{NSLocalizedDescriptionKey: @"roomID 为空"}]);
        return;
    }

    NSString *urlStr = [NSString stringWithFormat:
        @"https://webcast.amemv.com/douyin/webcast/reflow/%@", roomID];
    NSURL *url = [NSURL URLWithString:urlStr];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                      cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                  timeoutInterval:15.0];
    // 移动端 UA：桌面 UA 会被重定向到下载页
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
                   @"AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"https://www.douyin.com/" forHTTPHeaderField:@"Referer"];

    NSURLSessionDataTask *task =
        [[NSURLSession sharedSession] dataTaskWithRequest:req
                                        completionHandler:^(NSData *data, NSURLResponse *resp,
                                                            NSError *err) {
        if (err) { if (completion) completion(@[], err); return; }
        if (data.length == 0) {
            if (completion) completion(@[], [NSError errorWithDomain:@"DHL" code:-2
                                    userInfo:@{NSLocalizedDescriptionKey: @"reflow 返回空页面"}]);
            return;
        }
        NSString *html = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!html) html = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
        NSArray *list = [[self class] parseHTML:html ?: @""];

        if (completion) {
            if (list.count == 0) {
                completion(@[], [NSError errorWithDomain:@"DHL" code:-3
                    userInfo:@{NSLocalizedDescriptionKey:
                        @"页面里没有解析到流地址（可能未开播、roomID 无效，或抖音又改版）"}]);
            } else {
                completion(list, nil);
            }
        }
    }];
    [task resume];
}

#pragma mark - 解析

/// 从 `{` 开始做括号配平，返回完整 JSON 对象的 NSRange（失败返回 NSNotFound）
static NSRange DHLScanBalancedJSON(NSString *s, NSUInteger openIdx) {
    NSUInteger n = s.length;
    if (openIdx >= n || [s characterAtIndex:openIdx] != '{') return NSMakeRange(NSNotFound, 0);

    NSInteger depth = 0;
    BOOL inStr = NO, esc = NO;
    for (NSUInteger i = openIdx; i < n; i++) {
        unichar c = [s characterAtIndex:i];
        if (inStr) {
            if (esc) { esc = NO; }
            else if (c == '\\') { esc = YES; }
            else if (c == '"') { inStr = NO; }
            continue;
        }
        if (c == '"') { inStr = YES; }
        else if (c == '{') { depth++; }
        else if (c == '}') {
            depth--;
            if (depth == 0) return NSMakeRange(openIdx, i - openIdx + 1);
        }
    }
    return NSMakeRange(NSNotFound, 0);
}

/// 从 html 里找出 `"stream_data"` 之后第一个 `{` 并配平取全
static NSString *DHLExtractStreamDataJSON(NSString *html) {
    NSRange key = [html rangeOfString:@"\"stream_data\""];
    if (key.location == NSNotFound) {
        key = [html rangeOfString:@"stream_data"];   // 少数页面键名不带引号
        if (key.location == NSNotFound) return nil;
    }
    NSUInteger from = key.location + key.length;
    NSRange brace = [html rangeOfString:@"{" options:0 range:NSMakeRange(from, html.length - from)];
    if (brace.location == NSNotFound) return nil;
    NSRange full = DHLScanBalancedJSON(html, brace.location);
    if (full.location == NSNotFound) return nil;
    return [html substringWithRange:full];
}

/// 把 flv_url 里 "uhd"/"hd"/"sd"/"ld"/"or4" 这种档位词映射到枚举
static DHLStreamQuality DHLQualityFromKey(NSString *key) {
    NSString *k = key.lowercaseString;
    if ([k containsString:@"origin"] || [k containsString:@"or4"] || [k containsString:@"full_hd"]) {
        return DHLStreamQualityOrigin;
    }
    if ([k containsString:@"uhd"] || [k containsString:@"bluray"]) return DHLStreamQualityUHD;
    if ([k containsString:@"hd"])  return DHLStreamQualityHD;
    if ([k containsString:@"sd"])  return DHLStreamQualitySD;
    if ([k containsString:@"ld"])  return DHLStreamQualityLD;
    return DHLStreamQualityHD;
}

/// 从 URL 里的 `_hd.flv` / `_uhd.m3u8` 反推清晰度（老结构兜底）
static DHLStreamQuality DHLQualityFromURL(NSString *url) {
    NSString *u = url.lowercaseString;
    if ([u containsString:@"_or4."]) return DHLStreamQualityOrigin;
    if ([u containsString:@"_uhd."]) return DHLStreamQualityUHD;
    if ([u containsString:@"_hd."])  return DHLStreamQualityHD;
    if ([u containsString:@"_sd."])  return DHLStreamQualitySD;
    if ([u containsString:@"_ld."])  return DHLStreamQualityLD;
    return DHLStreamQualityHD;
}

static NSString *DHLProtocolFromURL(NSString *url) {
    NSString *u = url.lowercaseString;
    if ([u containsString:@".m3u8"]) return @"hls";
    if ([u hasPrefix:@"rtmp"])       return @"rtmp";
    if ([u containsString:@".flv"])  return @"flv";
    if ([u containsString:@".sdp"])  return @"webrtc";
    return @"flv";
}

+ (NSArray<DHLStreamCandidate *> *)parseHTML:(NSString *)html {
    NSMutableArray<DHLStreamCandidate *> *out = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    void (^add)(NSString *, DHLStreamQuality) = ^(NSString *u, DHLStreamQuality q) {
        if (u.length < 12) return;
        // 页面里 &quot; 之类转义先还原
        NSString *clean = [u stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
        clean = [clean stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
        if (!([clean hasPrefix:@"http"] || [clean hasPrefix:@"rtmp"])) return;
        if ([seen containsObject:clean]) return;
        [seen addObject:clean];

        DHLStreamCandidate *c = [DHLStreamCandidate new];
        c.url = clean;
        c.quality = (q == DHLStreamQualityHD && [clean containsString:@"_"]) ? DHLQualityFromURL(clean) : q;
        c.protocol = DHLProtocolFromURL(clean);
        [out addObject:c];
    };

    // ---------- 路线 ①：stream_data JSON ----------
    NSString *json = DHLExtractStreamDataJSON(html);
    if (json.length) {
        NSData *jd = [json dataUsingEncoding:NSUTF8StringEncoding];
        id obj = jd ? [NSJSONSerialization JSONObjectWithData:jd options:0 error:NULL] : nil;
        if ([obj isKindOfClass:[NSDictionary class]]) {
            NSDictionary *dict = obj;
            // 线上结构：stream_data.data[0].stream_info.{flv_pull_url,hls_pull_url,rtmp_pull_url}
            id dataArr = dict[@"data"];
            NSArray *items = nil;
            if ([dataArr isKindOfClass:[NSArray class]]) items = dataArr;
            else if ([dict[@"stream_url"] isKindOfClass:[NSDictionary class]]) items = @[dict];

            for (id item in items) {
                if (![item isKindOfClass:[NSDictionary class]]) continue;
                NSDictionary *info = item[@"stream_info"] ?: item[@"stream_url"] ?: item;
                if (![info isKindOfClass:[NSDictionary class]]) continue;

                NSDictionary *flv = info[@"flv_pull_url"];
                if ([flv isKindOfClass:[NSDictionary class]]) {
                    for (NSString *k in flv) {
                        id v = flv[k];
                        if ([v isKindOfClass:[NSString class]]) add(v, DHLQualityFromKey(k));
                    }
                }
                // hls 通常是单个字符串
                id hls = info[@"hls_pull_url"];
                if ([hls isKindOfClass:[NSString class]]) add(hls, DHLQualityFromURL(hls));
                else if ([hls isKindOfClass:[NSDictionary class]]) {
                    for (NSString *k in hls) {
                        id v = hls[k];
                        if ([v isKindOfClass:[NSString class]]) add(v, DHLQualityFromKey(k));
                    }
                }
                id rtmp = info[@"rtmp_pull_url"];
                if ([rtmp isKindOfClass:[NSString class]]) add(rtmp, DHLStreamQualityHD);
            }
        }
    }

    // ---------- 路线 ②：老 webcast-reflow-player 标签 ----------
    if (out.count == 0) {
        NSRegularExpression *re = [NSRegularExpression
            regularExpressionWithPattern:@"<webcast-reflow-player[^>]+url=\"([^\"]+)\"[^>]+backupUrl=\"([^\"]+)\"[^>]*>"
                                 options:0 error:NULL];
        [re enumerateMatchesInString:html options:0 range:NSMakeRange(0, html.length)
                          usingBlock:^(NSTextCheckingResult *r, NSMatchingFlags f, BOOL *stop) {
            if (r.numberOfRanges >= 3) {
                NSString *u  = [html substringWithRange:[r rangeAtIndex:1]];
                NSString *b  = [html substringWithRange:[r rangeAtIndex:2]];
                add(u, DHLQualityFromURL(u));
                add(b, DHLQualityFromURL(b));
            }
        }];
    }

    // ---------- 路线 ③：裸 URL 兜底（任何 .flv / .m3u8 直链） ----------
    if (out.count == 0) {
        NSRegularExpression *re = [NSRegularExpression
            regularExpressionWithPattern:@"https?:\\\\?/\\\\?/[^\"'\\\\s]+\\.(?:flv|m3u8)[^\"'\\\\s]*"
                                 options:0 error:NULL];
        [re enumerateMatchesInString:html options:0 range:NSMakeRange(0, html.length)
                          usingBlock:^(NSTextCheckingResult *r, NSMatchingFlags f, BOOL *stop) {
            NSString *u = [html substringWithRange:r.range];
            add(u, DHLQualityFromURL(u));
        }];
    }

    // 排序：原画 > 蓝光 > 高清 > 标清 > 流畅；同档 flv 优先（录制最稳）
    [out sortUsingComparator:^NSComparisonResult(DHLStreamCandidate *a, DHLStreamCandidate *b) {
        if (a.quality != b.quality) return a.quality < b.quality ? NSOrderedAscending : NSOrderedDescending;
        BOOL af = [a.protocol isEqualToString:@"flv"], bf = [b.protocol isEqualToString:@"flv"];
        if (af != bf) return af ? NSOrderedAscending : NSOrderedDescending;
        return NSOrderedSame;
    }];
    return out;
}

@end
