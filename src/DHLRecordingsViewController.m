//
//  DHLRecordingsViewController.m
//  DouyinHelperLite
//

#import "DHLRecordingsViewController.h"
#import "DHLLiveRecorder.h"
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>

@interface DHLRecordingsViewController () <UITableViewDataSource, UITableViewDelegate, UIActionSheetDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *items;
@property (nonatomic, strong) NSCache *thumbCache;
@property (nonatomic, strong) AVPlayer *previewPlayer;
@end

@implementation DHLRecordingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"直播录制";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.thumbCache = [NSCache new];
    self.thumbCache.countLimit = 60;

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self
                                                      action:@selector(dismissSelf)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                      target:self
                                                      action:@selector(reload)];

    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = 76;
    [self.view addSubview:self.table];

    [self reload];
}

- (void)dismissSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)reload {
    [self.items removeAllObjects];
    self.items = [NSMutableArray array];

    NSString *dir = [DHLLiveRecorder recordingsDirectory];
    NSArray<NSString *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL];

    for (NSString *name in files) {
        NSString *ext = name.pathExtension.lowercaseString;
        if (!([ext isEqualToString:@"mp4"] || [ext isEqualToString:@"flv"])) continue;

        NSString *full = [dir stringByAppendingPathComponent:name];
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:full error:NULL];
        unsigned long long size = [attr fileSize];

        [self.items addObject:@{
            @"path": full,
            @"name": name,
            @"size": @(size),
            @"mtime": attr[NSFileModificationDate] ?: [NSDate date],
            @"ext": ext,
        }];
    }

    // 新的排前面
    [self.items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"mtime"] compare:a[@"mtime"]];
    }];

    [self.table reloadData];
}

#pragma mark - table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"dhl.rec.cell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        cell.imageView.contentMode = UIViewContentModeScaleAspectFill;
        cell.imageView.clipsToBounds = YES;
    }

    NSDictionary *it = self.items[indexPath.row];
    cell.textLabel.text = it[@"name"];
    cell.textLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    cell.textLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;

    double mb = [it[@"size"] unsignedLongLongValue] / 1024.0 / 1024.0;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %.1f MB",
                                 [self dhlFormatDate:it[@"mtime"]], mb];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

    UIImage *cached = [self.thumbCache objectForKey:it[@"path"]];
    if (cached) {
        cell.imageView.image = cached;
    } else {
        cell.imageView.image = nil;
        [self dhlLoadThumbForPath:it[@"path"] completion:^(UIImage *img) {
            if (!img) return;
            [self.thumbCache setObject:img forKey:it[@"path"]];
            dispatch_async(dispatch_get_main_queue(), ^{
                UITableViewCell *c = [tableView cellForRowAtIndexPath:indexPath];
                if (c) c.imageView.image = img;
            });
        }];
    }

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *it = self.items[indexPath.row];
    NSURL *url = [NSURL fileURLWithPath:it[@"path"]];

    AVPlayerViewController *vc = [AVPlayerViewController new];
    self.previewPlayer = [AVPlayer playerWithURL:url];
    vc.player = self.previewPlayer;
    [self presentViewController:vc animated:YES completion:nil];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *it = self.items[indexPath.row];

    UIContextualAction *share = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                        title:@"分享"
                                                                      handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        UIActivityViewController *av = [[UIActivityViewController alloc]
            initWithActivityItems:@[[NSURL fileURLWithPath:it[@"path"]]] applicationActivities:nil];
        [self presentViewController:av animated:YES completion:nil];
        done(YES);
    }];
    share.backgroundColor = [UIColor systemBlueColor];

    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                      title:@"删除"
                                                                    handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        [[NSFileManager defaultManager] removeItemAtPath:it[@"path"] error:NULL];
        [self.thumbCache removeObjectForKey:it[@"path"]];
        [self reload];
        done(YES);
    }];

    return [UISwipeActionsConfiguration configurationWithActions:@[del, share]];
}

#pragma mark - helpers

- (NSString *)dhlFormatDate:(NSDate *)d {
    static NSDateFormatter *df;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [NSDateFormatter new];
        df.dateFormat = @"MM-dd HH:mm";
    });
    return [df stringFromDate:d] ?: @"";
}

- (void)dhlLoadThumbForPath:(NSString *)path completion:(void (^)(UIImage *))completion {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    AVAssetImageGenerator *gen = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    gen.appliesPreferredTrackTransform = YES;
    gen.maximumSize = CGSizeMake(160, 160);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *err = nil;
        CMTime t = CMTimeMakeWithSeconds(1.0, 600);
        CGImageRef img = [gen copyCGImageAtTime:t actualTime:NULL error:&err];
        UIImage *ui = img ? [UIImage imageWithCGImage:img] : nil;
        if (img) CGImageRelease(img);
        if (completion) completion(ui);
    });
}

@end
