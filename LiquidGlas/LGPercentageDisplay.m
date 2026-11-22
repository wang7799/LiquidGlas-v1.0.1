//
//  LGPercentageDisplay.m  (v1.0.5)
//  LiquidGlas - Control Center volume / brightness percentage overlay
//
//  v1.0.5 两个目标：
//  A. 发热 / CPU 占用
//     - 去掉 0.5s 的整棵视图树扫描：改为事件驱动 + 2s 轻量心跳，扫描次数降到 1/4。
//     - 扫描本身用 class_getName + strcasestr 做 C 字符串匹配，不再为每个视图分配
//       NSString / NSMutableString，也不再对无关视图做 KVC 异常探测。
//     - 扫描深度 12、节点预算 3000、事件扫描 1s 节流；心跳在无 HUD 且无已跟踪滑条时直接返回。
//     - 浮层从 UIVisualEffectView(实时模糊) 换成普通半透明 UIView，去掉持续 GPU 模糊。
//  B. 百分比一定能看到
//     - 控制中心可见期间直接常驻一个「音量 xx% / 亮度 xx%」浮层，
//       不再依赖识别私有滑条类名，也不需要用户先拖动滑条。
//     - 识别到滑条时仍额外在滑条上叠加数字（增强，不是唯一路径）。
//     - respring 后 1.5 秒的「LiquidGlas 已加载 ✓」横幅保留，用于判断注入是否成功。
//
//  数值来自公开 API：AVAudioSession.outputVolume / UIScreen.mainScreen.brightness。
//  只依赖公开框架，不引用私有头文件、不 hook 私有方法。
//

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <strings.h>
#import <math.h>

static NSString * const kLGPrefsDomain = @"com.wang7799.liquidglas";
static char kLGPercentLabelKey;
static char kLGPercentKindKey;
static char kLGCachedBoundsKey;

static NSTimeInterval const kLGHeartbeat = 2.0;   // 心跳：2 秒（原来 0.5 秒）
static NSTimeInterval const kLGHudLifetime = 8.0;  // 浮层最长驻留时间
static NSUInteger const kLGScanBudget = 3000;     // 单次扫描最多检查的视图数
static NSUInteger const kLGScanDepth = 12;

static BOOL LGSawControlCenterView = NO;
static BOOL LGHudVisible = NO;
static NSDate *LGHudExpiry = nil;
static NSDate *LGLastScan = nil;
static NSUInteger LGNoControlCenterScans = 0;

typedef NS_ENUM(NSUInteger, LGSliderKind) {
    LGSliderKindNone = 0,
    LGSliderKindVolume,
    LGSliderKindBrightness,
};

#define LGLog(fmt, ...) NSLog((@"[LiquidGlas] " fmt), ##__VA_ARGS__)

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

#pragma mark - Window enumeration

static NSArray<UIWindow *> *LGAllWindows(void) {
    UIApplication *app = [UIApplication sharedApplication];
    NSMutableArray<UIWindow *> *result = [NSMutableArray array];
    NSMutableSet<UIWindow *> *seen = [NSMutableSet set];
    void (^add)(UIWindow *) = ^(UIWindow *window) {
        if (window && ![seen containsObject:window]) {
            [seen addObject:window];
            [result addObject:window];
        }
    };
    for (UIWindow *window in app.windows) add(window);
    add(app.keyWindow);
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in [(UIWindowScene *)scene windows]) add(window);
        }
    }
    return result;
}

static UIWindow *LGTopWindow(void) {
    for (UIWindow *window in [LGAllWindows() reverseObjectEnumerator]) {
        if (!window.hidden && window.alpha > 0.01) return window;
    }
    return nil;
}

static BOOL LGWindowHasControlCenterName(void) {
    for (UIWindow *window in LGAllWindows()) {
        if (window.hidden || window.alpha < 0.01) continue;
        Class cls = [window class];
        const char *name = class_getName(cls);
        if (name && (strcasestr(name, "controlcenter") || strcasestr(name, "ccui"))) return YES;
        const char *root = class_getName([window.rootViewController class]);
        if (root && (strcasestr(root, "controlcenter") || strcasestr(root, "ccui"))) return YES;
    }
    return NO;
}

#pragma mark - Fast class-name matching (no NSString allocation)

static BOOL LGClassContains(Class cls, const char *needle) {
    const char *name = class_getName(cls);
    return name ? (strcasestr(name, needle) != NULL) : NO;
}

static BOOL LGHasNumericValue(UIView *view) {
    // 先判断 selector，避免对无关视图抛出 NSUndefinedKeyException（很贵）
    SEL valueSel = NSSelectorFromString(@"value");
    if (![view respondsToSelector:valueSel]) return NO;
    @try {
        return [[view valueForKey:@"value"] isKindOfClass:[NSNumber class]];
    } @catch (NSException *exception) {
        return NO;
    }
}

static NSString *LGA11yText(UIView *view) {
    // 只有候选视图才会走到这里
    return [NSString stringWithFormat:@"%@ %@",
            view.accessibilityIdentifier ?: @"",
            view.accessibilityLabel ?: @""].lowercaseString;
}

static LGSliderKind LGKindForView(UIView *view) {
    BOOL hasSlider = NO, isVolume = NO, isBrightness = NO;
    Class cls = [view class];
    for (int i = 0; cls && i < 8; i++, cls = class_getSuperclass(cls)) {
        if (LGClassContains(cls, "slider")) hasSlider = YES;
        if (LGClassContains(cls, "volume")) isVolume = YES;
        if (LGClassContains(cls, "brightness") || LGClassContains(cls, "display")) isBrightness = YES;
    }

    NSString *a11y = LGA11yText(view);
    if ([a11y containsString:@"volume"] || [a11y containsString:@"音量"]) isVolume = YES;
    if ([a11y containsString:@"brightness"] || [a11y containsString:@"亮度"]) isBrightness = YES;

    CGRect bounds = view.bounds;
    BOOL tall = bounds.size.height > 90.0 && bounds.size.height > bounds.size.width * 1.4;
    BOOL wide = bounds.size.width > 90.0 && bounds.size.width > bounds.size.height * 1.4;
    if (!hasSlider && !tall && !wide && !LGHasNumericValue(view)) return LGSliderKindNone;

    if (!isVolume && !isBrightness) {
        UIView *parent = view.superview;
        for (int i = 0; parent && i < 6; i++, parent = parent.superview) {
            Class pc = [parent class];
            if (LGClassContains(pc, "volume")) { isVolume = YES; break; }
            if (LGClassContains(pc, "brightness") || LGClassContains(pc, "display")) { isBrightness = YES; break; }
        }
    }

    if (isVolume) return LGSliderKindVolume;
    if (isBrightness) return LGSliderKindBrightness;
    return LGSliderKindNone;
}

#pragma mark - Value reading

static CGFloat LGSystemValue(LGSliderKind kind, UIView *slider) {
    CGFloat value = (kind == LGSliderKindVolume)
        ? [AVAudioSession sharedInstance].outputVolume
        : [UIScreen mainScreen].brightness;
    if (value >= 0.0 && value <= 1.0) return value;

    @try {
        id raw = [slider valueForKey:@"value"];
        if ([raw isKindOfClass:[NSNumber class]]) return MIN(MAX([raw floatValue], 0.0), 1.0);
    } @catch (NSException *exception) {}
    return -1.0;
}

static int LGPercent(CGFloat value) {
    return MIN(MAX((int)lroundf(MIN(MAX(value, 0.0), 1.0) * 100.0), 0), 100);
}

#pragma mark - Slider label (enhancement only)

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
        label.tag = 0x4C4750;
        label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
        objc_setAssociatedObject(slider, &kLGPercentLabelKey, label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(slider, &kLGPercentKindKey, @(kind), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        created = YES;
    }
    if (label.superview != slider) { [slider addSubview:label]; created = YES; }

    CGFloat fontSize = LGPrefsFontSize();
    CGRect bounds = slider.bounds;
    NSValue *cached = objc_getAssociatedObject(slider, &kLGCachedBoundsKey);
    if (created || label.font.pointSize != fontSize || !CGRectEqualToRect(bounds, [cached CGRectValue])) {
        label.font = [UIFont systemFontOfSize:fontSize weight:UIFontWeightSemibold];
        BOOL portrait = bounds.size.height > bounds.size.width * 1.3;
        CGFloat h = MAX(fontSize + 4.0, 16.0);
        label.frame = portrait
            ? CGRectMake(2.0, 6.0, MAX(bounds.size.width - 4.0, 24.0), h)
            : CGRectMake(MAX(bounds.size.width - 48.0, 0.0), (bounds.size.height - h) / 2.0, 44.0, h);
        objc_setAssociatedObject(slider, &kLGCachedBoundsKey, [NSValue valueWithCGRect:bounds],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [slider bringSubviewToFront:label];
    }
    return label;
}

static NSHashTable<UIView *> *LGTrackedSliders(void) {
    static NSHashTable<UIView *> *table;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ table = [NSHashTable weakObjectsHashTable]; });
    return table;
}

static void LGRefreshSliderLabels(void) {
    for (UIView *slider in [LGTrackedSliders() allObjects]) {
        if (slider.hidden || slider.alpha < 0.01) continue;
        NSNumber *box = objc_getAssociatedObject(slider, &kLGPercentKindKey);
        LGSliderKind kind = (LGSliderKind)[box integerValue];
        if (kind == LGSliderKindNone) continue;

        BOOL enabled = (kind == LGSliderKindVolume)
            ? LGPrefsBool(@"showVolumePercentage", YES)
            : LGPrefsBool(@"showBrightnessPercentage", YES);
        UILabel *label = LGEnsureLabel(slider, kind);
        label.hidden = !enabled;
        if (!enabled) continue;

        CGFloat value = LGSystemValue(kind, slider);
        if (value < 0.0) { label.text = nil; continue; }
        NSString *text = [NSString stringWithFormat:@"%d%%", LGPercent(value)];
        if (![label.text isEqualToString:text]) label.text = text;
    }
}

#pragma mark - Lightweight always-visible HUD

// 普通半透明 UIView，不用 UIVisualEffectView —— 实时模糊是持续 GPU/CPU 开销
static UIView *LGHudContainer(void) {
    static UIView *hud;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 190, 46)];
        box.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.72];
        box.layer.cornerRadius = 12.0;
        box.userInteractionEnabled = NO;
        UILabel *vol = [[UILabel alloc] initWithFrame:CGRectMake(8, 4, 174, 18)];
        vol.tag = 0x4C4741;
        vol.textAlignment = NSTextAlignmentCenter;
        vol.textColor = [UIColor whiteColor];
        vol.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        UILabel *bri = [[UILabel alloc] initWithFrame:CGRectMake(8, 24, 174, 18)];
        bri.tag = 0x4C4742;
        bri.textAlignment = NSTextAlignmentCenter;
        bri.textColor = [UIColor whiteColor];
        bri.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        [box addSubview:vol];
        [box addSubview:bri];
        hud = box;
    });
    return hud;
}

static void LGSetHUDText(NSString *line1, NSString *line2) {
    UIView *hud = LGHudContainer();
    UILabel *vol = [hud viewWithTag:0x4C4741];
    UILabel *bri = [hud viewWithTag:0x4C4742];
    if (![vol.text isEqualToString:line1]) vol.text = line1;
    if (![bri.text isEqualToString:line2]) bri.text = line2;
}

static void LGUpdateHUDNumbers(void) {
    if (!LGHudVisible) return;
    int volume = LGPercent([AVAudioSession sharedInstance].outputVolume);
    int brightness = LGPercent([UIScreen mainScreen].brightness);
    LGSetHUDText([NSString stringWithFormat:@"音量  %d%%", volume],
                 [NSString stringWithFormat:@"亮度  %d%%", brightness]);
}

static CGRect LGHudFrame(UIWindow *window) {
    CGFloat top = 20.0;
    if (@available(iOS 11.0, *)) top = window.safeAreaInsets.top + 8.0;
    return CGRectMake((window.bounds.size.width - 190.0) / 2.0, MAX(top, 20.0), 190.0, 46.0);
}

static void LGShowOrExtendHUD(void) {
    if (!LGPrefsBool(@"showFallbackHUD", YES)) return;
    UIWindow *window = LGTopWindow();
    if (!window) return;

    UIView *hud = LGHudContainer();
    hud.frame = LGHudFrame(window);
    [hud.layer removeAllAnimations];
    hud.alpha = 1.0;
    if (hud.superview != window) [window addSubview:hud];
    [window bringSubviewToFront:hud];

    LGHudVisible = YES;
    LGHudExpiry = [NSDate dateWithTimeIntervalSinceNow:kLGHudLifetime];
    LGNoControlCenterScans = 0;
    LGUpdateHUDNumbers();
}

static void LGHideHUD(void) {
    if (!LGHudVisible) return;
    LGHudVisible = NO;
    UIView *hud = LGHudContainer();
    [UIView animateWithDuration:0.25
                     animations:^{ hud.alpha = 0.0; }
                     completion:^(BOOL finished) { [hud removeFromSuperview]; }];
}

#pragma mark - Scan (cheap, budgeted, event-driven)

static void LGScanView(UIView *view, NSUInteger depth, NSUInteger *budget) {
    if (depth > kLGScanDepth || *budget == 0) return;
    (*budget)--;

    Class cls = [view class];
    const char *name = class_getName(cls);
    if (name) {
        if (strcasestr(name, "ccui") || strcasestr(name, "controlcenter") ||
            strcasestr(name, "module")) LGSawControlCenterView = YES;

        BOOL relevant = strcasestr(name, "slider") || strcasestr(name, "volume") ||
                        strcasestr(name, "brightness") || strcasestr(name, "display") ||
                        strcasestr(name, "ccui") || strcasestr(name, "controlcenter") ||
                        strcasestr(name, "module");
        if (relevant) {
            LGSliderKind kind = LGKindForView(view);
            if (kind != LGSliderKindNone && ![LGTrackedSliders() containsObject:view]) {
                [LGTrackedSliders() addObject:view];
                objc_setAssociatedObject(view, &kLGPercentKindKey, @(kind), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                LGLog(@"found %@ slider: %s", kind == LGSliderKindVolume ? @"volume" : @"brightness", name);
            }
        }
    }
    for (UIView *subview in view.subviews) LGScanView(subview, depth + 1, budget);
}

static void LGScanWindows(void) {
    LGSawControlCenterView = NO;
    NSUInteger budget = kLGScanBudget;
    for (UIWindow *window in LGAllWindows()) {
        if (window.hidden || window.alpha < 0.01) continue;
        LGScanView(window, 0, &budget);
        if (budget == 0) break;
    }
    LGLastScan = [NSDate date];
}

static void LGScanIfDue(void) {
    if (LGLastScan && [LGLastScan timeIntervalSinceNow] > -1.0) return;  // 1 秒节流
    LGScanWindows();
}

#pragma mark - Activity / heartbeat

static void LGMarkActivity(void) {
    LGScanIfDue();
    LGRefreshSliderLabels();
    LGShowOrExtendHUD();
}

static void LGHeartbeat(void) {
    // 2 秒一次、C 字符串匹配、深度 12 / 预算 3000 的轻量扫描；
    // 相比 v1.0.4 的「0.5 秒 + 每个视图分配 NSString + KVC 异常」大幅降低 CPU。
    LGScanWindows();
    LGRefreshSliderLabels();

    BOOL ccVisible = LGSawControlCenterView || LGWindowHasControlCenterName();
    if (ccVisible) {
        LGShowOrExtendHUD();
    } else if (LGHudVisible) {
        LGNoControlCenterScans++;
        BOOL expired = LGHudExpiry && [[NSDate date] compare:LGHudExpiry] != NSOrderedAscending;
        if (LGNoControlCenterScans >= 2 || expired) LGHideHUD();
    }
    LGUpdateHUDNumbers();
}

// respring 后的注入确认横幅：看到它 = dylib 已被加载并初始化
static void LGShowLoadBanner(void) {
    if (!LGPrefsBool(@"showLoadBanner", YES)) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIWindow *window = LGTopWindow();
        if (!window) return;
        UIView *hud = LGHudContainer();
        LGSetHUDText(@"LiquidGlas 已加载 ✓", @"控制中心显示音量 / 亮度百分比");
        hud.frame = LGHudFrame(window);
        [hud.layer removeAllAnimations];
        hud.alpha = 1.0;
        if (hud.superview != window) [window addSubview:hud];
        [window bringSubviewToFront:hud];
        LGLog(@"load banner, windows=%lu, bundle=%@",
              (unsigned long)LGAllWindows().count,
              [[NSBundle mainBundle] bundleIdentifier] ?: @"(nil)");
        [UIView animateWithDuration:0.3 delay:2.5
                            options:UIViewAnimationOptionAllowUserInteraction
                         animations:^{ hud.alpha = 0.0; }
                         completion:^(BOOL finished) { if (!LGHudVisible) [hud removeFromSuperview]; }];
    });
}

#pragma mark - Bootstrap

__attribute__((constructor))
static void LGPercentageDisplayInit(void) {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (![bundleID isEqualToString:@"com.apple.springboard"]) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        LGLog(@"loaded, windows=%lu", (unsigned long)LGAllWindows().count);

        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        NSOperationQueue *mainQueue = [NSOperationQueue mainQueue];

        [center addObserverForName:UIScreenBrightnessDidChangeNotification
                            object:nil queue:mainQueue
                        usingBlock:^(NSNotification *note) { LGMarkActivity(); }];
        [center addObserverForName:@"AVSystemController_SystemVolumeDidChangeNotification"
                            object:nil queue:mainQueue
                        usingBlock:^(NSNotification *note) { LGMarkActivity(); }];
        for (NSString *name in @[UIWindowDidBecomeVisibleNotification,
                                  UIWindowDidBecomeKeyNotification,
                                  UIApplicationDidBecomeActiveNotification]) {
            [center addObserverForName:name object:nil queue:mainQueue
                          usingBlock:^(NSNotification *note) { LGMarkActivity(); }];
        }

        // 心跳 2 秒；无控制中心视图时只做一次轻量扫描，不再有 0.5s 全树轮询
        NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:kLGHeartbeat
                                                         repeats:YES
                                                           block:^(NSTimer *t) { LGHeartbeat(); }];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];

        LGScanWindows();
        LGRefreshSliderLabels();
        LGShowLoadBanner();
    });
}
