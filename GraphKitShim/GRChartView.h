//
//  GraphKitShim — a small, source-level replacement for the subset of the
//  closed-source GraphKit.framework that UMMPerfusion uses. GraphKit was only
//  ever shipped for ppc/i386/x86_64, so it cannot load on Apple Silicon.
//
//  Written for the UMMPerfusion → IsiX port. Manual reference counting.
//

#import <Cocoa/Cocoa.h>

@class GRAxes;
@class GRDataSet;

// Chart properties (only the ones honoured by the shim have an effect).
extern NSString *GRChartDrawBackground;
extern NSString *GRChartBackgroundColor;
extern NSString *GRChartMainTitle;
extern NSString *GRChartMainTitleFont;

@interface GRChartView : NSView
{
    IBOutlet id dataSource;
    IBOutlet id delegate;
    GRAxes *_axes;
    NSMutableArray *_dataSets;
    NSMutableDictionary *_chartProperties;
    BOOL _needsReload;
    NSUInteger _nextAutoPlotColor;
}

- (id)propertyForKey:(NSString *)key;
- (void)setProperty:(id)value forKey:(NSString *)key;

- (void)setDataSource:(id)aDataSource;
- (id)dataSource;
- (void)setDelegate:(id)aDelegate;
- (id)delegate;

- (GRAxes *)axes;
- (NSRect)plotRect;

- (NSArray *)dataSets;
- (NSUInteger)numberOfDataSets;
- (void)addDataSet:(GRDataSet *)dataSet loadData:(BOOL)load;
- (void)removeDataSet:(GRDataSet *)dataSet;
- (void)removeAllDataSets;

- (void)reloadData;
- (void)setNeedsToReloadData:(BOOL)flag;
- (BOOL)needsToReloadData;

- (NSColor *)nextAutoPlotColor;

@end
