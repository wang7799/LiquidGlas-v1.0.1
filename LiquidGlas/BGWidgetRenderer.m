//
// BGWidgetRenderer - Widget Rendering for LiquidGlass Control Center
// Handles widget background effects and liquid rendering
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

@interface BGWidgetRenderer : UIView

@end

@implementation BGWidgetRenderer

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if(self) {
        self.layer.cornerRadius = 12.0f;
        self.layer.borderWidth = 0.5f;
        self.layer.borderColor = [UIColor colorWithWhite:0.2 alpha:0.4].CGColor;
        
        // Add subtle glow effect
        self.layer.shadowColor = [UIColor colorWithRed:0.1 green:0.3 blue:0.6 alpha:0.3].CGColor;
        self.layer.shadowOffset = CGSizeMake(0, 0);
        self.layer.shadowOpacity = 0.2;
        self.layer.shadowRadius = 5.0f;

        // 半透明玻璃渐变，只创建一次
        CAGradientLayer *widgetGradient = [CAGradientLayer layer];
        widgetGradient.frame = self.bounds;
        widgetGradient.cornerRadius = 12.0f;
        widgetGradient.colors = @[
            (__bridge id)[UIColor colorWithWhite:0.1 alpha:0.2].CGColor,
            (__bridge id)[UIColor clearColor].CGColor
        ];
        widgetGradient.locations = @[@0.0f, @1.0f];
        [self.layer insertSublayer:widgetGradient atIndex:0];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // 渐变层只在初始化时创建一次，这里跟随尺寸变化，避免 drawRect 反复叠加图层
    for (CALayer *layer in self.layer.sublayers) {
        if ([layer isKindOfClass:[CAGradientLayer class]]) {
            layer.frame = self.bounds;
        }
    }
}

@end
