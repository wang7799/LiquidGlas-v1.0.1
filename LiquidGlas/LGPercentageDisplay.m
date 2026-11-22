//
//  LGPercentageDisplay.m
//  LiquidGlas - Control Center volume / brightness percentage overlay
//
//  在控制中心的音量、亮度滑条上叠加实时百分比（例如 "45%"）。
//
//  设计要点：
//  1. 不引用任何私有类头文件，也不 hook 私有方法 —— 全部用运行时类名匹配 +
//     公开 API 取值，因此 iOS 15~18 都能编译、加载失败也不会让 SpringBoard 崩溃。
//  2. 数值来自 AVAudioSession.outputVolume 与 UIScreen.mainScreen.brightness，
//     控制中心拖动时会实时变化；读不到时回退到滑块自身的 value (KVC)。
//  3. 低频刷新 (0.4s) + 亮度/音量通知即时刷新；控制中心不可见时几乎零开销，
//     符合本项目的省电 / 防发热目标。
//  4. 偏好开关在 com.wang7799.liquidglas：
//       showVolumePercentage      (BOOL, 默认 YES)
//       showBrightnessPercentage  (BOOL, 默认 YES)
//       percentageFontSize        (9~24, 默认 12)
//

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <math.h>

static NSString * const kLGPrefsDomain = @"com.wang7799.liquidglas";
static char kLGPercentLabelKey;
static char kLGPercentKindKey;
static char kLGCachedBoundsKey;
static NSTimeInterval const kLGRefreshInterval = 0.4;

typedef NS_ENUM(NSUInteger, LGSliderKind) {
    LGSliderKindNone = 0,
    LGSliderKindVolume,
    LGSliderKindBrightness,
};

#pragma mark - Preferences

static NSDictionary *LGPrefs(void) {
    return [[NSUserDefaults standardUserDefaults] persistentDomainForName:kLGPrefsDomain];
}

static BOOL LGPrefsBool(NSString *key, BOOL defaultValue) {
    id value = LGPrefs()[key];
    return value ? [value boolValue] : defaultValue;
}

static CGFloat LGPrefsFontSize(void) {
    CGFloat size = [LGPrefs()[@"percentageFontSize"] floatValue];
    return (size >= 9.0 && size <= 24.0) ? size : 12.0;
}

#pragma mark - Slider detection

// 沿继承链收集类名，兼容 CCUIVolumeSliderView / CCUIDisplaySliderView /
// CCUIModuleSliderView 以及 iOS 16+ 改名的各种变体。
static NSString *LGClassChain(Class cls) {
    NSMutableString *chain = [NSMutableString string];
    for (int i = 0; cls && i < 6; i++, cls = class_getSuperclass(cls)) {
        [chain appendFormat:@"%s ", class_getName(cls)];
    }
    return [chain lowercaseString];
}

static BOOL LGHasNumericValue(UIView *view) {
    @try {
        return [[view valueForKey:@"value"] isKindOfClass:[NSNumber class]];
    } @catch (NSException *exception) {
        return NO;
    }
}

static LGSliderKind LGKindForView(UIView *view) {
    if (!view) return LGSliderKindNone;

    NSString *chain = LGClassChain([view class]);

    // 先按类名粗筛，避免对整棵视图树做 KVC 探测（省电）
    BOOL relevant = [chain containsString:@"slider"] ||
                    [chain containsString:@"volume"] ||
                    [chain containsString:@"brightness"] ||
                    [chain containsString:@"display"] ||
                    [chain containsString:@"ccui"] ||
                    [chain containsString:@"module"];
    if (!relevant) return LGSliderKindNone;

    BOOL looksLikeSlider = [chain containsString:@"slider"] || LGHasNumericValue(view);
    if (!looksLikeSlider) return LGSliderKindNone;

    BOOL isVolume = [chain containsString:@"volume"];
    BOOL isBrightness = [chain containsString:@"brightness"] || [chain containsString:@"display"];

    // 新版 CC 可能统一用 CCUIModuleSliderView 之类的通用类名，靠无障碍标签区分
    NSString *a11y = [NSString stringWithFormat:@"%@ %@",
                      view.accessibilityIdentifier ?: @"",
                      view.accessibilityLabel ?: @""].lowercaseString;
    if ([a11y containsString:@"volume"] || [a11y containsString:@"音量"]) isVolume = YES;
    if ([a11y containsString:@"brightness"] || [a11y containsString:@"亮度"]) isBrightness = YES;

    // 类名里没有明确语义时，向上找模块容器（CCUIVolumeModuleViewController 等）
    if (!isVolume && !isBrightness) {
        UIView *parent = view.superview;
        for (int i = 0; parent && i < 5; i++, parent = parent.superview) {
            NSString *p = [LGClassChain([parent class]) lowercaseString];
            if ([p containsString:@"volume"]) { isVolume = YES; break; }
            if ([p containsString:@"brightness"] || [p containsString:@"display"]) { isBrightness = YES; break; }
        }
    }

    if (isVolume) return LGSliderKindVolume;
    if (isBrightness) return LGSliderKindBrightness;
    return LGSliderKindNone;
}

#pragma mark - Value reading

static CGFloat LGSystemValue(LGSliderKind kind, UIView *slider) {
    CGFloat value = -1.0;

    if (kind == LGSliderKindVolume) {
        // 公开 API，0.0 ~ 1.0
        value = [AVAudioSession sharedInstance].outputVolume;
    } else if (kind == LGSliderKindBrightness) {
        // 公开 API，0.0 ~ 1.0
        value = [UIScreen mainScreen].brightness;
    }

    if (value >= 0.0 && value <= 1.0) return value;

    // 回退：滑块自身的 value（KVC 会把 float 属性装箱成 NSNumber）
    @try {
        id raw = [slider valueForKey:@"value"];
        if ([raw isKindOfClass:[NSNumber class]]) {
            CGFloat v = [raw floatValue];
            return MIN(MAX(v, 0.0), 1.0);
        }
    } @catch (NSException *exception) {}
    return -1.0;
}

#pragma mark - Overlay label

static UILabel *LGEnsureLabel(UIView *slider, LGSliderKind kind) {
    UILabel *label = objc_getAssociatedObject(slider, &kLGPercentLabelKey);
    BOOL created = NO;
    if (!label) {
        label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.backgroundColor = [UIColor clearColor];
        label.textColor = [UIColor colorWithWhite:1.0 alpha:0.95];
        label.textAlignment = NSTextAlignmentCenter;
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor = 0.7;
        label.userInteractionEnabled = NO;
        label.layer.shadowColor = [UIColor blackColor].CGColor;
        label.layer.shadowOffset = CGSizeMake(0, 0.5);
        label.layer.shadowOpacity = 0.55;
        label.layer.shadowRadius = 2.0;
        label.tag = 0x4C4750; // 'LGP'，便于在视图调试里识别
        label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
        objc_setAssociatedObject(slider, &kLGPercentLabelKey, label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(slider, &kLGPercentKindKey, @(kind), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        created = YES;
    }
    if (label.superview != slider) {
        [slider addSubview:label];
        created = YES;
    }

    // 只在首次创建、字号变更或滑块尺寸变化时重新布局，避免每帧重绘
    CGFloat fontSize = LGPrefsFontSize();
    CGRect bounds = slider.bounds;
    NSValue *cached = objc_getAssociatedObject(slider, &kLGCachedBoundsKey);
    if (created || label.font.pointSize != fontSize || !CGRectEqualToRect(bounds, [cached CGRectValue])) {
        label.font = [UIFont systemFontOfSize:fontSize weight:UIFontWeightSemibold];

        // 竖条（控制中心音量/亮度）放顶部内嵌；横条放右侧，避免盖住滑块 thumb
        BOOL portrait = bounds.size.height > bounds.size.width * 1.3;
        CGFloat h = MAX(fontSize + 4.0, 16.0);
        label.frame = portrait
            ? CGRectMake(2.0, 6.0, MAX(bounds.size.width - 4.0, 24.0), h)
            : CGRectMake(MAX(bounds.size.width - 48.0, 0.0), (bounds.size.height - h) / 2.0, 44.0, h);

        objc_setAssociatedObject(slider, &kLGCachedBoundsKey,
                                 [NSValue valueWithCGRect:bounds],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [slider bringSubviewToFront:label];
    }
    return label;
}

static void LGUpdateLabel(UIView *slider) {
    if (!slider.window || slider.hidden || slider.alpha < 0.01) return;

    NSNumber *kindBox = objc_getAssociatedObject(slider, &kLGPercentKindKey);
    LGSliderKind kind = (LGSliderKind)[kindBox integerValue];
    if (kind == LGSliderKindNone) return;

    BOOL enabled = (kind == LGSliderKindVolume)
        ? LGPrefsBool(@"showVolumePercentage", YES)
        : LGPrefsBool(@"showBrightnessPercentage", YES);

    UILabel *label = LGEnsureLabel(slider, kind);
    label.hidden = !enabled;
    if (!enabled) return;

    CGFloat value = LGSystemValue(kind, slider);
    if (value < 0.0) {
        label.text = nil;
        return;
    }

    int percent = (int)lroundf(value * 100.0);
    percent = MIN(MAX(percent, 0), 100);
    NSString *text = [NSString stringWithFormat:@"%d%%", percent];
    if (![label.text isEqualToString:text]) label.text = text;   // 避免无谓的重绘
}

#pragma mark - Discovery & refresh

static NSHashTable<UIView *> *LGTrackedSliders(void) {
    static NSHashTable<UIView *> *table;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        table = [NSHashTable weakObjectsHashTable];   // 视图释放后自动移除，不持有 CC 界面
    });
    return table;
}

static void LGScanView(UIView *view, NSUInteger depth) {
    if (depth > 18) return;
    LGSliderKind kind = LGKindForView(view);
    if (kind != LGSliderKindNone && ![LGTrackedSliders() containsObject:view]) {
        [LGTrackedSliders() addObject:view];
        objc_setAssociatedObject(view, &kLGPercentKindKey, @(kind), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    for (UIView *subview in view.subviews) {
        LGScanView(subview, depth + 1);
    }
}

static BOOL LGControlCenterWindowVisible(void) {
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        if (window.hidden || window.alpha < 0.01) continue;
        NSString *windowName = NSStringFromClass([window class]).lowercaseString;
        NSString *rootName = NSStringFromClass([window.rootViewController class]).lowercaseString;
        if ([windowName containsString:@"controlcenter"] || [windowName containsString:@"ccui"] ||
            [rootName containsString:@"controlcenter"] || [rootName containsString:@"ccui"]) {
            return YES;
        }
    }
    return NO;
}

static void LGScanWindows(void) {
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        if (window.hidden || window.alpha < 0.01) continue;
        LGScanView(window, 0);
    }
}

static void LGRefresh(void) {
    for (UIView *slider in [LGTrackedSliders() allObjects]) {
        LGUpdateLabel(slider);
    }
}

#pragma mark - Bootstrap

__attribute__((constructor))
static void LGPercentageDisplayInit(void) {
    // 只在 SpringBoard 里生效；控制中心由 SpringBoard 承载
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (![bundleID isEqualToString:@"com.apple.springboard"]) return;

    // dylib 的 constructor 早于 UIApplication 初始化，推迟到主队列下一个 run loop
    dispatch_async(dispatch_get_main_queue(), ^{
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        NSOperationQueue *main = [NSOperationQueue mainQueue];

        // 亮度变化：UIKit 公开通知
        [center addObserverForName:UIScreenBrightnessDidChangeNotification
                            object:nil
                             queue:main
                        usingBlock:^(NSNotification *note) { LGRefresh(); }];

        // 音量变化：系统通知名是字符串常量，不需要链接私有框架
        [center addObserverForName:@"AVSystemController_SystemVolumeDidChangeNotification"
                            object:nil
                             queue:main
                        usingBlock:^(NSNotification *note) { LGRefresh(); }];

        // 控制中心窗口出现时立即扫描一次
        [center addObserverForName:UIWindowDidBecomeVisibleNotification
                            object:nil
                             queue:main
                        usingBlock:^(NSNotification *note) {
                            LGScanWindows();
                            LGRefresh();
                        }];

        __block NSUInteger tick = 0;
        NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:kLGRefreshInterval
                                                         repeats:YES
                                                           block:^(NSTimer *t) {
            tick++;
            BOOL ccVisible = LGControlCenterWindowVisible();
            // 控制中心可见时 0.8s 扫描一次（捕捉滑条重建），不可见时约 5s 兜底一次；
            // 拖动过程由亮度/音量通知即时刷新，不依赖扫描。
            if ((ccVisible && tick % 2 == 0) || (!ccVisible && tick % 12 == 0)) LGScanWindows();
            LGRefresh();
        }];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];

        // 插件加载较晚时控制中心可能已经展开，先补一次扫描
        LGScanWindows();
        LGRefresh();

        NSLog(@"[LiquidGlas] volume/brightness percentage overlay enabled");
    });
}
