//
//  UMMPCurvesController.m — "UMMPerfusion Time Curves" window (IsiX port). Manual reference counting.
//

#import "UMMPCurvesController.h"
#import "GRChartView.h"
#import "GRAxes.h"
#import "GRDataSet.h"
#import "GRLineDataSet.h"
#import <OsiriXAPI/ViewerController.h>
#if __has_include(<OsiriXAPI/ViewerController+ROI.h>)   // IsiX; in Horos these are in ViewerController.h
#import <OsiriXAPI/ViewerController+ROI.h>
#endif
#import <OsiriXAPI/DCMPix.h>
#import <OsiriXAPI/ROI.h>
#import <OsiriXAPI/Notifications.h>
#include <math.h>

enum { UMMPCurveSignal = 0, UMMPCurveRelative, UMMPCurveDifference, UMMPCurveDeltaR2 };

static NSTextField *UMMPCurvesLabel(NSString *text)
{
    NSTextField *f = [NSTextField labelWithString:text];
    [f setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    return f;
}

@interface UMMPCurvesController ()
{
    ViewerController *_viewer;     // not retained; cleared when it closes
    NSTextField *_viewerLabel;
    NSPopUpButton *_modePopup;
    NSTextField *_baselineField;
    GRChartView *_chart;
    NSTableView *_table;
    NSMutableArray *_curves;       // NSMutableDictionary per ROI
    NSMutableSet *_hidden;         // NSValue (non-retained ROI) of hidden curves
    NSArray *_palette;
    BOOL _refreshPending;
    BOOL _timesInSeconds;
}
@end

@implementation UMMPCurvesController

+ (UMMPCurvesController *)sharedController
{
    static UMMPCurvesController *shared = nil;
    if (!shared) shared = [[UMMPCurvesController alloc] init];
    return shared;
}

- (id)init
{
    NSPanel *panel = [[[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 760, 600)
                                                 styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                           NSWindowStyleMaskResizable | NSWindowStyleMaskUtilityWindow
                                                   backing:NSBackingStoreBuffered defer:YES] autorelease];
    self = [super initWithWindow:panel];
    if (self) {
        [panel setTitle:@"UMMPerfusion Time Curves"];
        [panel setFloatingPanel:YES];
        [panel setLevel:NSFloatingWindowLevel];
        [panel setHidesOnDeactivate:YES];
        [panel setBecomesKeyOnlyIfNeeded:NO];
        [panel setCollectionBehavior:NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorMoveToActiveSpace];
        [panel setReleasedWhenClosed:NO];
        [panel setMinSize:NSMakeSize(560, 460)];
        [panel setDelegate:self];
        _curves = [[NSMutableArray alloc] init];
        _hidden = [[NSMutableSet alloc] init];
        _palette = [[NSArray alloc] initWithObjects:
                    [NSColor systemBlueColor], [NSColor systemRedColor], [NSColor systemGreenColor],
                    [NSColor systemOrangeColor], [NSColor systemPurpleColor], [NSColor systemTealColor],
                    [NSColor systemPinkColor], [NSColor systemBrownColor], [NSColor systemYellowColor],
                    [NSColor systemIndigoColor], [NSColor systemGrayColor], [NSColor systemMintColor], nil];
        [self buildInterface];
        [panel center];
        [panel setFrameAutosaveName:@"UMMPCurvesWindow"];
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(viewerWillClose:) name:OsirixCloseViewerNotification object:nil];
        [nc addObserver:self selector:@selector(roisChanged:) name:OsirixROIChangeNotification object:nil];
        [nc addObserver:self selector:@selector(roisChanged:) name:OsirixRemoveROINotification object:nil];
        [nc addObserver:self selector:@selector(roisChanged:) name:OsirixAddROINotification object:nil];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_curves release];
    [_hidden release];
    [_palette release];
    [super dealloc];
}

#pragma mark - Interface

- (void)buildInterface
{
    NSView *content = [[self window] contentView];

    _viewerLabel = UMMPCurvesLabel(@"No viewer");
    [_viewerLabel setFont:[NSFont boldSystemFontOfSize:[NSFont smallSystemFontSize]]];
    [_viewerLabel setLineBreakMode:NSLineBreakByTruncatingMiddle];
    [_viewerLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSButton *front = [NSButton buttonWithTitle:@"Use Frontmost Viewer" target:self action:@selector(useFrontmostViewer:)];
    [front setControlSize:NSControlSizeSmall];

    _modePopup = [[[NSPopUpButton alloc] init] autorelease];
    [_modePopup setControlSize:NSControlSizeSmall];
    [_modePopup setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    [_modePopup addItemsWithTitles:@[@"Signal", @"Relative enhancement (%)  – DCE",
                                     @"Signal difference (S − S0)  – DCE", @"ΔR2*·TE  – DSC"]];
    [_modePopup selectItemAtIndex:UMMPCurveRelative];
    [_modePopup setTarget:self];
    [_modePopup setAction:@selector(refresh:)];

    _baselineField = [NSTextField textFieldWithString:@"3"];
    [_baselineField setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    [_baselineField setAlignment:NSTextAlignmentRight];
    [[_baselineField widthAnchor] constraintEqualToConstant:36].active = YES;
    [_baselineField setTarget:self];
    [_baselineField setAction:@selector(refresh:)];

    NSButton *refresh = [NSButton buttonWithTitle:@"Refresh" target:self action:@selector(refresh:)];
    [refresh setControlSize:NSControlSizeSmall];
    NSButton *export = [NSButton buttonWithTitle:@"Export CSV…" target:self action:@selector(exportCSV:)];
    [export setControlSize:NSControlSizeSmall];

    NSStackView *top = [NSStackView stackViewWithViews:@[UMMPCurvesLabel(@"Viewer:"), _viewerLabel, front]];
    [top setSpacing:6];
    NSStackView *controls = [NSStackView stackViewWithViews:@[UMMPCurvesLabel(@"Show:"), _modePopup,
                                                              UMMPCurvesLabel(@"Baseline frames:"), _baselineField,
                                                              refresh, export]];
    [controls setSpacing:6];

    _chart = [[[GRChartView alloc] initWithFrame:NSMakeRect(0, 0, 700, 320)] autorelease];
    [_chart setDataSource:self];
    [_chart setDelegate:self];
    [_chart setProperty:@NO forKey:GRChartDrawBackground];
    [_chart setTranslatesAutoresizingMaskIntoConstraints:NO];
    [[_chart heightAnchor] constraintGreaterThanOrEqualToConstant:240].active = YES;

    _table = [[[NSTableView alloc] init] autorelease];
    [_table setUsesAlternatingRowBackgroundColors:YES];
    [_table setDataSource:self];
    [_table setDelegate:self];
    NSArray *columns = @[@[@"show", @"", @22], @[@"name", @"ROI", @150], @[@"slice", @"Slice", @40],
                         @[@"peak", @"Peak", @64], @[@"ttp", @"Time to peak", @84], @[@"washin", @"Wash-in /s", @74],
                         @[@"washout", @"Wash-out %", @74], @[@"auc", @"Area", @70], @[@"shape", @"Shape", @80]];
    for (NSArray *c in columns) {
        NSTableColumn *col = [[[NSTableColumn alloc] initWithIdentifier:[c objectAtIndex:0]] autorelease];
        [[col headerCell] setStringValue:[c objectAtIndex:1]];
        [col setWidth:[[c objectAtIndex:2] doubleValue]];
        if ([[c objectAtIndex:0] isEqualToString:@"show"]) {
            NSButtonCell *check = [[[NSButtonCell alloc] init] autorelease];
            [check setButtonType:NSButtonTypeSwitch];
            [check setTitle:@""];
            [check setControlSize:NSControlSizeSmall];
            [col setDataCell:check];
        } else {
            [[col dataCell] setFont:[NSFont monospacedDigitSystemFontOfSize:[NSFont smallSystemFontSize] weight:NSFontWeightRegular]];
            if (![[c objectAtIndex:0] isEqualToString:@"name"] && ![[c objectAtIndex:0] isEqualToString:@"shape"])
                [[col dataCell] setAlignment:NSTextAlignmentRight];
            [col setEditable:NO];
        }
        [_table addTableColumn:col];
    }
    NSScrollView *scroll = [[[NSScrollView alloc] init] autorelease];
    [scroll setDocumentView:_table];
    [scroll setHasVerticalScroller:YES];
    [scroll setBorderType:NSBezelBorder];
    [[scroll heightAnchor] constraintEqualToConstant:150].active = YES;

    NSTextField *note = [NSTextField wrappingLabelWithString:@"Each ROI is measured on its own slice in every frame. Peak, wash-in, wash-out and area use the curve shown; wash-out is the fall from the peak to the last frame. Shape: persistent (still rising at the end), plateau (within 10 % of the peak), wash-out (more than 10 % below the peak)."];
    [note setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize] - 1]];
    [note setTextColor:[NSColor secondaryLabelColor]];

    NSStackView *main = [NSStackView stackViewWithViews:@[top, controls, _chart, scroll, note]];
    [main setOrientation:NSUserInterfaceLayoutOrientationVertical];
    [main setAlignment:NSLayoutAttributeLeading];
    [main setSpacing:8];
    [main setTranslatesAutoresizingMaskIntoConstraints:NO];
    [content addSubview:main];
    [NSLayoutConstraint activateConstraints:@[
        [[main leadingAnchor] constraintEqualToAnchor:[content leadingAnchor] constant:14],
        [[main trailingAnchor] constraintEqualToAnchor:[content trailingAnchor] constant:-14],
        [[main topAnchor] constraintEqualToAnchor:[content topAnchor] constant:12],
        [[main bottomAnchor] constraintEqualToAnchor:[content bottomAnchor] constant:-12],
        [[_chart widthAnchor] constraintEqualToAnchor:[main widthAnchor]],
        [[scroll widthAnchor] constraintEqualToAnchor:[main widthAnchor]],
        [[note widthAnchor] constraintEqualToAnchor:[main widthAnchor]],
        [[top widthAnchor] constraintEqualToAnchor:[main widthAnchor]]]];
    [_chart setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];
}

#pragma mark - Viewer

- (void)showForViewer:(ViewerController *)viewer
{
    [self setViewer:viewer];
    [self showWindow:nil];
    [[self window] makeKeyAndOrderFront:nil];
}

- (void)setViewer:(ViewerController *)viewer
{
    _viewer = viewer;
    [_hidden removeAllObjects];
    NSString *title = [[_viewer window] title];
    [_viewerLabel setStringValue:_viewer ? (title ? title : @"Viewer") : @"No viewer"];
    [self refresh:nil];
}

- (void)useFrontmostViewer:(id)sender
{
    ViewerController *front = [ViewerController frontMostDisplayed2DViewer];
    if (front) [self setViewer:front];
}

- (void)viewerWillClose:(NSNotification *)note
{
    if ([note object] == _viewer) [self setViewer:nil];
}

- (void)roisChanged:(NSNotification *)note
{
    if (!_viewer || ![[self window] isVisible] || _refreshPending) return;
    _refreshPending = YES;
    [self performSelector:@selector(deferredRefresh) withObject:nil afterDelay:0.15];
}

- (void)deferredRefresh
{
    _refreshPending = NO;
    [self refresh:nil];
}

#pragma mark - Curves

- (NSArray *)timesForSlice:(NSUInteger)slice frames:(int)frames
{
    NSMutableArray *times = [NSMutableArray arrayWithCapacity:frames];
    NSDate *first = nil;
    BOOL seconds = YES;
    for (int t = 0; t < frames && seconds; t++) {
        NSArray *pixList = [_viewer pixList:t];
        if (slice >= [pixList count]) { seconds = NO; break; }
        NSDate *date = [[pixList objectAtIndex:slice] acquisitionTime];
        if (!date) { seconds = NO; break; }
        if (!first) first = date;
        [times addObject:@([date timeIntervalSinceDate:first])];
    }
    // all times equal, or not increasing: frame numbers
    if (seconds && [times count] > 1 && [[times lastObject] doubleValue] <= 0) seconds = NO;
    if (!seconds) {
        [times removeAllObjects];
        for (int t = 0; t < frames; t++) [times addObject:@(t + 1)];
    }
    _timesInSeconds = seconds;
    return times;
}

- (void)refresh:(id)sender
{
    [_chart removeAllDataSets];
    [_curves removeAllObjects];
    if (!_viewer) { [_table reloadData]; return; }

    int frames = [_viewer maxMovieIndex];
    if (frames < 2) {
        [_viewerLabel setStringValue:[NSString stringWithFormat:@"%@ — not a 4D series", [[_viewer window] title]]];
        [_table reloadData];
        [_chart setNeedsDisplay:YES];
        return;
    }
    int bl = [_baselineField intValue];
    if (bl < 1) bl = 1;
    if (bl > frames - 1) bl = frames - 1;
    NSInteger mode = [_modePopup indexOfSelectedItem];

    NSMutableSet *seen = [NSMutableSet set];
    BOOL allSeconds = YES;
    for (int m = 0; m < frames; m++) {
        NSArray *perSlice = [_viewer roiList:m];
        for (NSUInteger s = 0; s < [perSlice count]; s++) {
            for (ROI *roi in [perSlice objectAtIndex:s]) {
                NSValue *key = [NSValue valueWithNonretainedObject:roi];
                if ([seen containsObject:key]) continue;
                [seen addObject:key];
                if ([roi roiArea] <= 0) continue;   // lines, points: no area to measure

                NSArray *times = [self timesForSlice:s frames:frames];
                allSeconds = allSeconds && _timesInSeconds;
                NSMutableArray *values = [NSMutableArray arrayWithCapacity:frames];
                double *y = (double *)malloc(sizeof(double) * (size_t)frames);
                for (int t = 0; t < frames; t++) {
                    float mean = 0;
                    [[[_viewer pixList:t] objectAtIndex:s] computeROI:roi :&mean :NULL :NULL :NULL :NULL];
                    y[t] = mean;
                }
                double s0 = 0;
                for (int t = 0; t < bl; t++) s0 += y[t];
                s0 /= bl;
                for (int t = 0; t < frames; t++) {
                    double v = y[t];
                    switch (mode) {
                        case UMMPCurveRelative:   v = (s0 != 0) ? 100.0 * (y[t] - s0) / s0 : NAN; break;
                        case UMMPCurveDifference: v = y[t] - s0; break;
                        case UMMPCurveDeltaR2:    v = (s0 > 0 && y[t] > 0) ? -log(y[t] / s0) : NAN; break;
                        default: break;
                    }
                    y[t] = v;
                    [values addObject:@(v)];
                }

                NSMutableDictionary *curve = [NSMutableDictionary dictionary];
                [curve setObject:key forKey:@"key"];
                [curve setObject:([roi name] ? [roi name] : @"ROI") forKey:@"name"];
                [curve setObject:@(s + 1) forKey:@"slice"];
                [curve setObject:times forKey:@"times"];
                [curve setObject:values forKey:@"values"];
                [self addMetricsTo:curve y:y times:times frames:frames baseline:bl];
                free(y);
                [_curves addObject:curve];
            }
        }
    }
    _timesInSeconds = allSeconds;

    NSUInteger index = 0;
    for (NSMutableDictionary *curve in _curves) {
        GRLineDataSet *ds = [[[GRLineDataSet alloc] initWithOwnerChart:_chart] autorelease];
        NSColor *color = [_palette objectAtIndex:index++ % [_palette count]];
        [ds setProperty:color forKey:GRDataSetPlotColor];
        [ds setProperty:@YES forKey:GRDataSetDrawMarkers];
        [ds setProperty:@([_hidden containsObject:[curve objectForKey:@"key"]]) forKey:GRDataSetHidden];
        [curve setObject:ds forKey:@"dataSet"];
        [curve setObject:color forKey:@"color"];
        [_chart addDataSet:ds loadData:YES];
    }

    NSString *yTitle = @[@"Signal", @"Relative enhancement (%)", @"S − S0", @"ΔR2*·TE"][MAX(0, MIN(3, mode))];
    [[_chart axes] setProperty:yTitle forKey:GRAxesYTitle];
    [[_chart axes] setProperty:(_timesInSeconds ? @"Time (s)" : @"Frame") forKey:GRAxesXTitle];
    [_table reloadData];
    [_chart setNeedsDisplay:YES];
}

- (void)addMetricsTo:(NSMutableDictionary *)curve y:(const double *)y times:(NSArray *)times frames:(int)frames baseline:(int)bl
{
    int peak = -1;
    for (int t = bl; t < frames; t++)
        if (isfinite(y[t]) && (peak < 0 || y[t] > y[peak])) peak = t;
    if (peak < 0) return;
    double t0 = [[times objectAtIndex:0] doubleValue];
    double peakValue = y[peak];
    [curve setObject:@(peakValue) forKey:@"peak"];
    [curve setObject:@([[times objectAtIndex:peak] doubleValue] - t0) forKey:@"ttp"];

    double washin = NAN;
    for (int t = MAX(1, bl); t <= peak; t++) {
        double dt = [[times objectAtIndex:t] doubleValue] - [[times objectAtIndex:t - 1] doubleValue];
        if (dt <= 0 || !isfinite(y[t]) || !isfinite(y[t - 1])) continue;
        double slope = (y[t] - y[t - 1]) / dt;
        if (isnan(washin) || slope > washin) washin = slope;
    }
    if (isfinite(washin)) [curve setObject:@(washin) forKey:@"washin"];

    double last = y[frames - 1];
    if (isfinite(last) && peakValue != 0) {
        double washout = 100.0 * (peakValue - last) / fabs(peakValue);
        [curve setObject:@(washout) forKey:@"washout"];
        NSString *shape = (peak >= frames - 2) ? @"persistent" : (washout <= 10.0 ? @"plateau" : @"wash-out");
        [curve setObject:shape forKey:@"shape"];
    }

    double area = 0;
    for (int t = MAX(1, bl); t < frames; t++) {
        if (!isfinite(y[t]) || !isfinite(y[t - 1])) continue;
        area += 0.5 * (y[t] + y[t - 1]) * ([[times objectAtIndex:t] doubleValue] - [[times objectAtIndex:t - 1] doubleValue]);
    }
    [curve setObject:@(area) forKey:@"auc"];
}

#pragma mark - Chart data source

- (NSDictionary *)curveForDataSet:(GRDataSet *)dataSet
{
    for (NSDictionary *c in _curves) if ([c objectForKey:@"dataSet"] == dataSet) return c;
    return nil;
}

- (NSInteger)chart:(GRChartView *)chart numberOfElementsForDataSet:(GRDataSet *)dataSet
{
    return (NSInteger)[[[self curveForDataSet:dataSet] objectForKey:@"values"] count];
}

- (double)chart:(GRChartView *)chart xValueForDataSet:(GRDataSet *)dataSet element:(NSInteger)element
{
    return [[[[self curveForDataSet:dataSet] objectForKey:@"times"] objectAtIndex:element] doubleValue];
}

- (double)chart:(GRChartView *)chart yValueForDataSet:(GRDataSet *)dataSet element:(NSInteger)element
{
    return [[[[self curveForDataSet:dataSet] objectForKey:@"values"] objectAtIndex:element] doubleValue];
}

#pragma mark - Table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    return (NSInteger)[_curves count];
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
    NSDictionary *c = [_curves objectAtIndex:row];
    NSString *key = [column identifier];
    if ([key isEqualToString:@"show"]) return @(![_hidden containsObject:[c objectForKey:@"key"]]);
    id v = [c objectForKey:key];
    if ([key isEqualToString:@"name"]) return [NSString stringWithFormat:@"● %@", v];
    if (!v) return @"–";
    if ([key isEqualToString:@"slice"] || [key isEqualToString:@"shape"]) return v;
    if ([key isEqualToString:@"ttp"]) return [NSString stringWithFormat:_timesInSeconds ? @"%.1f s" : @"%.0f fr", [v doubleValue]];
    return [NSString stringWithFormat:@"%.3g", [v doubleValue]];
}

- (void)tableView:(NSTableView *)tableView setObjectValue:(id)value forTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
    if (![[column identifier] isEqualToString:@"show"]) return;
    NSDictionary *c = [_curves objectAtIndex:row];
    NSValue *key = [c objectForKey:@"key"];
    BOOL show = [value boolValue];
    if (show) [_hidden removeObject:key]; else [_hidden addObject:key];
    [[c objectForKey:@"dataSet"] setProperty:@(!show) forKey:GRDataSetHidden];
    [_chart setNeedsDisplay:YES];
}

- (void)tableView:(NSTableView *)tableView willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
    if ([[column identifier] isEqualToString:@"name"] && [cell respondsToSelector:@selector(setTextColor:)])
        [cell setTextColor:[[_curves objectAtIndex:row] objectForKey:@"color"]];
}

#pragma mark - Export

- (void)exportCSV:(id)sender
{
    if (![_curves count]) { NSBeep(); return; }
    NSSavePanel *panel = [NSSavePanel savePanel];
    [panel setNameFieldStringValue:@"UMMPerfusion time curves.csv"];
    [panel beginSheetModalForWindow:[self window] completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSMutableString *csv = [NSMutableString string];
        [csv appendFormat:@"# Viewer: \"%@\"\n# Curves: %@, baseline frames %d\n",
         [[_viewerLabel stringValue] stringByReplacingOccurrencesOfString:@"\"" withString:@"'"],
         [_modePopup titleOfSelectedItem], [_baselineField intValue]];
        // curves: one row per frame (times of the first curve's slice; slices may differ slightly)
        [csv appendString:_timesInSeconds ? @"time_s" : @"frame"];
        for (NSDictionary *c in _curves)
            [csv appendFormat:@",\"%@ (slice %@)\"", [[c objectForKey:@"name"] stringByReplacingOccurrencesOfString:@"\"" withString:@"'"], [c objectForKey:@"slice"]];
        [csv appendString:@"\n"];
        NSArray *times = [[_curves objectAtIndex:0] objectForKey:@"times"];
        for (NSUInteger t = 0; t < [times count]; t++) {
            [csv appendFormat:@"%.3f", [[times objectAtIndex:t] doubleValue]];
            for (NSDictionary *c in _curves) {
                NSArray *v = [c objectForKey:@"values"];
                [csv appendFormat:@",%.6g", t < [v count] ? [[v objectAtIndex:t] doubleValue] : NAN];
            }
            [csv appendString:@"\n"];
        }
        [csv appendString:@"\nroi,slice,peak,time_to_peak,wash_in_per_s,wash_out_percent,area,shape\n"];
        for (NSDictionary *c in _curves) {
            NSString *(^num)(NSString *) = ^NSString *(NSString *k) {
                id v = [c objectForKey:k];
                return v ? [NSString stringWithFormat:@"%.6g", [v doubleValue]] : @"";
            };
            [csv appendFormat:@"\"%@\",%@,%@,%@,%@,%@,%@,%@\n",
             [[c objectForKey:@"name"] stringByReplacingOccurrencesOfString:@"\"" withString:@"'"], [c objectForKey:@"slice"],
             num(@"peak"), num(@"ttp"), num(@"washin"), num(@"washout"), num(@"auc"),
             [c objectForKey:@"shape"] ? [c objectForKey:@"shape"] : @""];
        }
        NSError *error = nil;
        if (![csv writeToURL:[panel URL] atomically:YES encoding:NSUTF8StringEncoding error:&error])
            [[NSAlert alertWithError:error] runModal];
    }];
}

@end
