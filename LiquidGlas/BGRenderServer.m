//
// BGRenderServer - Background Render Server for LiquidGlas (Optimized v1.0)
// Handles dynamic rendering and glass effect computations with minimal CPU/GPU overhead
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

@interface BGRenderServer : NSObject
@end

@interface BGRenderServer ()
@property (nonatomic, assign) CGFloat glassOpacity;
@property (nonatomic, assign) CGFloat blurAmount;
@property (nonatomic, assign) float glossLevel;
@end

@implementation BGRenderServer

- (id)init {
    self = [super init];
    if(self) {
        _glassOpacity = 0.85f;
        _blurAmount = 15.0f;
        _glossLevel = 0.5f;
    }
    return self;
}

- (void)setGlassEffect:(CGFloat)opacity blur:(CGFloat)blur gloss:(float)g {
    _glassOpacity = opacity;
    _blurAmount = blur;
    _glossLevel = g;
}

%hook UIViewController

- (void)viewDidLoad {
    %orig;
    
    UIView *view = self.view;
    if(!view || !self.isViewSupportedForEffect) return;
    
    // 跳过系统关键视图，避免影响性能
    const char *name = class_getName([view class]);
    if(name && (strcasestr(name, "SBAwareness") != NULL || 
                strcasestr(name, "Navigation") != NULL ||
                strcasestr(name, "AlertView") != NULL)) {
        return;
    }
    
    view.layer.masksToBounds = NO;
    
    // 优化：使用简单的纯色渐变层，替代复杂的阴影和多层渲染
    CAGradientLayer *glassGradient = [CAGradientLayer layer];
    glassGradient.frame = view.bounds;
    glassGradient.startPoint = CGPointMake(0.0, 0.0);
    glassGradient.endPoint = CGPointMake(1.0, 1.0);
    
    // 性能优化：减少颜色数量，降低 alpha 值减轻渲染负担
    glassGradient.colors = @[
        (__bridge id)[UIColor colorWithRed:0.95 green:0.95 blue:0.98 alpha:0.08].CGColor,
        (__bridge id)[UIColor colorWithRed:0.1 green:0.1 blue:0.2 alpha:0.2].CGColor
    ];
    glassGradient.locations = @[@0.0f, @1.0f];
    glassGradient.opacity = 0.75f;
    
    // 性能优化：移除或减小阴影，GPU 开销较大
    glassGradient.shadowOpacity = 0.05;
    glassGradient.shadowOffset = CGSizeMake(0, 1);
    glassGradient.shadowRadius = 8.0f;
    
    // 性能优化：降低边框粗细，减少绘制像素
    if(view.layer.borderWidth > 0) {
        view.layer.borderWidth = 0.3f;
    }
    
    [view.layer addSublayer:glassGradient];
    
    // 使用更轻量的 corner radius
    view.layer.cornerRadius = 20.0f;
    view.layer.borderColor = [UIColor colorWithWhite:0.18 alpha:0.25].CGColor;
}

// 性能优化：添加视图支持检测，避免对所有视图渲染
- (BOOL)isViewSupportedForEffect {
    UIViewController *controller = self;
    while(controller) {
        const char *name = class_getName([controller class]);
        // 跳过系统关键控制器
        if(name && (strcasestr(name, "Navigation") != NULL || 
                    strcasestr(name, "Alert") != NULL ||
                    strcasestr(name, "Sheet") != NULL)) {
            return NO;
        }
        controller = controller.parentViewController;
    }
    return YES;
}

%end

%ctor {
    NSLog(@"BGRenderServer [Optimized] loaded - Reduced GPU rendering overhead");
}

@end