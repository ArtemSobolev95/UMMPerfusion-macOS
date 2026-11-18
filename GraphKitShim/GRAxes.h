//
//  GraphKitShim — GRAxes: axis ranges, layout and drawing for GRChartView.
//

#import <Cocoa/Cocoa.h>

@class GRChartView;

extern NSString *GRAxesXTitle;
extern NSString *GRAxesYTitle;
extern NSString *GRAxesLabelFont;
extern NSString *GRAxesMinorLineDashPattern;
extern NSString *GRAxesDrawXLabels;
extern NSString *GRAxesDrawYLabels;
extern NSString *GRAxesDrawXMajorTicks;
extern NSString *GRAxesDrawXMinorTicks;
extern NSString *GRAxesDrawYMajorTicks;
extern NSString *GRAxesDrawYMinorTicks;
extern NSString *GRAxesDrawXMajorLines;
extern NSString *GRAxesDrawYMajorLines;
extern NSString *GRAxesXPlotMin;
extern NSString *GRAxesXPlotMax;
extern NSString *GRAxesYPlotMin;
extern NSString *GRAxesYPlotMax;
extern NSString *GRAxesFixedXPlotMin;
extern NSString *GRAxesFixedXPlotMax;
extern NSString *GRAxesFixedYPlotMin;
extern NSString *GRAxesFixedYPlotMax;

@interface GRAxes : NSObject
{
    GRChartView *_chart;               // not retained (owner)
    NSMutableDictionary *_properties;
    NSRect _plotRect;
    double _xMin, _xMax, _yMin, _yMax; // current data-space range
}

- (id)initWithOwner:(GRChartView *)chart;
- (id)chart;

- (id)propertyForKey:(NSString *)key;
- (void)setProperty:(id)value forKey:(NSString *)key;

- (NSRect)plotRect;

- (double)xValueAtPoint:(NSPoint)point;
- (double)yValueAtPoint:(NSPoint)point;
- (NSPoint)locationForXValue:(double)x yValue:(double)y;

// Used by GRChartView
- (void)layoutInBounds:(NSRect)bounds;
- (void)drawAxes;

@end
