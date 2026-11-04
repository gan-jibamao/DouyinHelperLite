//
//  DHLRecordControl.m
//  DouyinHelperLite
//
//  46pt 悬浮球：单击 = 开始/停止录制，长按 = 打开录制列表，可拖动。
//

#import "DHLRecordControl.h"

@interface DHLRecordControl ()
@property (nonatomic, strong) UIView *dot;
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, assign) BOOL recording;
@end

@implementation DHLRecordControl

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.72];
        self.layer.cornerRadius = frame.size.width / 2.0;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
        self.clipsToBounds = YES;
        self.userInteractionEnabled = YES;

        CGFloat w = frame.size.width;
        _dot = [[UIView alloc] initWithFrame:CGRectMake((w - 16) / 2.0, 8, 16, 16)];
        _dot.backgroundColor = [UIColor colorWithRed:1.0 green:0.23 blue:0.19 alpha:1.0];
        _dot.layer.cornerRadius = 8;
        _dot.userInteractionEnabled = NO;
        [self addSubview:_dot];

        _label = [[UILabel alloc] initWithFrame:CGRectMake(0, 26, w, 14)];
        _label.text = @"录";
        _label.textAlignment = NSTextAlignmentCenter;
        _label.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
        _label.textColor = [UIColor whiteColor];
        _label.userInteractionEnabled = NO;
        [self addSubview:_label];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
        [self addGestureRecognizer:pan];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap)];
        [self addGestureRecognizer:tap];

        UILongPressGestureRecognizer *lp =
            [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onLongPress:)];
        lp.minimumPressDuration = 0.6;
        [self addGestureRecognizer:lp];
    }
    return self;
}

#pragma mark - 公开

- (void)setRecording:(BOOL)recording {
    _recording = recording;
    [self dhlApplyState];
}

- (void)dhlApplyState {
    if (self.recording) {
        self.label.text = @"停";
        self.dot.backgroundColor = [UIColor whiteColor];
        // 呼吸动画
        if (!self.dot.layer.animationKeys.count) {
            CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"opacity"];
            a.fromValue = @1.0;
            a.toValue = @0.25;
            a.duration = 0.8;
            a.autoreverses = YES;
            a.repeatCount = HUGE_VALF;
            [self.dot.layer addAnimation:a forKey:@"blink"];
        }
    } else {
        self.label.text = @"录";
        self.dot.backgroundColor = [UIColor colorWithRed:1.0 green:0.23 blue:0.19 alpha:1.0];
        [self.dot.layer removeAnimationForKey:@"blink"];
    }
}

#pragma mark - 交互

- (void)onTap {
    extern void DHLControlTapped(void);
    DHLControlTapped();
}

- (void)onLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    extern void DHLControlShowList(void);
    DHLControlShowList();
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    UIView *sp = self.superview;
    if (!sp) return;
    CGPoint t = [g translationInView:sp];
    CGPoint c = self.center;
    c.x += t.x;
    c.y += t.y;
    c.x = MAX(self.bounds.size.width / 2.0, MIN(sp.bounds.size.width - self.bounds.size.width / 2.0, c.x));
    c.y = MAX(self.bounds.size.height / 2.0, MIN(sp.bounds.size.height - self.bounds.size.height / 2.0, c.y));
    self.center = c;
    [g setTranslation:CGPointZero inView:sp];
}

@end
