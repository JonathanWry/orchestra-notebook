#import <Cocoa/Cocoa.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 2;
        NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(1024, 1024)];
        [image lockFocus];

        NSBezierPath *outer = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(54, 54, 916, 916) xRadius:218 yRadius:218];
        NSGradient *gradient = [[NSGradient alloc] initWithColors:@[
            [NSColor colorWithCalibratedRed:0.08 green:0.16 blue:0.18 alpha:1],
            [NSColor colorWithCalibratedRed:0.12 green:0.34 blue:0.34 alpha:1]
        ]];
        [gradient drawInBezierPath:outer angle:-45];

        NSShadow *shadow = [NSShadow new];
        shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.28];
        shadow.shadowBlurRadius = 34;
        shadow.shadowOffset = NSMakeSize(0, -14);
        [NSGraphicsContext saveGraphicsState];
        [shadow set];
        NSBezierPath *paper = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(178, 204, 668, 616) xRadius:44 yRadius:44];
        [[NSColor colorWithCalibratedRed:0.98 green:0.96 blue:0.89 alpha:1] setFill];
        [paper fill];
        [NSGraphicsContext restoreGraphicsState];

        NSColor *ink = [NSColor colorWithCalibratedRed:0.11 green:0.19 blue:0.18 alpha:1];
        [ink setStroke];
        for (NSInteger staff = 0; staff < 5; staff++) {
            NSBezierPath *line = [NSBezierPath bezierPath];
            [line moveToPoint:NSMakePoint(254, 638 - staff * 38)];
            [line lineToPoint:NSMakePoint(770, 638 - staff * 38)];
            line.lineWidth = 9;
            [line stroke];
        }

        NSArray<NSNumber *> *xs = @[@330, @465, @610, @705];
        NSArray<NSNumber *> *ys = @[@585, @510, @622, @548];
        NSColor *accent = [NSColor colorWithCalibratedRed:0.91 green:0.38 blue:0.20 alpha:1];
        [accent setFill];
        for (NSInteger i = 0; i < xs.count; i++) {
            CGFloat x = xs[i].doubleValue, y = ys[i].doubleValue;
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x - 24, y - 18, 48, 36)] fill];
            NSBezierPath *stem = [NSBezierPath bezierPathWithRect:NSMakeRect(x + 18, y, 9, 108)];
            [stem fill];
        }

        NSDictionary *labelAttributes = @{
            NSFontAttributeName: [NSFont systemFontOfSize:74 weight:NSFontWeightHeavy],
            NSForegroundColorAttributeName: ink
        };
        NSString *label = @"NOTE";
        NSSize size = [label sizeWithAttributes:labelAttributes];
        [label drawAtPoint:NSMakePoint(512 - size.width / 2, 288) withAttributes:labelAttributes];

        [image unlockFocus];
        NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithData:image.TIFFRepresentation];
        NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        return [png writeToFile:[NSString stringWithUTF8String:argv[1]] atomically:YES] ? 0 : 1;
    }
}
