//
//  GraphKitShim — GRDataSet and its line subclass.
//

#import <Cocoa/Cocoa.h>
#import "GRChartView.h"

@class GRAxes;

extern NSString *GRDataSetHidden;
extern NSString *GRDataSetDrawMarkers;
extern NSString *GRDataSetDrawPlotLine;
extern NSString *GRDataSetPlotColor;
extern NSString *GRDataSetPlotLineWidth;
extern NSString *GRDataSetLegendLabel;
extern NSString *GRDataSetPieStartAngle;   // accepted and ignored

@interface GRDataSet : NSObject
{
    GRChartView *_chart;                // not retained (owner)
    NSMutableDictionary *_properties;
    double *_x;
    double *_y;
    NSUInteger _count;
    NSColor *_autoColor;
}

- (id)initWithOwnerChart:(GRChartView *)chart;
- (GRChartView *)chart;

- (id)propertyForKey:(NSString *)key;
- (void)setProperty:(id)value forKey:(NSString *)key;

- (NSUInteger)numberOfElements;
- (void)reloadData;

// Used by GRChartView / GRAxes
- (void)_setOwnerChart:(GRChartView *)chart;
- (BOOL)_isHidden;
- (BOOL)_getXRangeMin:(double *)min max:(double *)max;
- (BOOL)_getYRangeMin:(double *)min max:(double *)max inXFrom:(double)x0 to:(double)x1;
- (void)_drawWithAxes:(GRAxes *)axes;
- (void)_setAutoColor:(NSColor *)color;

@end
