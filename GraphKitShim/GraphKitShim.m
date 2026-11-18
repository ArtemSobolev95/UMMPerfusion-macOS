//
//  GraphKitShim.m — implementation of the GraphKit subset used by UMMPerfusion.
//  Compiled with manual reference counting (-fno-objc-arc), like the plugin.
//
//  Behaviour kept from GraphKit where UMMPerfusion depends on it:
//   - values come from the chart's dataSource:
//       -chart:numberOfElementsForDataSet:
//       -chart:yValueForDataSet:element:
//       -chart:xValueForDataSet:element:   (optional; element index otherwise)
//   - y-axis labels may come from the chart's delegate:
//       -chart:yLabelForAxes:value:defaultLabel:
//   - the X range follows GRAxesFixedXPlotMin/Max (or GRAxesXPlotMin/Max), the
//     Y range is fitted to the visible data; -[GRAxes plotRect],
//     -locationForXValue:yValue: and -xValueAtPoint: map between data and view.
//

#import "GRChartView.h"
#import "GRAxes.h"
#import "GRDataSet.h"
#import "GRXYDataSet.h"
#import "GRLineDataSet.h"
#import "GRPieDataSet.h"
#import "GRColumnDataSet.h"
#import "GRAreaDataSet.h"
#include <math.h>

@interface GRAxes (GRShimPrivate)
- (NSColor *)_plotBackgroundColor;
@end

#pragma mark - Keys

NSString *GRChartDrawBackground   = @"GRChartDrawBackground";
NSString *GRChartBackgroundColor  = @"GRChartBackgroundColor";
NSString *GRChartMainTitle        = @"GRChartMainTitle";
NSString *GRChartMainTitleFont    = @"GRChartMainTitleFont";

NSString *GRAxesXTitle                = @"GRAxesXTitle";
NSString *GRAxesYTitle                = @"GRAxesYTitle";
NSString *GRAxesLabelFont             = @"GRAxesLabelFont";
NSString *GRAxesMinorLineDashPattern  = @"GRAxesMinorLineDashPattern";
NSString *GRAxesDrawXLabels           = @"GRAxesDrawXLabels";
NSString *GRAxesDrawYLabels           = @"GRAxesDrawYLabels";
NSString *GRAxesDrawXMajorTicks       = @"GRAxesDrawXMajorTicks";
NSString *GRAxesDrawXMinorTicks       = @"GRAxesDrawXMinorTicks";
NSString *GRAxesDrawYMajorTicks       = @"GRAxesDrawYMajorTicks";
NSString *GRAxesDrawYMinorTicks       = @"GRAxesDrawYMinorTicks";
NSString *GRAxesDrawXMajorLines       = @"GRAxesDrawXMajorLines";
NSString *GRAxesDrawYMajorLines       = @"GRAxesDrawYMajorLines";
NSString *GRAxesXPlotMin              = @"GRAxesXPlotMin";
NSString *GRAxesXPlotMax              = @"GRAxesXPlotMax";
NSString *GRAxesYPlotMin              = @"GRAxesYPlotMin";
NSString *GRAxesYPlotMax              = @"GRAxesYPlotMax";
NSString *GRAxesFixedXPlotMin         = @"GRAxesFixedXPlotMin";
NSString *GRAxesFixedXPlotMax         = @"GRAxesFixedXPlotMax";
NSString *GRAxesFixedYPlotMin         = @"GRAxesFixedYPlotMin";
NSString *GRAxesFixedYPlotMax         = @"GRAxesFixedYPlotMax";

NSString *GRDataSetHidden         = @"GRDataSetHidden";
NSString *GRDataSetDrawMarkers    = @"GRDataSetDrawMarkers";
NSString *GRDataSetDrawPlotLine   = @"GRDataSetDrawPlotLine";
NSString *GRDataSetPlotColor      = @"GRDataSetPlotColor";
NSString *GRDataSetPlotLineWidth  = @"GRDataSetPlotLineWidth";
NSString *GRDataSetLegendLabel    = @"GRDataSetLegendLabel";
NSString *GRDataSetPieStartAngle  = @"GRDataSetPieStartAngle";

#pragma mark - Data source / delegate signatures

@protocol GRShimDataSource
@optional
- (NSInteger)chart:(GRChartView *)chart numberOfElementsForDataSet:(GRDataSet *)dataSet;
- (double)chart:(GRChartView *)chart yValueForDataSet:(GRDataSet *)dataSet element:(NSInteger)element;
- (double)chart:(GRChartView *)chart xValueForDataSet:(GRDataSet *)dataSet element:(NSInteger)element;
- (NSString *)chart:(GRChartView *)chart yLabelForAxes:(GRAxes *)axes value:(double)value defaultLabel:(NSString *)defaultLabel;
- (NSString *)chart:(GRChartView *)chart xLabelForAxes:(GRAxes *)axes value:(double)value defaultLabel:(NSString *)defaultLabel;
@end

static BOOL GRBool(id value, BOOL fallback)
{
    return value ? [value boolValue] : fallback;
}

// A "nice" step (1, 2, 2.5, 5 × 10^n) close to raw.
static double GRNiceStep(double raw)
{
    if (!(raw > 0) || !isfinite(raw)) return 1.0;
    double exponent = floor(log10(raw));
    double base = pow(10.0, exponent);
    double fraction = raw / base;
    double nice;
    if (fraction <= 1.0)      nice = 1.0;
    else if (fraction <= 2.0) nice = 2.0;
    else if (fraction <= 2.5) nice = 2.5;
    else if (fraction <= 5.0) nice = 5.0;
    else                      nice = 10.0;
    return nice * base;
}

static NSString *GRDefaultLabel(double value, double step)
{
    if (fabs(value) < step * 1e-6) value = 0.0;
    int decimals = 0;
    if (step < 1.0) decimals = (int)ceil(-log10(step) - 1e-9);
    if (decimals > 6) decimals = 6;
    if (fabs(value) >= 1e6 || (fabs(value) > 0 && fabs(value) < 1e-4))
        return [NSString stringWithFormat:@"%.3g", value];
    return [NSString stringWithFormat:@"%.*f", decimals, value];
}

#pragma mark - GRDataSet

@implementation GRDataSet

- (id)initWithOwnerChart:(GRChartView *)chart
{
    self = [super init];
    if (self) {
        _chart = chart;
        _properties = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (id)init
{
    return [self initWithOwnerChart:nil];
}

- (void)dealloc
{
    free(_x); _x = NULL;
    free(_y); _y = NULL;
    [_properties release];
    [_autoColor release];
    [super dealloc];
}

- (GRChartView *)chart { return _chart; }
- (void)_setOwnerChart:(GRChartView *)chart { _chart = chart; }

- (id)propertyForKey:(NSString *)key
{
    if (!key) return nil;
    id value = [_properties objectForKey:key];
    if (!value && [key isEqualToString:GRDataSetPlotColor]) return _autoColor;
    return value;
}

- (void)setProperty:(id)value forKey:(NSString *)key
{
    if (!key) return;
    if (value) [_properties setObject:value forKey:key];
    else       [_properties removeObjectForKey:key];
    [_chart setNeedsDisplay:YES];
}

- (id)valueForUndefinedKey:(NSString *)key { return [self propertyForKey:key]; }
- (void)setValue:(id)value forUndefinedKey:(NSString *)key { [self setProperty:value forKey:key]; }

- (NSUInteger)numberOfElements { return _count; }

- (void)_setAutoColor:(NSColor *)color
{
    [_autoColor release];
    _autoColor = [color retain];
}

- (void)reloadData
{
    free(_x); _x = NULL;
    free(_y); _y = NULL;
    _count = 0;

    id<GRShimDataSource> source = [_chart dataSource];
    if (!source || ![source respondsToSelector:@selector(chart:numberOfElementsForDataSet:)])
        return;

    NSInteger n = [source chart:_chart numberOfElementsForDataSet:self];
    if (n <= 0) return;

    _x = (double *)malloc(sizeof(double) * (size_t)n);
    _y = (double *)malloc(sizeof(double) * (size_t)n);
    if (!_x || !_y) { free(_x); free(_y); _x = _y = NULL; return; }

    BOOL hasX = [source respondsToSelector:@selector(chart:xValueForDataSet:element:)];
    BOOL hasY = [source respondsToSelector:@selector(chart:yValueForDataSet:element:)];
    for (NSInteger i = 0; i < n; i++) {
        _x[i] = hasX ? [source chart:_chart xValueForDataSet:self element:i] : (double)i;
        _y[i] = hasY ? [source chart:_chart yValueForDataSet:self element:i] : 0.0;
    }
    _count = (NSUInteger)n;
}

- (BOOL)_isHidden
{
    return GRBool([_properties objectForKey:GRDataSetHidden], NO);
}

- (BOOL)_getXRangeMin:(double *)min max:(double *)max
{
    BOOL found = NO;
    for (NSUInteger i = 0; i < _count; i++) {
        double v = _x[i];
        if (!isfinite(v)) continue;
        if (!found) { *min = *max = v; found = YES; }
        else { if (v < *min) *min = v; if (v > *max) *max = v; }
    }
    return found;
}

- (BOOL)_getYRangeMin:(double *)min max:(double *)max inXFrom:(double)x0 to:(double)x1
{
    BOOL found = NO;
    for (NSUInteger i = 0; i < _count; i++) {
        if (!isfinite(_x[i]) || !isfinite(_y[i])) continue;
        if (_x[i] < x0 || _x[i] > x1) continue;
        double v = _y[i];
        if (!found) { *min = *max = v; found = YES; }
        else { if (v < *min) *min = v; if (v > *max) *max = v; }
    }
    return found;
}

- (void)_drawWithAxes:(GRAxes *)axes
{
    if (_count == 0 || [self _isHidden]) return;

    NSColor *color = [self propertyForKey:GRDataSetPlotColor];
    if (!color) color = [NSColor blueColor];
    BOOL drawLine = GRBool([_properties objectForKey:GRDataSetDrawPlotLine], YES);
    BOOL drawMarkers = GRBool([_properties objectForKey:GRDataSetDrawMarkers], YES);
    id widthValue = [_properties objectForKey:GRDataSetPlotLineWidth];
    CGFloat width = widthValue ? [widthValue doubleValue] : 1.5;

    if (drawLine) {
        NSBezierPath *path = [NSBezierPath bezierPath];
        BOOL penDown = NO;
        for (NSUInteger i = 0; i < _count; i++) {
            if (!isfinite(_x[i]) || !isfinite(_y[i])) { penDown = NO; continue; }
            NSPoint p = [axes locationForXValue:_x[i] yValue:_y[i]];
            if (!penDown) { [path moveToPoint:p]; penDown = YES; }
            else          [path lineToPoint:p];
        }
        [path setLineWidth:width];
        [path setLineJoinStyle:NSLineJoinStyleRound];
        [color setStroke];
        [path stroke];
    }

    if (drawMarkers) {
        [color setFill];
        for (NSUInteger i = 0; i < _count; i++) {
            if (!isfinite(_x[i]) || !isfinite(_y[i])) continue;
            NSPoint p = [axes locationForXValue:_x[i] yValue:_y[i]];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(p.x - 2.5, p.y - 2.5, 5, 5)] fill];
        }
    }
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@ %p: %lu elements>", [self class], self, (unsigned long)_count];
}

@end

@implementation GRXYDataSet
@end

@implementation GRLineDataSet
@end

@implementation GRPieDataSet
@end

@implementation GRColumnDataSet
@end

@implementation GRAreaDataSet
@end

#pragma mark - GRAxes

@implementation GRAxes

- (id)initWithOwner:(GRChartView *)chart
{
    self = [super init];
    if (self) {
        _chart = chart;
        _properties = [[NSMutableDictionary alloc] init];
        _xMin = 0; _xMax = 1; _yMin = 0; _yMax = 1;
    }
    return self;
}

- (void)dealloc
{
    [_properties release];
    [super dealloc];
}

- (id)chart { return _chart; }
- (id)owner { return _chart; }

- (id)propertyForKey:(NSString *)key
{
    if (!key) return nil;
    id value = [_properties objectForKey:key];
    if (value) return value;
    // GraphKit answers the current range for these when they were not set.
    if ([key isEqualToString:GRAxesXPlotMin]) return [NSNumber numberWithDouble:_xMin];
    if ([key isEqualToString:GRAxesXPlotMax]) return [NSNumber numberWithDouble:_xMax];
    if ([key isEqualToString:GRAxesYPlotMin]) return [NSNumber numberWithDouble:_yMin];
    if ([key isEqualToString:GRAxesYPlotMax]) return [NSNumber numberWithDouble:_yMax];
    return nil;
}

- (void)setProperty:(id)value forKey:(NSString *)key
{
    if (!key) return;
    if (value) [_properties setObject:value forKey:key];
    else       [_properties removeObjectForKey:key];
    [_chart setNeedsDisplay:YES];
}

- (id)valueForUndefinedKey:(NSString *)key { return [self propertyForKey:key]; }
- (void)setValue:(id)value forUndefinedKey:(NSString *)key { [self setProperty:value forKey:key]; }

- (NSRect)plotRect { return _plotRect; }

// Charts that paint their own background (reports) keep dark-on-white colours;
// charts drawn over the window (GRChartDrawBackground = NO) follow light/dark mode.
- (BOOL)_usesSystemColors
{
    return !GRBool([_chart propertyForKey:GRChartDrawBackground], YES);
}

- (NSColor *)_textColor
{
    return [self _usesSystemColors] ? [NSColor labelColor] : [NSColor colorWithCalibratedWhite:0.15 alpha:1.0];
}

- (NSColor *)_gridColor
{
    return [self _usesSystemColors] ? [NSColor separatorColor] : [NSColor colorWithCalibratedWhite:0.88 alpha:1.0];
}

- (NSColor *)_frameColor
{
    return [self _usesSystemColors] ? [NSColor secondaryLabelColor] : [NSColor colorWithCalibratedWhite:0.35 alpha:1.0];
}

- (NSColor *)_plotBackgroundColor
{
    return [self _usesSystemColors] ? [NSColor textBackgroundColor] : [NSColor whiteColor];
}

- (NSFont *)_labelFont
{
    NSFont *font = [_properties objectForKey:GRAxesLabelFont];
    return font ? font : [NSFont labelFontOfSize:[NSFont smallSystemFontSize]];
}

- (NSDictionary *)_labelAttributes
{
    return [NSDictionary dictionaryWithObjectsAndKeys:
            [self _labelFont], NSFontAttributeName,
            [self _textColor], NSForegroundColorAttributeName, nil];
}

- (BOOL)_numberForKey:(NSString *)fixedKey orKey:(NSString *)key value:(double *)out
{
    id v = [_properties objectForKey:fixedKey];
    if (!v) v = [_properties objectForKey:key];
    if (!v) return NO;
    *out = [v doubleValue];
    return isfinite(*out);
}

- (void)_computeRanges
{
    NSArray *dataSets = [_chart dataSets];

    // X: as set by the plugin, else the data's extent.
    double dataXMin = 0, dataXMax = 0;
    BOOL haveX = NO;
    for (GRDataSet *ds in dataSets) {
        double a, b;
        if ([ds _isHidden]) continue;
        if ([ds _getXRangeMin:&a max:&b]) {
            if (!haveX) { dataXMin = a; dataXMax = b; haveX = YES; }
            else { if (a < dataXMin) dataXMin = a; if (b > dataXMax) dataXMax = b; }
        }
    }
    double xMin = haveX ? dataXMin : 0, xMax = haveX ? dataXMax : 1;
    double v;
    if ([self _numberForKey:GRAxesFixedXPlotMin orKey:GRAxesXPlotMin value:&v]) xMin = v;
    if ([self _numberForKey:GRAxesFixedXPlotMax orKey:GRAxesXPlotMax value:&v]) xMax = v;
    if (!(xMax > xMin)) xMax = xMin + 1;
    _xMin = xMin; _xMax = xMax;

    // Y: fitted to the visible data within the X range, unless set.
    double yMin = 0, yMax = 0;
    BOOL haveY = NO;
    for (GRDataSet *ds in dataSets) {
        double a, b;
        if ([ds _isHidden]) continue;
        if ([ds _getYRangeMin:&a max:&b inXFrom:xMin to:xMax]) {
            if (!haveY) { yMin = a; yMax = b; haveY = YES; }
            else { if (a < yMin) yMin = a; if (b > yMax) yMax = b; }
        }
    }
    if (!haveY) { yMin = 0; yMax = 1; }
    if (yMax - yMin <= fabs(yMax) * 1e-9) {
        double pad = fabs(yMax) > 0 ? fabs(yMax) * 0.1 : 1.0;
        yMin -= pad; yMax += pad;
    } else {
        double pad = (yMax - yMin) * 0.05;
        yMax += pad;
        if (yMin < 0) yMin -= pad;
    }
    BOOL fixedYMin = [self _numberForKey:GRAxesFixedYPlotMin orKey:GRAxesYPlotMin value:&v];
    if (fixedYMin) yMin = v;
    double fixedYMaxValue;
    BOOL fixedYMax = [self _numberForKey:GRAxesFixedYPlotMax orKey:GRAxesYPlotMax value:&fixedYMaxValue];
    if (fixedYMax) yMax = fixedYMaxValue;
    if (!(yMax > yMin)) yMax = yMin + 1;

    // Round the free ends of Y out to a tick.
    double step = GRNiceStep((yMax - yMin) / 5.0);
    if (!fixedYMin) yMin = floor(yMin / step) * step;
    if (!fixedYMax) yMax = ceil(yMax / step) * step;
    if (!(yMax > yMin)) yMax = yMin + step;
    _yMin = yMin; _yMax = yMax;
}

- (CGFloat)_widestYLabelWidth:(double)step
{
    NSDictionary *attributes = [self _labelAttributes];
    CGFloat widest = 0;
    id delegate = [_chart delegate];
    BOOL custom = [delegate respondsToSelector:@selector(chart:yLabelForAxes:value:defaultLabel:)];
    for (double y = ceil(_yMin / step) * step; y <= _yMax + step * 1e-6; y += step) {
        NSString *label = GRDefaultLabel(y, step);
        if (custom) {
            NSString *c = [(id<GRShimDataSource>)delegate chart:_chart yLabelForAxes:self value:y defaultLabel:label];
            if (c) label = c;
        }
        CGFloat w = [label sizeWithAttributes:attributes].width;
        if (w > widest) widest = w;
    }
    return widest;
}

- (void)layoutInBounds:(NSRect)bounds
{
    [self _computeRanges];

    NSFont *font = [self _labelFont];
    CGFloat lineHeight = ceil([font ascender] - [font descender]) + 2;
    BOOL xLabels = GRBool([_properties objectForKey:GRAxesDrawXLabels], YES);
    BOOL yLabels = GRBool([_properties objectForKey:GRAxesDrawYLabels], YES);
    NSString *xTitle = [_properties objectForKey:GRAxesXTitle];
    NSString *yTitle = [_properties objectForKey:GRAxesYTitle];

    double yStep = GRNiceStep((_yMax - _yMin) / MAX(2.0, floor(NSHeight(bounds) / 40.0)));

    CGFloat left = 8, bottom = 6, top = 10, right = 14;
    if (yLabels) left += [self _widestYLabelWidth:yStep] + 6;
    if ([yTitle length]) left += lineHeight + 2;
    if (xLabels) bottom += lineHeight + 4;
    if ([xTitle length]) bottom += lineHeight + 2;

    NSRect plot = NSMakeRect(NSMinX(bounds) + left, NSMinY(bounds) + bottom,
                             NSWidth(bounds) - left - right, NSHeight(bounds) - bottom - top);
    if (plot.size.width < 10) plot.size.width = 10;
    if (plot.size.height < 10) plot.size.height = 10;
    _plotRect = NSIntegralRect(plot);
}

- (NSPoint)locationForXValue:(double)x yValue:(double)y
{
    double fx = (x - _xMin) / (_xMax - _xMin);
    double fy = (y - _yMin) / (_yMax - _yMin);
    return NSMakePoint(NSMinX(_plotRect) + fx * NSWidth(_plotRect),
                       NSMinY(_plotRect) + fy * NSHeight(_plotRect));
}

- (double)xValueAtPoint:(NSPoint)point
{
    if (NSWidth(_plotRect) <= 0) return _xMin;
    return _xMin + (point.x - NSMinX(_plotRect)) / NSWidth(_plotRect) * (_xMax - _xMin);
}

- (double)yValueAtPoint:(NSPoint)point
{
    if (NSHeight(_plotRect) <= 0) return _yMin;
    return _yMin + (point.y - NSMinY(_plotRect)) / NSHeight(_plotRect) * (_yMax - _yMin);
}

- (void)drawAxes
{
    NSDictionary *attributes = [self _labelAttributes];
    NSFont *font = [self _labelFont];
    CGFloat lineHeight = ceil([font ascender] - [font descender]) + 2;
    id delegate = [_chart delegate];

    double xStep = GRNiceStep((_xMax - _xMin) / MAX(2.0, floor(NSWidth(_plotRect) / 60.0)));
    double yStep = GRNiceStep((_yMax - _yMin) / MAX(2.0, floor(NSHeight([_chart bounds]) / 40.0)));
    // Time points are integers: never label fractions of them unless the range is tiny.
    if (_xMax - _xMin >= 4 && xStep < 1) xStep = 1;

    BOOL xMajorTicks = GRBool([_properties objectForKey:GRAxesDrawXMajorTicks], YES);
    BOOL xMinorTicks = GRBool([_properties objectForKey:GRAxesDrawXMinorTicks], NO);
    BOOL yMajorTicks = GRBool([_properties objectForKey:GRAxesDrawYMajorTicks], YES);
    BOOL yMinorTicks = GRBool([_properties objectForKey:GRAxesDrawYMinorTicks], NO);
    BOOL xMajorLines = GRBool([_properties objectForKey:GRAxesDrawXMajorLines], YES);
    BOOL yMajorLines = GRBool([_properties objectForKey:GRAxesDrawYMajorLines], YES);
    BOOL xLabels = GRBool([_properties objectForKey:GRAxesDrawXLabels], YES);
    BOOL yLabels = GRBool([_properties objectForKey:GRAxesDrawYLabels], YES);

    NSBezierPath *grid = [NSBezierPath bezierPath];
    NSBezierPath *ticks = [NSBezierPath bezierPath];

    // X axis
    double xStart = ceil(_xMin / xStep - 1e-9) * xStep;
    for (double x = xStart; x <= _xMax + xStep * 1e-6; x += xStep) {
        CGFloat px = round([self locationForXValue:x yValue:_yMin].x) + 0.5;
        if (xMajorLines) {
            [grid moveToPoint:NSMakePoint(px, NSMinY(_plotRect))];
            [grid lineToPoint:NSMakePoint(px, NSMaxY(_plotRect))];
        }
        if (xMajorTicks) {
            [ticks moveToPoint:NSMakePoint(px, NSMinY(_plotRect))];
            [ticks lineToPoint:NSMakePoint(px, NSMinY(_plotRect) - 4)];
        }
        if (xLabels) {
            NSString *label = GRDefaultLabel(x, xStep);
            if ([delegate respondsToSelector:@selector(chart:xLabelForAxes:value:defaultLabel:)]) {
                NSString *c = [(id<GRShimDataSource>)delegate chart:_chart xLabelForAxes:self value:x defaultLabel:label];
                if (c) label = c;
            }
            NSSize size = [label sizeWithAttributes:attributes];
            [label drawAtPoint:NSMakePoint(px - size.width / 2, NSMinY(_plotRect) - 5 - size.height) withAttributes:attributes];
        }
    }
    if (xMinorTicks) {
        double minor = xStep / ((xStep >= 5 && fmod(xStep, 5) == 0) ? 5 : 2);
        for (double x = ceil(_xMin / minor - 1e-9) * minor; x <= _xMax + minor * 1e-6; x += minor) {
            CGFloat px = round([self locationForXValue:x yValue:_yMin].x) + 0.5;
            [ticks moveToPoint:NSMakePoint(px, NSMinY(_plotRect))];
            [ticks lineToPoint:NSMakePoint(px, NSMinY(_plotRect) - 2)];
        }
    }

    // Y axis
    double yStart = ceil(_yMin / yStep - 1e-9) * yStep;
    BOOL customY = [delegate respondsToSelector:@selector(chart:yLabelForAxes:value:defaultLabel:)];
    for (double y = yStart; y <= _yMax + yStep * 1e-6; y += yStep) {
        CGFloat py = round([self locationForXValue:_xMin yValue:y].y) + 0.5;
        if (yMajorLines) {
            [grid moveToPoint:NSMakePoint(NSMinX(_plotRect), py)];
            [grid lineToPoint:NSMakePoint(NSMaxX(_plotRect), py)];
        }
        if (yMajorTicks) {
            [ticks moveToPoint:NSMakePoint(NSMinX(_plotRect), py)];
            [ticks lineToPoint:NSMakePoint(NSMinX(_plotRect) - 4, py)];
        }
        if (yLabels) {
            NSString *label = GRDefaultLabel(y, yStep);
            if (customY) {
                NSString *c = [(id<GRShimDataSource>)delegate chart:_chart yLabelForAxes:self value:y defaultLabel:label];
                if (c) label = c;
            }
            NSSize size = [label sizeWithAttributes:attributes];
            [label drawAtPoint:NSMakePoint(NSMinX(_plotRect) - 6 - size.width, py - size.height / 2) withAttributes:attributes];
        }
    }
    if (yMinorTicks) {
        double minor = yStep / 2;
        for (double y = ceil(_yMin / minor - 1e-9) * minor; y <= _yMax + minor * 1e-6; y += minor) {
            CGFloat py = round([self locationForXValue:_xMin yValue:y].y) + 0.5;
            [ticks moveToPoint:NSMakePoint(NSMinX(_plotRect), py)];
            [ticks lineToPoint:NSMakePoint(NSMinX(_plotRect) - 2, py)];
        }
    }

    [[self _gridColor] setStroke];
    [grid setLineWidth:1.0];
    [grid stroke];

    [[self _frameColor] setStroke];
    [ticks setLineWidth:1.0];
    [ticks stroke];

    NSBezierPath *frame = [NSBezierPath bezierPathWithRect:NSInsetRect(_plotRect, -0.5, -0.5)];
    [frame setLineWidth:1.0];
    [frame stroke];

    // Titles
    NSString *xTitle = [_properties objectForKey:GRAxesXTitle];
    if ([xTitle length]) {
        NSSize size = [xTitle sizeWithAttributes:attributes];
        CGFloat y = NSMinY(_plotRect) - 5 - (xLabels ? lineHeight + 2 : 0) - size.height;
        [xTitle drawAtPoint:NSMakePoint(NSMidX(_plotRect) - size.width / 2, y) withAttributes:attributes];
    }
    NSString *yTitle = [_properties objectForKey:GRAxesYTitle];
    if ([yTitle length]) {
        NSSize size = [yTitle sizeWithAttributes:attributes];
        NSGraphicsContext *context = [NSGraphicsContext currentContext];
        [context saveGraphicsState];
        NSAffineTransform *transform = [NSAffineTransform transform];
        [transform translateXBy:NSMinX([_chart bounds]) + 6 + size.height yBy:NSMidY(_plotRect) - size.width / 2];
        [transform rotateByDegrees:90];
        [transform concat];
        [yTitle drawAtPoint:NSZeroPoint withAttributes:attributes];
        [context restoreGraphicsState];
    }
}

@end

#pragma mark - GRChartView

@implementation GRChartView

- (void)_grCommonInit
{
    if (_axes) return;
    _axes = [[GRAxes alloc] initWithOwner:self];
    _dataSets = [[NSMutableArray alloc] init];
    _chartProperties = [[NSMutableDictionary alloc] init];
    [_chartProperties setObject:[NSNumber numberWithBool:YES] forKey:GRChartDrawBackground];
    _needsReload = NO;
    _nextAutoPlotColor = 0;
}

- (id)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self) [self _grCommonInit];
    return self;
}

- (id)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (self) [self _grCommonInit];
    return self;
}

- (void)awakeFromNib
{
    [super awakeFromNib];
    [self _grCommonInit];
}

- (void)dealloc
{
    for (GRDataSet *ds in _dataSets) [ds _setOwnerChart:nil];
    [_dataSets release];
    [_axes release];
    [_chartProperties release];
    [super dealloc];
}

- (BOOL)isOpaque { return NO; }

- (id)propertyForKey:(NSString *)key
{
    return key ? [_chartProperties objectForKey:key] : nil;
}

- (void)setProperty:(id)value forKey:(NSString *)key
{
    if (!key) return;
    if (value) [_chartProperties setObject:value forKey:key];
    else       [_chartProperties removeObjectForKey:key];
    [self setNeedsDisplay:YES];
}

- (id)valueForUndefinedKey:(NSString *)key { return [self propertyForKey:key]; }

- (void)setDataSource:(id)aDataSource { dataSource = aDataSource; [self setNeedsToReloadData:YES]; }
- (id)dataSource { return dataSource; }
- (void)setDelegate:(id)aDelegate { delegate = aDelegate; [self setNeedsDisplay:YES]; }
- (id)delegate { return delegate; }

- (GRAxes *)axes { return _axes; }
- (NSRect)plotRect { return [_axes plotRect]; }

- (NSArray *)dataSets { return [[_dataSets copy] autorelease]; }
- (NSUInteger)numberOfDataSets { return [_dataSets count]; }

- (NSColor *)nextAutoPlotColor
{
    static NSArray *palette = nil;
    if (!palette) {
        palette = [[NSArray alloc] initWithObjects:
                   [NSColor colorWithCalibratedRed:0.12 green:0.47 blue:0.71 alpha:1],
                   [NSColor colorWithCalibratedRed:0.84 green:0.15 blue:0.16 alpha:1],
                   [NSColor colorWithCalibratedRed:0.17 green:0.63 blue:0.17 alpha:1],
                   [NSColor colorWithCalibratedRed:1.00 green:0.50 blue:0.05 alpha:1],
                   [NSColor colorWithCalibratedRed:0.58 green:0.40 blue:0.74 alpha:1],
                   [NSColor colorWithCalibratedRed:0.55 green:0.34 blue:0.29 alpha:1], nil];
    }
    NSColor *color = [palette objectAtIndex:_nextAutoPlotColor % [palette count]];
    _nextAutoPlotColor++;
    return color;
}

- (void)addDataSet:(GRDataSet *)dataSet loadData:(BOOL)load
{
    if (!dataSet || [_dataSets indexOfObjectIdenticalTo:dataSet] != NSNotFound) return;
    [_dataSets addObject:dataSet];
    [dataSet _setOwnerChart:self];
    if (![dataSet propertyForKey:GRDataSetPlotColor])
        [dataSet _setAutoColor:[self nextAutoPlotColor]];
    if (load) [dataSet reloadData];
    [self setNeedsDisplay:YES];
}

- (void)addDataSets:(NSArray *)dataSets loadData:(BOOL)load
{
    for (GRDataSet *ds in dataSets) [self addDataSet:ds loadData:load];
}

- (void)removeDataSet:(GRDataSet *)dataSet
{
    if (!dataSet) return;
    NSUInteger index = [_dataSets indexOfObjectIdenticalTo:dataSet];
    if (index == NSNotFound) return;
    [dataSet retain];
    [_dataSets removeObjectAtIndex:index];
    [dataSet _setOwnerChart:nil];
    [dataSet release];
    [self setNeedsDisplay:YES];
}

- (void)removeAllDataSets
{
    for (GRDataSet *ds in _dataSets) [ds _setOwnerChart:nil];
    [_dataSets removeAllObjects];
    [self setNeedsDisplay:YES];
}

- (void)reloadData
{
    _needsReload = NO;
    for (GRDataSet *ds in [[_dataSets copy] autorelease]) [ds reloadData];
    [self setNeedsDisplay:YES];
}

- (void)setNeedsToReloadData:(BOOL)flag
{
    _needsReload = flag;
    if (flag) [self setNeedsDisplay:YES];
}

- (BOOL)needsToReloadData { return _needsReload; }

- (void)drawRect:(NSRect)dirtyRect
{
    if (_needsReload) {
        _needsReload = NO;
        for (GRDataSet *ds in [[_dataSets copy] autorelease]) [ds reloadData];
    }

    NSRect bounds = [self bounds];
    if (GRBool([_chartProperties objectForKey:GRChartDrawBackground], YES)) {
        NSColor *background = [_chartProperties objectForKey:GRChartBackgroundColor];
        [(background ? background : [NSColor whiteColor]) setFill];
        NSRectFill(bounds);
    }

    [_axes layoutInBounds:bounds];

    NSRect plot = [_axes plotRect];
    [[_axes _plotBackgroundColor] setFill];
    NSRectFill(plot);

    [_axes drawAxes];

    NSGraphicsContext *context = [NSGraphicsContext currentContext];
    [context saveGraphicsState];
    [[NSBezierPath bezierPathWithRect:plot] setClip];
    for (GRDataSet *ds in _dataSets) [ds _drawWithAxes:_axes];
    [context restoreGraphicsState];
}

@end
