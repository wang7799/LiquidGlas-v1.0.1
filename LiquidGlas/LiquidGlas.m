//
// LiquidGlas - iOS Control Center Liquid Glass Effect
// A sophisticated glassmorphism tweak for the Control Center
//

#import <UIKit/UIKit.h>
#import <substrate.h>
#import <QuartzCore/QuartzCore.h>

// SpringBoard 是 UIApplication 的子类。这里用 Logos hook 而不是 category 覆盖，
// 否则 applicationDidFinishLaunching: 会整体替换系统实现，导致 SpringBoard 启动异常。
@interface SpringBoard : UIApplication
- (void)controlCenterWillPresent:(NSNotification *)notification;
- (void)controlCenterDidClose:(NSNotification *)notification;
@end

// 私有通知用字符串注册，避免链接期依赖不存在的常量符号
static NSString * const kLGControlCenterWillPresent = @"UIControlCenterWillPresentNotification";

%hook SpringBoard

- (void)applicationDidFinishLaunching:(UIApplication *)application {
    %orig;

    if (@available(iOS 14.0, *)) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(controlCenterWillPresent:)
                                                     name:kLGControlCenterWillPresent
                                                   object:nil];
    }
}

- (void)controlCenterWillPresent:(NSNotification *)notification {
    UIView *view = [notification object];
    if (![view isKindOfClass:[UIView class]]) return;

    view.layer.masksToBounds = NO;
    view.layer.cornerRadius = 25.0f;
    view.layer.borderWidth = 1.0f;

    // CAShapeLayer 作为 mask 必须设置 path，否则视图会被完全遮掉
    CAShapeLayer *glassLayer = [CAShapeLayer layer];
    glassLayer.frame = view.bounds;
    glassLayer.path = [UIBezierPath bezierPathWithRoundedRect:view.bounds cornerRadius:25.0f].CGPath;
    // Performance optimization: Reduced alpha values to minimize GPU rendering load
    glassLayer.fillColor = [UIColor colorWithWhite:0.2 alpha:0.25].CGColor;  // Reduced from 0.3
    glassLayer.strokeColor = [UIColor colorWithWhite:0.3 alpha:0.35].CGColor;  // Reduced from 0.4
    glassLayer.lineWidth = 0.8f;  // Slightly reduced to minimize border drawing

    view.layer.mask = glassLayer;
}

- (void)controlCenterDidClose:(NSNotification *)notification {
}

%end

// Liquid Glass Effect Manager
@interface LiquidGlassEffectManager : NSObject
@property (nonatomic, strong) UIView *targetView;
@property (nonatomic, assign) CGFloat glassOpacity;
@property (nonatomic, assign) CGFloat blurAmount;
@property (nonatomic, assign) CGFloat cornerRadius;
@property (nonatomic, assign) float glossLevel;
@property (nonatomic, strong) UIColor *colorTint;
@end

@implementation LiquidGlassEffectManager

+ (instancetype)sharedManager {
    static LiquidGlassEffectManager *manager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ manager = [[self alloc] init]; });
    return manager;
}

- (id)init {
    self = [super init];
    if(self) {
        // Performance: Reduced default blur and opacity to minimize GPU rendering overhead
        _glassOpacity = 0.80f;      // Reduced from 0.85
        _blurAmount = 12.0f;         // Reduced from 15.0 - lower blur needs less computation
        _glossLevel = 0.4f;          // Reduced from 0.5 - simpler reflections
        _colorTint = [UIColor colorWithRed:0.13 green:0.37 blue:0.91 alpha:1.0];
    }
    return self;
}

- (void)applyToView:(UIView *)view {
    _targetView = view;
    
    // Performance: Reduced corner radius and border width to minimize rendering overhead
    view.layer.cornerRadius = _cornerRadius;
    view.layer.borderWidth = 0.8f;  // Reduced from 1.0 for lighter rendering
    view.layer.borderColor = [UIColor colorWithWhite:0.18 alpha:0.3].CGColor;  // Slightly lighter border
    
    view.layer.masksToBounds = NO;
}

- (void)updateWithValues:(CGFloat)opacity blurAmount:(CGFloat)blur cornerRadius:(CGFloat)radius {
    _glassOpacity = opacity;
    _blurAmount = blur;
    _cornerRadius = radius;
    
    if(_targetView) {
        [self applyToView:_targetView];
    }
}

@end

@interface SBSettingsViewController : UIViewController
@end

%hook SBSettingsViewController

- (void)willMoveToWindow:(UIWindow *)window {
    %orig;

    // 私有 ivar 不一定存在，KVC 取不到时会抛 NSUndefinedKeyException
    @try {
        id manager = [self valueForKey:@"_viewControllerForActivePeer"];
        if (manager && [manager isKindOfClass:[NSObject class]]) {
            [[LiquidGlassEffectManager sharedManager] applyToView:self.view];
        }
    } @catch (NSException *exception) {}
}

%end

// Shader for glass effect - Optimized for minimal GPU overhead
// Reduced Fresnel coefficient and simplified color mixing
__unused static NSString * const glassShaderFragmentSource =
    @"precision highp float;\n"
    @"uniform sampler2D u_samplerBackground;\n"
    @"varying highp vec2 v_texCoord;\n"
    @"uniform float u_glassOpacity;\n"
    @"uniform vec3 u_tintColor;\n"
    @"\n"
    @"void main() {\n"
    @"    vec4 background = texture2D(u_samplerBackground, v_texCoord);\n"
    @"    // Performance: Reduced Fresnel effect coefficient from 0.15 to 0.1\n"
    @"    float fresnelEffect = 0.1 + (u_glassOpacity * 0.8);\n"
    @"    // Simplified color mixing - reduced precision operations\n"
    @"    vec3 glassColor = vec3(u_tintColor) * u_glassOpacity;\n"
    @"    gl_FragColor = vec4(mix(glassColor, background.rgb, fresnelEffect), background.a);\n"
    @"}\n";

%ctor {
    NSLog(@"LiquidGlas Control Center Glass Effect - Loaded");
}
