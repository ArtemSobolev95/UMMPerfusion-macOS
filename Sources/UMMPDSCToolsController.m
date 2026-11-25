//
//  UMMPDSCToolsController.m — "UMMPerfusion DSC Tools" window (IsiX port). Manual reference counting.
//

#import "UMMPDSCToolsController.h"
#import "UMMPDSCEngine.h"
#import "UMMPSRCBV.h"
#import "UMMPDeltaT1.h"
#import "UMMPerfusionFilter.h"
#import "UMMPCurvesController.h"
#import <OsiriXAPI/ViewerController.h>
#if __has_include(<OsiriXAPI/ViewerController+ROI.h>)   // IsiX; in Horos these are in ViewerController.h
#import <OsiriXAPI/ViewerController+ROI.h>
#endif
#import <OsiriXAPI/DCMPix.h>
#import <OsiriXAPI/DCMView.h>
#import <OsiriXAPI/ROI.h>
#import <OsiriXAPI/Notifications.h>
#include <math.h>
#include <stdlib.h>

#define UMMP_NOT_COMPUTED -1.0f

static int UMMPCompareFloats(const void *a, const void *b)
{
    float x = *(const float *)a, y = *(const float *)b;
    return (x > y) - (x < y);
}

static NSTextField *UMMPLabel(NSString *text)
{
    NSTextField *f = [NSTextField labelWithString:text];
    [f setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    return f;
}

static NSTextField *UMMPNumberField(NSString *value, CGFloat width)
{
    NSTextField *f = [NSTextField textFieldWithString:value];
    [f setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    [f setAlignment:NSTextAlignmentRight];
    [[f widthAnchor] constraintEqualToConstant:width].active = YES;
    return f;
}

static NSButton *UMMPCheckbox(NSString *title, id target, SEL action)
{
    NSButton *b = [NSButton checkboxWithTitle:title target:target action:action];
    [b setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    return b;
}

static NSButton *UMMPButton(NSString *title, id target, SEL action)
{
    NSButton *b = [NSButton buttonWithTitle:title target:target action:action];
    [b setControlSize:NSControlSizeSmall];
    [b setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    return b;
}

static NSStackView *UMMPRow(NSArray *views)
{
    NSStackView *row = [NSStackView stackViewWithViews:views];
    [row setOrientation:NSUserInterfaceLayoutOrientationHorizontal];
    [row setAlignment:NSLayoutAttributeFirstBaseline];
    [row setSpacing:6];
    return row;
}

static NSBox *UMMPSection(NSString *title, NSView *content)
{
    NSBox *box = [[[NSBox alloc] init] autorelease];
    [box setTitle:title];
    [box setTitleFont:[NSFont boldSystemFontOfSize:[NSFont smallSystemFontSize]]];
    [box setContentViewMargins:NSMakeSize(8, 8)];
    [content setTranslatesAutoresizingMaskIntoConstraints:NO];
    [[box contentView] addSubview:content];
    NSView *cv = [box contentView];
    [NSLayoutConstraint activateConstraints:@[
        [[content leadingAnchor] constraintEqualToAnchor:[cv leadingAnchor] constant:8],
        [[content trailingAnchor] constraintEqualToAnchor:[cv trailingAnchor] constant:-8],
        [[content topAnchor] constraintEqualToAnchor:[cv topAnchor] constant:6],
        [[content bottomAnchor] constraintEqualToAnchor:[cv bottomAnchor] constant:-8]]];
    return box;
}

@interface UMMPDSCToolsController ()
{
    ViewerController *_viewer;            // not retained; cleared when the viewer closes
    UMMPerfusionFilter *_filter;          // not retained (the plugin's filter lives as long as the app)

    NSTextField *_viewerLabel;

    NSButton *_maskBox, *_leakageBox, *_osvdBox, *_firstPassBox, *_clampBox;
    NSButton *_dceWholeBox, *_dceSmoothBox, *_autoRCBVBox, *_autoSRCBVBox;
    NSTextField *_srcbvSummary;
    NSPopUpButton *_preT1Popup, *_postT1Popup;
    NSMutableArray *_t1Viewers;           // NSValue (non-retained ViewerController), same order as the popups
    NSTextField *_dt1ThresholdField, *_dt1Result;
    NSButton *_dt1MaskBox, *_dt1RegisterBox, *_dt1ShadingBox, *_dt1CreateButton;
    NSPopUpButton *_clutPopup;
    NSTextField *_maskField, *_oiField;

    NSPopUpButton *_referencePopup;
    NSTableView *_table;
    NSMutableArray *_rows;                // NSDictionary per ROI
    NSMutableArray *_roiEntries;          // NSDictionary: roi, slice, movie, title
    double _referenceMean;
    NSString *_referenceTitle;

    NSPopUpButton *_aifPopup;
    NSTextField *_baselineField;
    NSTextField *_aifResult;
}
@end

@implementation UMMPDSCToolsController

+ (UMMPDSCToolsController *)sharedController
{
    static UMMPDSCToolsController *shared = nil;
    if (!shared) shared = [[UMMPDSCToolsController alloc] init];
    return shared;
}

- (id)init
{
    NSPanel *panel = [[[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 720, 990)
                                                 styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                           NSWindowStyleMaskResizable | NSWindowStyleMaskUtilityWindow
                                                   backing:NSBackingStoreBuffered defer:YES] autorelease];
    self = [super initWithWindow:panel];
    if (self) {
        [panel setTitle:@"UMMPerfusion DSC Tools"];
        // Stays above the viewers while you work in them; hidden only while IsiX is in the background.
        [panel setFloatingPanel:YES];
        [panel setLevel:NSFloatingWindowLevel];
        [panel setHidesOnDeactivate:YES];
        [panel setBecomesKeyOnlyIfNeeded:NO];
        [panel setCollectionBehavior:NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorMoveToActiveSpace];
        [panel setReleasedWhenClosed:NO];
        [panel setMinSize:NSMakeSize(700, 930)];
        [panel setDelegate:self];
        _rows = [[NSMutableArray alloc] init];
        _roiEntries = [[NSMutableArray alloc] init];
        _t1Viewers = [[NSMutableArray alloc] init];
        _referenceMean = NAN;
        [self buildInterface];
        [self loadSettings];
        [panel center];
        [panel setFrameAutosaveName:@"UMMPDSCToolsWindow"];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(viewerWillClose:)
                                                     name:OsirixCloseViewerNotification object:nil];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_rows release];
    [_roiEntries release];
    [_t1Viewers release];
    [_referenceTitle release];
    [super dealloc];
}

#pragma mark - Interface

- (void)buildInterface
{
    NSView *content = [[self window] contentView];

    _viewerLabel = UMMPLabel(@"No viewer");
    [_viewerLabel setLineBreakMode:NSLineBreakByTruncatingMiddle];
    [_viewerLabel setFont:[NSFont boldSystemFontOfSize:[NSFont smallSystemFontSize]]];
    NSButton *useFront = UMMPButton(@"Use Frontmost Viewer", self, @selector(useFrontmostViewer:));
    NSButton *curves = UMMPButton(@"Time Curves…", self, @selector(showCurves:));
    NSStackView *viewerRow = UMMPRow(@[UMMPLabel(@"Viewer:"), _viewerLabel, useFront, curves]);
    [_viewerLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    // Options
    _maskBox = UMMPCheckbox(@"Brain mask: skip pixels with baseline signal below", self, @selector(optionChanged:));
    _maskField = UMMPNumberField(@"10", 44); [_maskField setTarget:self]; [_maskField setAction:@selector(optionChanged:)];
    _leakageBox = UMMPCheckbox(@"Leakage correction (Boxerman–Weisskoff), with a K2 map", self, @selector(optionChanged:));
    _osvdBox = UMMPCheckbox(@"oSVD deconvolution (bolus-delay insensitive); maximum oscillation index", self, @selector(optionChanged:));
    _oiField = UMMPNumberField(@"0.095", 54); [_oiField setTarget:self]; [_oiField setAction:@selector(optionChanged:)];
    _firstPassBox = UMMPCheckbox(@"Blood volume from the first pass only (excludes recirculation)", self, @selector(optionChanged:));
    _clampBox = UMMPCheckbox(@"Keep pixels whose signal reaches zero in some frame (clamp to 1% of baseline)", self, @selector(optionChanged:));
    NSTextField *optionsNote = UMMPLabel(@"Used by Fast Deconvolution with the T2*-DSC tracer, from the next calculation on.");
    _dceWholeBox = UMMPCheckbox(@"Fit the whole slice within the brain mask, not only the tissue rectangle (slow)", self, @selector(optionChanged:));
    _dceSmoothBox = UMMPCheckbox(@"Smooth 3×3 before fitting (fewer outlier pixels, lower resolution)", self, @selector(optionChanged:));
    _autoRCBVBox = UMMPCheckbox(@"Create an rCBV map automatically (reference: ROI named “NAWM” or “ref”, else whole-brain median)", self, @selector(optionChanged:));
    _autoSRCBVBox = UMMPCheckbox(@"Create an sRCBV map automatically when an sRCBV calibration exists (no reference ROI needed)", self, @selector(optionChanged:));
    _clutPopup = [[[NSPopUpButton alloc] init] autorelease];
    [_clutPopup setControlSize:NSControlSizeSmall];
    [_clutPopup setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    [_clutPopup addItemsWithTitles:@[@"Rainbow2", @"Rainbow", @"Rainbow3", @"Perfusion", @"Jet", @"PPU Viridis", @"PPU Inferno", @"HotIron", @"None (grey)"]];
    [_clutPopup setTarget:self];
    [_clutPopup setAction:@selector(optionChanged:)];
    NSTextField *dceTitle = UMMPLabel(@"DCE pixel maps (compartment models, Modified Tofts):");
    [dceTitle setFont:[NSFont boldSystemFontOfSize:[NSFont smallSystemFontSize]]];
    [optionsNote setTextColor:[NSColor secondaryLabelColor]];
    NSStackView *options = [NSStackView stackViewWithViews:@[
        UMMPRow(@[_maskBox, _maskField, UMMPLabel(@"% of the bright end (99th percentile)")]),
        _leakageBox,
        UMMPRow(@[_osvdBox, _oiField]),
        _firstPassBox, _clampBox, _autoRCBVBox, _autoSRCBVBox, optionsNote, dceTitle, _dceWholeBox, _dceSmoothBox,
        UMMPRow(@[UMMPLabel(@"Colour table for new maps (DSC and DCE):"), _clutPopup])]];
    [options setOrientation:NSUserInterfaceLayoutOrientationVertical];
    [options setAlignment:NSLayoutAttributeLeading];
    [options setSpacing:5];

    // ROI statistics
    _referencePopup = [[[NSPopUpButton alloc] init] autorelease];
    [_referencePopup setControlSize:NSControlSizeSmall];
    [_referencePopup setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    [_referencePopup setTarget:self];
    [_referencePopup setAction:@selector(measure:)];
    NSStackView *refRow = UMMPRow(@[UMMPLabel(@"Reference ROI (e.g. contralateral NAWM):"), _referencePopup,
                                    UMMPButton(@"Refresh ROIs", self, @selector(refreshROIs:))]);

    _table = [[[NSTableView alloc] init] autorelease];
    [_table setUsesAlternatingRowBackgroundColors:YES];
    [_table setColumnAutoresizingStyle:NSTableViewUniformColumnAutoresizingStyle];
    [_table setDataSource:self];
    [_table setDelegate:self];
    NSArray *columns = @[@[@"name", @"ROI", @150], @[@"slice", @"Slice", @44], @[@"valid", @"Valid", @54],
                         @[@"excluded", @"Excl. (−1)", @64], @[@"mean", @"Mean", @70], @[@"sd", @"SD", @64],
                         @[@"median", @"Median", @70], @[@"min", @"Min", @60], @[@"max", @"Max", @60],
                         @[@"ratio", @"Mean ÷ ref", @74]];
    for (NSArray *c in columns) {
        NSTableColumn *col = [[[NSTableColumn alloc] initWithIdentifier:[c objectAtIndex:0]] autorelease];
        [[col headerCell] setStringValue:[c objectAtIndex:1]];
        [col setWidth:[[c objectAtIndex:2] doubleValue]];
        [[col dataCell] setFont:[NSFont monospacedDigitSystemFontOfSize:[NSFont smallSystemFontSize] weight:NSFontWeightRegular]];
        if (![[c objectAtIndex:0] isEqualToString:@"name"]) [[col dataCell] setAlignment:NSTextAlignmentRight];
        [_table addTableColumn:col];
    }
    NSScrollView *scroll = [[[NSScrollView alloc] init] autorelease];
    [scroll setDocumentView:_table];
    [scroll setHasVerticalScroller:YES];
    [scroll setHasHorizontalScroller:YES];
    [scroll setBorderType:NSBezelBorder];
    [[scroll heightAnchor] constraintGreaterThanOrEqualToConstant:150].active = YES;
    [scroll setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];

    NSTextField *statsNote = UMMPLabel(@"Pixels marked −1 (not computed: no signal, outside the mask or slice range) are left out.");
    [statsNote setTextColor:[NSColor secondaryLabelColor]];
    NSStackView *statsButtons = UMMPRow(@[UMMPButton(@"Measure", self, @selector(measure:)),
                                          UMMPButton(@"Create Normalized Map", self, @selector(createNormalizedMap:)),
                                          UMMPButton(@"Export CSV…", self, @selector(exportCSV:))]);
    NSStackView *stats = [NSStackView stackViewWithViews:@[refRow, scroll, statsNote, statsButtons]];
    [stats setOrientation:NSUserInterfaceLayoutOrientationVertical];
    [stats setAlignment:NSLayoutAttributeLeading];
    [stats setSpacing:6];
    [[scroll widthAnchor] constraintEqualToAnchor:[stats widthAnchor]].active = YES;

    // AIF
    _aifPopup = [[[NSPopUpButton alloc] init] autorelease];
    [_aifPopup setControlSize:NSControlSizeSmall];
    [_aifPopup setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    _baselineField = UMMPNumberField(@"10", 40);
    _aifResult = [NSTextField wrappingLabelWithString:@"Open the 4D DSC series in the viewer to check the arterial ROI or to search for AIF voxels on the current slice."];
    [_aifResult setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    [_aifResult setSelectable:YES];
    NSStackView *aifRow = UMMPRow(@[UMMPLabel(@"Arterial ROI:"), _aifPopup, UMMPLabel(@"Baseline frames:"), _baselineField]);
    NSStackView *aifButtons = UMMPRow(@[UMMPButton(@"Check AIF", self, @selector(checkAIF:)),
                                        UMMPButton(@"Find AIF Voxels on Current Slice", self, @selector(findAIF:))]);
    NSStackView *aif = [NSStackView stackViewWithViews:@[aifRow, aifButtons, _aifResult]];
    [aif setOrientation:NSUserInterfaceLayoutOrientationVertical];
    [aif setAlignment:NSLayoutAttributeLeading];
    [aif setSpacing:6];
    [[_aifResult widthAnchor] constraintEqualToAnchor:[aif widthAnchor]].active = YES;

    // Standardised rCBV
    _srcbvSummary = [NSTextField wrappingLabelWithString:@""];
    [_srcbvSummary setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    [_srcbvSummary setSelectable:YES];
    NSTextField *srcbvNote = [NSTextField wrappingLabelWithString:
        @"Calibration: add the blood-volume (or rCBV) map of each patient scanned with the same DSC protocol, ideally "
        @"with an ROI named “NAWM” (sets 1 = NAWM). Then any map can be standardised without an ROI. "
        @"Site-specific scale: not the IB Neuro scale; thresholds from papers do not transfer."];
    [srcbvNote setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    [srcbvNote setTextColor:[NSColor secondaryLabelColor]];
    NSStackView *srcbvButtons1 = UMMPRow(@[UMMPButton(@"Create sRCBV Map", self, @selector(createSRCBVMap:)),
                                           UMMPButton(@"Add Map to Calibration", self, @selector(addSRCBVCase:)),
                                           UMMPButton(@"Remove Last Case", self, @selector(removeLastSRCBVCase:)),
                                           UMMPButton(@"Reset…", self, @selector(resetSRCBV:))]);
    NSStackView *srcbvButtons2 = UMMPRow(@[UMMPButton(@"Export Calibration…", self, @selector(exportSRCBV:)),
                                           UMMPButton(@"Import Calibration…", self, @selector(importSRCBV:))]);
    NSStackView *srcbv = [NSStackView stackViewWithViews:@[_srcbvSummary, srcbvButtons1, srcbvButtons2, srcbvNote]];
    [srcbv setOrientation:NSUserInterfaceLayoutOrientationVertical];
    [srcbv setAlignment:NSLayoutAttributeLeading];
    [srcbv setSpacing:6];
    [[_srcbvSummary widthAnchor] constraintEqualToAnchor:[srcbv widthAnchor]].active = YES;
    [[srcbvNote widthAnchor] constraintEqualToAnchor:[srcbv widthAnchor]].active = YES;

    // ΔT1
    _preT1Popup = [[[NSPopUpButton alloc] init] autorelease];
    _postT1Popup = [[[NSPopUpButton alloc] init] autorelease];
    for (NSPopUpButton *b in @[_preT1Popup, _postT1Popup]) {
        [b setControlSize:NSControlSizeSmall];
        [b setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
        [[b widthAnchor] constraintLessThanOrEqualToConstant:230].active = YES;
    }
    _dt1ThresholdField = UMMPNumberField(@"0.2", 44);
    _dt1MaskBox = UMMPCheckbox(@"Mark pixels with ΔT1 above", self, NULL);
    [_dt1MaskBox setState:NSControlStateValueOn];
    _dt1Result = [NSTextField wrappingLabelWithString:
        @"Open the pre- and post-contrast T1 series (same sequence, same slices) in two viewers. "
        @"ΔT1 = post ÷ its median − pre ÷ its median, inside the head mask (brain-mask % above); "
        @"0 = no enhancement. Per-pair normalisation, not the IB Delta Suite scale."];
    [_dt1Result setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    [_dt1Result setTextColor:[NSColor secondaryLabelColor]];
    [_dt1Result setSelectable:YES];
    NSStackView *dt1Row1 = UMMPRow(@[UMMPLabel(@"Pre:"), _preT1Popup, UMMPLabel(@"Post:"), _postT1Popup,
                                     UMMPButton(@"Refresh", self, @selector(refreshT1Viewers:))]);
    _dt1CreateButton = UMMPButton(@"Create ΔT1 Map", self, @selector(createDeltaT1Map:));
    NSStackView *dt1Row2 = UMMPRow(@[_dt1MaskBox, _dt1ThresholdField, UMMPLabel(@"as ROI “Enhancing (ΔT1)”"), _dt1CreateButton]);
    _dt1RegisterBox = UMMPCheckbox(@"Align post onto pre (rigid: head movement between the scans)", self, NULL);
    _dt1ShadingBox = UMMPCheckbox(@"Correct slow intensity differences (coil shading)", self, NULL);
    [_dt1RegisterBox setState:NSControlStateValueOn];
    [_dt1ShadingBox setState:NSControlStateValueOn];
    NSStackView *dt1Row3 = UMMPRow(@[_dt1RegisterBox, _dt1ShadingBox]);
    NSStackView *dt1 = [NSStackView stackViewWithViews:@[dt1Row1, dt1Row3, dt1Row2, _dt1Result]];
    [dt1 setOrientation:NSUserInterfaceLayoutOrientationVertical];
    [dt1 setAlignment:NSLayoutAttributeLeading];
    [dt1 setSpacing:6];
    [[_dt1Result widthAnchor] constraintEqualToAnchor:[dt1 widthAnchor]].active = YES;

    NSBox *optionsBox = UMMPSection(@"Calculation options", options);
    NSBox *statsBox = UMMPSection(@"ROI statistics and normalisation (map viewer)", stats);
    NSBox *aifBox = UMMPSection(@"Arterial input function (4D series)", aif);
    NSBox *srcbvBox = UMMPSection(@"Standardised rCBV (sRCBV, map viewer)", srcbv);
    NSBox *dt1Box = UMMPSection(@"ΔT1 map (pre- and post-contrast T1)", dt1);

    NSStackView *main = [NSStackView stackViewWithViews:@[viewerRow, optionsBox, statsBox, srcbvBox, dt1Box, aifBox]];
    [main setOrientation:NSUserInterfaceLayoutOrientationVertical];
    [main setAlignment:NSLayoutAttributeLeading];
    [main setSpacing:10];
    [main setTranslatesAutoresizingMaskIntoConstraints:NO];
    [content addSubview:main];
    [NSLayoutConstraint activateConstraints:@[
        [[main leadingAnchor] constraintEqualToAnchor:[content leadingAnchor] constant:14],
        [[main trailingAnchor] constraintEqualToAnchor:[content trailingAnchor] constant:-14],
        [[main topAnchor] constraintEqualToAnchor:[content topAnchor] constant:12],
        [[main bottomAnchor] constraintEqualToAnchor:[content bottomAnchor] constant:-14],
        [[optionsBox widthAnchor] constraintEqualToAnchor:[main widthAnchor]],
        [[statsBox widthAnchor] constraintEqualToAnchor:[main widthAnchor]],
        [[aifBox widthAnchor] constraintEqualToAnchor:[main widthAnchor]],
        [[srcbvBox widthAnchor] constraintEqualToAnchor:[main widthAnchor]],
        [[dt1Box widthAnchor] constraintEqualToAnchor:[main widthAnchor]],
        [[viewerRow widthAnchor] constraintEqualToAnchor:[main widthAnchor]]]];
    [statsBox setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];
}

#pragma mark - Viewer

- (void)showForViewer:(ViewerController *)viewer filter:(UMMPerfusionFilter *)filter
{
    _filter = filter;
    [self setViewer:viewer];
    [self showWindow:nil];
    [[self window] makeKeyAndOrderFront:nil];
}

- (void)setViewer:(ViewerController *)viewer
{
    _viewer = viewer;
    NSString *title = [[_viewer window] title];
    [_viewerLabel setStringValue:_viewer ? (title ? title : @"Viewer") : @"No viewer"];
    [_rows removeAllObjects];
    [_table reloadData];
    [self refreshROIs:nil];
    [self refreshT1Viewers:nil];
}

- (void)useFrontmostViewer:(id)sender
{
    ViewerController *front = [ViewerController frontMostDisplayed2DViewer];
    if (front) [self setViewer:front];
}

- (void)showCurves:(id)sender
{
    [[UMMPCurvesController sharedController] showForViewer:_viewer ? _viewer : [ViewerController frontMostDisplayed2DViewer]];
}

- (void)viewerWillClose:(NSNotification *)note
{
    if ([note object] == _viewer) [self setViewer:nil];
    for (NSValue *v in _t1Viewers)
        if ([v nonretainedObjectValue] == [note object]) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self refreshT1Viewers:nil]; });
            break;
        }
}

- (BOOL)requireViewer
{
    if (_viewer) return YES;
    NSBeep();
    [_viewerLabel setStringValue:@"No viewer: click “Use Frontmost Viewer”"];
    return NO;
}

#pragma mark - Options

- (void)loadSettings
{
    UMMPDSCSettings s = UMMPDSCLoadSettings();
    [_maskBox setState:s.mask ? NSControlStateValueOn : NSControlStateValueOff];
    [_maskField setStringValue:[NSString stringWithFormat:@"%g", s.maskFraction * 100.0]];
    [_leakageBox setState:s.leakage ? NSControlStateValueOn : NSControlStateValueOff];
    [_osvdBox setState:s.oSVD ? NSControlStateValueOn : NSControlStateValueOff];
    [_oiField setStringValue:[NSString stringWithFormat:@"%g", s.oiThreshold]];
    [_firstPassBox setState:s.firstPass ? NSControlStateValueOn : NSControlStateValueOff];
    [_clampBox setState:s.clamp ? NSControlStateValueOn : NSControlStateValueOff];
    [_maskField setEnabled:s.mask];
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] persistentDomainForName:@"com.osirix.UMMPerfusion.DSC"];
    [_dceWholeBox setState:[[d objectForKey:@"dceWholeSlice"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff];
    [_dceSmoothBox setState:[[d objectForKey:@"dceSmooth"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff];
    id autoRCBV = [d objectForKey:@"autoRCBV"];
    [_autoRCBVBox setState:(autoRCBV ? [autoRCBV boolValue] : YES) ? NSControlStateValueOn : NSControlStateValueOff];
    id autoSRCBV = [d objectForKey:@"autoSRCBV"];
    [_autoSRCBVBox setState:(autoSRCBV ? [autoSRCBV boolValue] : YES) ? NSControlStateValueOn : NSControlStateValueOff];
    [_srcbvSummary setStringValue:UMMPSRCBVCalibrationSummary()];
    id clut = [d objectForKey:@"mapCLUT"];
    NSString *clutTitle = [clut isKindOfClass:[NSString class]] ? ([clut length] ? clut : @"None (grey)") : @"Rainbow2";
    if ([_clutPopup itemWithTitle:clutTitle]) [_clutPopup selectItemWithTitle:clutTitle];
    [_oiField setEnabled:s.oSVD];
}

- (void)optionChanged:(id)sender
{
    UMMPDSCSettings s = UMMPDSCLoadSettings();
    s.mask = ([_maskBox state] == NSControlStateValueOn);
    double fraction = [_maskField doubleValue] / 100.0;
    if (fraction >= 0.0 && fraction < 1.0) s.maskFraction = fraction;
    s.leakage = ([_leakageBox state] == NSControlStateValueOn);
    s.oSVD = ([_osvdBox state] == NSControlStateValueOn);
    double oi = [_oiField doubleValue];
    if (oi > 0.0 && oi < 1.0) s.oiThreshold = oi;
    s.firstPass = ([_firstPassBox state] == NSControlStateValueOn);
    s.clamp = ([_clampBox state] == NSControlStateValueOn);
    UMMPDSCSaveSettings(s);
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:
        [[NSUserDefaults standardUserDefaults] persistentDomainForName:@"com.osirix.UMMPerfusion.DSC"] ?: @{}];
    [d setObject:@([_dceWholeBox state] == NSControlStateValueOn) forKey:@"dceWholeSlice"];
    [d setObject:@([_dceSmoothBox state] == NSControlStateValueOn) forKey:@"dceSmooth"];
    [d setObject:@([_autoRCBVBox state] == NSControlStateValueOn) forKey:@"autoRCBV"];
    [d setObject:@([_autoSRCBVBox state] == NSControlStateValueOn) forKey:@"autoSRCBV"];
    NSString *clutTitle = [_clutPopup titleOfSelectedItem];
    [d setObject:([clutTitle hasPrefix:@"None"] ? @"" : clutTitle) forKey:@"mapCLUT"];
    [[NSUserDefaults standardUserDefaults] setPersistentDomain:d forName:@"com.osirix.UMMPerfusion.DSC"];
    [self loadSettings];
}

- (void)windowDidBecomeKey:(NSNotification *)note
{
    [self loadSettings];
}

#pragma mark - ΔT1

// Every open 2D viewer with one time frame (the T1 series), for the Pre / Post popups.
- (void)refreshT1Viewers:(id)sender
{
    NSString *pre = [[[_preT1Popup titleOfSelectedItem] copy] autorelease];
    NSString *post = [[[_postT1Popup titleOfSelectedItem] copy] autorelease];
    [_t1Viewers removeAllObjects];
    [_preT1Popup removeAllItems];
    [_postT1Popup removeAllItems];
    NSArray *viewers = [ViewerController getDisplayed2DViewers];
    for (ViewerController *v in viewers) {
        if ([v maxMovieIndex] > 1) continue;
        NSString *title = [[v window] title];
        if (![title length]) title = @"Viewer";
        NSString *unique = title;
        for (int k = 2; [_preT1Popup itemWithTitle:unique]; k++) unique = [NSString stringWithFormat:@"%@ (%d)", title, k];
        [_preT1Popup addItemWithTitle:unique];
        [_postT1Popup addItemWithTitle:unique];
        [_t1Viewers addObject:[NSValue valueWithNonretainedObject:v]];
    }
    if (pre && [_preT1Popup itemWithTitle:pre]) [_preT1Popup selectItemWithTitle:pre];
    if (post && [_postT1Popup itemWithTitle:post]) [_postT1Popup selectItemWithTitle:post];
    else if ([_postT1Popup numberOfItems] > 1 && [_postT1Popup indexOfSelectedItem] == [_preT1Popup indexOfSelectedItem])
        [_postT1Popup selectItemAtIndex:1];
}

- (ViewerController *)t1ViewerForPopup:(NSPopUpButton *)popup
{
    NSInteger i = [popup indexOfSelectedItem];
    if (i < 0 || i >= (NSInteger)[_t1Viewers count]) return nil;
    ViewerController *v = [[_t1Viewers objectAtIndex:i] nonretainedObjectValue];
    return [[ViewerController getDisplayed2DViewers] containsObject:v] ? v : nil;
}

// Same matrix, slices, position and orientation (within half a pixel). nil, or what differs.
static NSString *UMMPGeometryMismatch(ViewerController *a, ViewerController *b)
{
    NSArray *pa = [a pixList], *pb = [b pixList];
    if ([pa count] != [pb count])
        return [NSString stringWithFormat:@"%lu slices vs %lu slices", (unsigned long)[pa count], (unsigned long)[pb count]];
    for (NSUInteger s = 0; s < [pa count]; s++) {
        DCMPix *x = [pa objectAtIndex:s], *y = [pb objectAtIndex:s];
        if ([x pwidth] != [y pwidth] || [x pheight] != [y pheight])
            return [NSString stringWithFormat:@"matrix %ld×%ld vs %ld×%ld", [x pwidth], [x pheight], [y pwidth], [y pheight]];
        double tol = 0.5 * MIN([x pixelSpacingX], [x pixelSpacingY]);
        if (!(tol > 0)) tol = 0.5;
        double d = sqrt(pow([x originX] - [y originX], 2) + pow([x originY] - [y originY], 2) + pow([x originZ] - [y originZ], 2));
        if (d > tol) return [NSString stringWithFormat:@"slice %lu is %.1f mm apart", (unsigned long)s + 1, d];
        double ox[9], oy[9];
        [x orientationDouble:ox];
        [y orientationDouble:oy];
        for (int k = 0; k < 6; k++)
            if (fabs(ox[k] - oy[k]) > 1e-3) return [NSString stringWithFormat:@"slice %lu has another orientation", (unsigned long)s + 1];
    }
    return nil;
}


// YES when the middle slice of the viewer still holds the ΔT1 values.
static BOOL UMMPDeltaT1Intact(ViewerController *out, NSData *data)
{
    NSArray *pl = [out pixList];
    if (![pl count]) return NO;
    NSUInteger m = [pl count] / 2;
    long off = 0;
    for (NSUInteger s = 0; s < m; s++) off += (long)[[pl objectAtIndex:s] pwidth] * [[pl objectAtIndex:s] pheight];
    DCMPix *mid = [pl objectAtIndex:m];
    long size = (long)[mid pwidth] * [mid pheight];
    const float *d = (const float *)[data bytes];
    float *img = [mid fImage];
    if (!img || (off + size) * (long)sizeof(float) > (long)[data length]) return NO;
    long differ = 0;
    for (long i = 0; i < size; i++) if (fabsf(img[i] - d[off + i]) > 1e-4f) differ++;
    return differ == 0;
}

// A new 2D viewer with the geometry of `source` and the pixels of `volume` (count floats,
// malloc'ed; the viewer's volume data takes ownership). nil and *error on failure.
static ViewerController *UMMPNewViewerFromVolume(ViewerController *source, float *volume, long count, NSString **error)
{
    NSArray *srcPix = [source pixList];
    NSArray *srcFiles = [source fileList];
    long total = 0;
    for (DCMPix *p in srcPix) total += (long)[p pwidth] * [p pheight];
    if (![srcPix count] || total != count) {
        if (error) *error = @"The source series has changed (slice count or matrix).";
        free(volume);
        return nil;
    }
    NSMutableArray *pixList = [NSMutableArray arrayWithCapacity:[srcPix count]];
    NSMutableArray *fileList = [NSMutableArray arrayWithCapacity:[srcPix count]];
    long offset = 0;
    for (NSUInteger i = 0; i < [srcPix count]; i++) {
        DCMPix *p = [srcPix objectAtIndex:i];
        DCMPix *c = [[p copy] autorelease];
        [c setfImage:volume + offset];
        offset += (long)[p pwidth] * [p pheight];
        [pixList addObject:c];
        id file = (i < [srcFiles count]) ? [srcFiles objectAtIndex:i] : [srcFiles lastObject];
        if (file) [fileList addObject:file];
    }
    if ([fileList count] != [pixList count]) {
        if (error) *error = @"The source series has no file list.";
        free(volume);
        return nil;
    }
    NSData *data = [[[NSData alloc] initWithBytesNoCopy:volume length:sizeof(float) * (size_t)count freeWhenDone:YES] autorelease];
    ViewerController *v = [ViewerController newWindow:pixList :fileList :data];
    if (!v && error) *error = @"IsiX did not open a new viewer.";
    return v;
}

static float *UMMPVolumeCopy(ViewerController *v, long *count)
{
    long total = 0;
    for (DCMPix *pix in [v pixList]) total += (long)[pix pwidth] * [pix pheight];
    float *out = (float *)malloc(sizeof(float) * (size_t)(total > 0 ? total : 1));
    long n = 0;
    for (DCMPix *pix in [v pixList]) {
        long size = (long)[pix pwidth] * [pix pheight];
        float *img = [pix fImage];
        if (img) memcpy(out + n, img, sizeof(float) * (size_t)size);
        else for (long i = 0; i < size; i++) out[n + i] = NAN;
        n += size;
    }
    *count = n;
    return out;
}

- (void)createDeltaT1Map:(id)sender
{
    [self refreshT1Viewers:nil];
    ViewerController *pre = [self t1ViewerForPopup:_preT1Popup], *post = [self t1ViewerForPopup:_postT1Popup];
    if (!pre || !post || pre == post) {
        [self showMessage:@"Choose two series" text:@"Open the pre- and the post-contrast T1 series in two viewers and choose them as Pre and Post."];
        return;
    }
    if (!_filter) return;
    // IsiX/Horos load a series in the background: wait until every slice is in memory, or the
    // copies below read (and the new viewer later shows) the file contents instead of ours.
    [pre checkEverythingLoaded];
    [post checkEverythingLoaded];
    NSString *mismatch = UMMPGeometryMismatch(pre, post);
    if (mismatch) {
        [self showMessage:@"The two series do not overlap"
                     text:[NSString stringWithFormat:@"Pre and post must have the same matrix, slices and position (%@). "
                           @"Use the same 3D T1 sequence before and after contrast, or resample the post series onto the pre series first.", mismatch]];
        return;
    }
    long n = 0, m = 0;
    float *a = UMMPVolumeCopy(pre, &n), *b = UMMPVolumeCopy(post, &m);
    NSArray *prePix = [pre pixList];
    DCMPix *p0 = [prePix objectAtIndex:0];
    long nx = [p0 pwidth], ny = [p0 pheight], nz = (long)[prePix count];
    double dx = [p0 pixelSpacingX] > 0 ? [p0 pixelSpacingX] : 1.0, dy = [p0 pixelSpacingY] > 0 ? [p0 pixelSpacingY] : 1.0;
    double dz = 1.0;
    if (nz > 1) {
        DCMPix *p1 = [prePix objectAtIndex:1];
        dz = sqrt(pow([p1 originX] - [p0 originX], 2) + pow([p1 originY] - [p0 originY], 2) + pow([p1 originZ] - [p0 originZ], 2));
        if (!(dz > 0)) dz = [p0 sliceThickness] > 0 ? [p0 sliceThickness] : 1.0;
    }
    BOOL doRegister = ([_dt1RegisterBox state] == NSControlStateValueOn);
    BOOL doShading = ([_dt1ShadingBox state] == NSControlStateValueOn);
    double maskFraction = UMMPDCEMaskFraction();
    if (n != m || n != nx * ny * nz) {
        free(a); free(b);
        [self showMessage:@"No ΔT1 map" text:@"The two series do not have the same number of pixels."];
        return;
    }

    // The alignment takes a few seconds: computed in the background, the viewer is made after.
    [_dt1CreateButton setEnabled:NO];
    [_dt1Result setTextColor:[NSColor labelColor]];
    [_dt1Result setStringValue:doRegister ? @"Aligning post onto pre and computing ΔT1…" : @"Computing ΔT1…"];
    NSDate *startTime = [NSDate date];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        float *d = (float *)malloc(sizeof(float) * (size_t)(n > 0 ? n : 1));
        UMMPDT1Report rep;
        memset(&rep, 0, sizeof(rep));
        int ok = d && UMMPDT1Pipeline(a, b, nx, ny, nz, dx, dy, dz, doRegister, doShading, maskFraction, d, &rep);
        free(a); free(b);
        dispatch_async(dispatch_get_main_queue(), ^{
            [_dt1CreateButton setEnabled:YES];
            if (!ok) {
                free(d);
                [_dt1Result setStringValue:@"No ΔT1 map."];
                [self showMessage:@"No ΔT1 map" text:@"The pre series has too few pixels above the head-mask threshold, or no signal."];
                return;
            }
            NSString *steps = [NSString stringWithFormat:@"%@%@ (%.0f s)",
                doRegister ? [NSString stringWithFormat:@"post aligned: rotation %.1f° %.1f° %.1f°, shift %.1f %.1f %.1f mm, local r %.2f; ",
                              rep.transform.rx * 180 / M_PI, rep.transform.ry * 180 / M_PI, rep.transform.rz * 180 / M_PI,
                              rep.transform.tx, rep.transform.ty, rep.transform.tz, rep.correlation] : @"not aligned; ",
                doShading ? [NSString stringWithFormat:@"shading corrected (%ld blocks)", rep.shadingBlocks] : @"no shading correction",
                -[startTime timeIntervalSinceNow]];
            [self finishDeltaT1:d count:n pre:pre normalisation:rep.normalisation steps:steps];
        });
    });
}

- (void)finishDeltaT1:(float *)d count:(long)n pre:(ViewerController *)pre normalisation:(UMMPDT1Result)r steps:(NSString *)steps
{
    if (![[ViewerController getDisplayed2DViewers] containsObject:pre]) {
        free(d);
        [_dt1Result setStringValue:@"The pre-contrast viewer was closed: no ΔT1 map."];
        return;
    }
    // A new viewer built from copies of the pre series' slices, each pointing into our own ΔT1
    // volume (the OsiriX way of creating a result series). duplicateViewer: is not used: IsiX
    // fills a duplicated viewer asynchronously with the source pixels, which replaced the ΔT1 values.
    NSData *dt1Data = [NSData dataWithBytes:d length:sizeof(float) * (size_t)n];
    NSString *buildError = nil;
    ViewerController *out = UMMPNewViewerFromVolume(pre, d, n, &buildError);
    if (!out) {   // d was freed by UMMPNewViewerFromVolume
        [self showMessage:@"No ΔT1 viewer" text:buildError ?: @"IsiX did not open a new viewer."];
        return;
    }
    NSString *check = UMMPDeltaT1Intact(out, dt1Data) ? @"viewer holds ΔT1" : @"viewer does NOT hold ΔT1";
    NSString *name = @"ΔT1 (post ÷ median − pre ÷ median)";
    if ([[out pixList] count]) [[[out pixList] objectAtIndex:0] setGeneratedName:name];

    NSString *maskText = @"";
    double threshold = [_dt1ThresholdField doubleValue];
    if ([_dt1MaskBox state] == NSControlStateValueOn && threshold > 0) {
        long marked = 0; double volume = 0;
        NSString *roiName = [NSString stringWithFormat:@"Enhancing (ΔT1 > %g)", threshold];
        long offset = 0;
        const float *dv = (const float *)[dt1Data bytes];
        NSArray *pixList = [out pixList];
        for (NSUInteger s = 0; s < [pixList count]; s++) {
            DCMPix *pix = [pixList objectAtIndex:s];
            long w = [pix pwidth], h = [pix pheight], size = w * h, here = 0;
            unsigned char *mask = (unsigned char *)calloc((size_t)size, 1);
            for (long i = 0; i < size; i++) if (dv[offset + i] > threshold) { mask[i] = 255; here++; }
            offset += size;
            if (here) {
                ROI *roi = [[[ROI alloc] initWithTexture:mask textWidth:(int)w textHeight:(int)h textName:roiName
                                               positionX:0 positionY:0
                                                spacingX:[pix pixelSpacingX] spacingY:[pix pixelSpacingY]
                                             imageOrigin:NSMakePoint([pix originX], [pix originY])] autorelease];
                RGBColor orange = {65535, 32768, 0};
                [roi setColor:orange];
                [roi setPix:pix];
                [roi setCurView:[out imageView]];
                NSArray *rois = [out roiList:0];
                if (s < [rois count]) [[rois objectAtIndex:s] addObject:roi];
                marked += here;
                double thick = [pix sliceInterval] > 0 ? [pix sliceInterval] : [pix sliceThickness];
                volume += here * [pix pixelSpacingX] * [pix pixelSpacingY] * thick / 1000.0;
            }
            free(mask);
        }
        maskText = marked
            ? [NSString stringWithFormat:@" ROI “%@”: %ld pixels, %.2f ml (raw threshold: includes vessels, choroid plexus and motion rims — edit the ROI).", roiName, marked, volume]
            : [NSString stringWithFormat:@" No pixel above %g.", threshold];
    }
    // d is owned by the viewer's volume now (freed with it).
    // Redraw from the new values: the copied slices keep the 8-bit display image of the T1 series.
    for (DCMPix *pix in [out pixList]) [pix changeWLWW:0.25 :1.0];
    [out setWL:0.25 WW:1.0];
    [out refresh];
    [out needsDisplayUpdate];
    NSString *summary = [NSString stringWithFormat:@"ΔT1 map created: %@. Medians pre %.4g, post %.4g; head mask %ld pixels (pre > %.4g).%@",
                         steps, r.medianPre, r.medianPost, r.maskPixels, r.maskThreshold, maskText];
    [_dt1Result setTextColor:[NSColor labelColor]];
    [_dt1Result setStringValue:[NSString stringWithFormat:@"%@ [check: %@]", summary, check]];
    NSLog(@"UMMP ΔT1: %@", [_dt1Result stringValue]);

    // Check once more after IsiX has settled the new viewer.
    NSTextField *resultField = _dt1Result;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (![[ViewerController getDisplayed2DViewers] containsObject:out]) return;
        if (!UMMPDeltaT1Intact(out, dt1Data))
            [resultField setStringValue:[NSString stringWithFormat:@"%@ [after 2 s: viewer does NOT hold ΔT1 any more]", summary]];
    });
}

#pragma mark - Standardised rCBV

- (void)showMessage:(NSString *)title text:(NSString *)text
{
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    [alert setMessageText:title];
    [alert setInformativeText:text ?: @""];
    [alert beginSheetModalForWindow:[self window] completionHandler:nil];
}

// The viewer must be a map (one time frame), not the 4D DSC series.
- (BOOL)requireMapViewer
{
    if (![self requireViewer]) return NO;
    if ([_viewer maxMovieIndex] > 1) {
        [self showMessage:@"Choose a map" text:@"The viewer shows a 4D series. Bring the blood-volume (Volume of Distribution) or rCBV map to the front and click “Use Frontmost Viewer”."];
        return NO;
    }
    return YES;
}

- (NSString *)mapTitle
{
    NSString *t = [[[_viewer pixList] objectAtIndex:0] generatedName];
    NSString *w = [[_viewer window] title];
    if ([w length] && [t length]) return [NSString stringWithFormat:@"%@ — %@", w, t];
    return [w length] ? w : ([t length] ? t : @"Map");
}

- (void)refreshSRCBVSummary
{
    [_srcbvSummary setStringValue:UMMPSRCBVCalibrationSummary()];
}

- (void)createSRCBVMap:(id)sender
{
    if (![self requireMapViewer] || !_filter) return;
    NSString *error = nil;
    if (!UMMPSRCBVCreateMap(_filter, _viewer, &error))
        [self showMessage:@"No sRCBV map" text:error];
}

- (void)addSRCBVCase:(id)sender
{
    if (![self requireMapViewer]) return;
    NSString *error = UMMPSRCBVAddCase(_viewer, nil, [self mapTitle]);
    if (error) [self showMessage:@"Not added" text:error];
    [self refreshSRCBVSummary];
}

- (void)removeLastSRCBVCase:(id)sender
{
    NSMutableArray *cases = [NSMutableArray arrayWithArray:UMMPSRCBVCases()];
    if (![cases count]) { NSBeep(); return; }
    NSLog(@"UMMP sRCBV: case removed (%@)", [[cases lastObject] objectForKey:@"title"]);
    [cases removeLastObject];
    UMMPSRCBVSaveCases(cases);
    [self refreshSRCBVSummary];
}

- (void)resetSRCBV:(id)sender
{
    if (![UMMPSRCBVCases() count]) { NSBeep(); return; }
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    [alert setMessageText:@"Delete the sRCBV calibration?"];
    [alert setInformativeText:@"All calibration cases are removed. Export the calibration first if you may need it again."];
    [alert addButtonWithTitle:@"Delete"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:[self window] completionHandler:^(NSModalResponse r) {
        if (r != NSAlertFirstButtonReturn) return;
        UMMPSRCBVSaveCases(@[]);
        [self refreshSRCBVSummary];
    }];
}

- (void)exportSRCBV:(id)sender
{
    NSArray *cases = UMMPSRCBVCases();
    if (![cases count]) { NSBeep(); return; }
    NSSavePanel *panel = [NSSavePanel savePanel];
    [panel setNameFieldStringValue:@"UMMPerfusion sRCBV calibration.plist"];
    [panel beginSheetModalForWindow:[self window] completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSDictionary *file = @{@"format": @"UMMPerfusion sRCBV calibration", @"version": @1,
                               @"landmarkPercentiles": @[@1, @10, @20, @30, @40, @50, @60, @70, @80, @90, @99.8],
                               @"cases": cases};
        NSError *err = nil;
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:file format:NSPropertyListXMLFormat_v1_0 options:0 error:&err];
        if (!data || ![data writeToURL:[panel URL] options:NSDataWritingAtomic error:&err])
            [self showMessage:@"Export failed" text:[err localizedDescription]];
    }];
}

- (void)importSRCBV:(id)sender
{
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    [panel setAllowsMultipleSelection:NO];
    [panel beginSheetModalForWindow:[self window] completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSData *data = [NSData dataWithContentsOfURL:[panel URL]];
        id file = data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL] : nil;
        NSArray *imported = [file isKindOfClass:[NSDictionary class]] ? [file objectForKey:@"cases"] : nil;
        NSMutableArray *valid = [NSMutableArray array];
        for (id c in [imported isKindOfClass:[NSArray class]] ? imported : @[]) {
            NSArray *lm = [c isKindOfClass:[NSDictionary class]] ? [c objectForKey:@"landmarks"] : nil;
            if ([lm isKindOfClass:[NSArray class]] && [lm count] == UMMP_SRCBV_LANDMARKS) [valid addObject:c];
        }
        if (![valid count]) {
            [self showMessage:@"Nothing imported" text:@"The file is not an UMMPerfusion sRCBV calibration, or it has no case."];
            return;
        }
        // The sheet of the open panel must be gone before the next one.
        dispatch_async(dispatch_get_main_queue(), ^{
            NSArray *current = UMMPSRCBVCases();
            if (![current count]) {
                UMMPSRCBVSaveCases(valid);
                [self refreshSRCBVSummary];
                return;
            }
            NSAlert *alert = [[[NSAlert alloc] init] autorelease];
            [alert setMessageText:[NSString stringWithFormat:@"Import %lu case%@", (unsigned long)[valid count], [valid count] == 1 ? @"" : @"s"]];
            [alert setInformativeText:[NSString stringWithFormat:@"The current calibration has %lu case%@.",
                                       (unsigned long)[current count], [current count] == 1 ? @"" : @"s"]];
            [alert addButtonWithTitle:@"Replace"];
            [alert addButtonWithTitle:@"Add to Current"];
            [alert addButtonWithTitle:@"Cancel"];
            [alert beginSheetModalForWindow:[self window] completionHandler:^(NSModalResponse r) {
                if (r == NSAlertFirstButtonReturn) UMMPSRCBVSaveCases(valid);
                else if (r == NSAlertSecondButtonReturn) UMMPSRCBVSaveCases([current arrayByAddingObjectsFromArray:valid]);
                else return;
                [self refreshSRCBVSummary];
            }];
        });
    }];
}

#pragma mark - ROIs

// Every ROI of the viewer: those of the frame shown for map viewers, those of all frames for 4D series.
- (void)refreshROIs:(id)sender
{
    NSString *previousRef = [[[_referencePopup titleOfSelectedItem] copy] autorelease];
    NSString *previousAIF = [[[_aifPopup titleOfSelectedItem] copy] autorelease];
    [_roiEntries removeAllObjects];
    [_referencePopup removeAllItems];
    [_aifPopup removeAllItems];
    if (!_viewer) return;

    long movies = [_viewer maxMovieIndex];
    NSMutableSet *seen = [NSMutableSet set];
    for (long m = 0; m < movies; m++) {
        NSArray *perSlice = [_viewer roiList:m];
        for (NSUInteger s = 0; s < [perSlice count]; s++) {
            for (ROI *roi in [perSlice objectAtIndex:s]) {
                NSValue *key = [NSValue valueWithNonretainedObject:roi];
                if ([seen containsObject:key]) continue;
                [seen addObject:key];
                NSString *name = [roi name] ? [roi name] : @"Unnamed";
                NSString *title = (movies > 1)
                    ? [NSString stringWithFormat:@"%@ — slice %lu, frame %ld", name, (unsigned long)s + 1, m + 1]
                    : [NSString stringWithFormat:@"%@ — slice %lu", name, (unsigned long)s + 1];
                [_roiEntries addObject:@{@"roi": roi, @"slice": @(s), @"movie": @(m), @"title": title, @"name": name}];
            }
        }
    }
    for (NSDictionary *e in _roiEntries) {
        [_referencePopup addItemWithTitle:[e objectForKey:@"title"]];
        [_aifPopup addItemWithTitle:[e objectForKey:@"title"]];
    }
    if (previousRef && [_referencePopup itemWithTitle:previousRef]) [_referencePopup selectItemWithTitle:previousRef];
    if (previousAIF && [_aifPopup itemWithTitle:previousAIF]) [_aifPopup selectItemWithTitle:previousAIF];
    else {
        for (NSDictionary *e in _roiEntries)
            if ([[[e objectForKey:@"name"] lowercaseString] rangeOfString:@"aif"].location != NSNotFound ||
                [[[e objectForKey:@"name"] lowercaseString] rangeOfString:@"arter"].location != NSNotFound) {
                [_aifPopup selectItemWithTitle:[e objectForKey:@"title"]];
                break;
            }
    }
}

- (NSDictionary *)entryForPopup:(NSPopUpButton *)popup
{
    NSInteger i = [popup indexOfSelectedItem];
    if (i < 0 || i >= (NSInteger)[_roiEntries count]) return nil;
    return [_roiEntries objectAtIndex:i];
}

// Statistics of the pixels of a ROI on the frame shown, -1 and non-finite values left out.
- (NSMutableDictionary *)statisticsForEntry:(NSDictionary *)entry
{
    ROI *roi = [entry objectForKey:@"roi"];
    NSUInteger slice = [[entry objectForKey:@"slice"] unsignedIntegerValue];
    long movie = [_viewer maxMovieIndex] > 1 ? [_viewer curMovieIndex] : 0;
    NSArray *pixList = [_viewer pixList:movie];
    if (slice >= [pixList count]) return nil;
    DCMPix *pix = [pixList objectAtIndex:slice];

    long count = 0;
    float *values = [pix getROIValue:&count :roi :NULL];
    float *valid = (float *)malloc(sizeof(float) * (size_t)MAX(count, 1));
    long n = 0;
    for (long i = 0; i < count; i++)
        if (isfinite(values[i]) && values[i] != UMMP_NOT_COMPUTED) valid[n++] = values[i];
    if (values) free(values);

    NSMutableDictionary *row = [NSMutableDictionary dictionary];
    [row setObject:[entry objectForKey:@"name"] forKey:@"name"];
    [row setObject:@(slice + 1) forKey:@"slice"];
    [row setObject:@(n) forKey:@"valid"];
    [row setObject:@(count - n) forKey:@"excluded"];
    if (n > 0) {
        double sum = 0, sum2 = 0;
        for (long i = 0; i < n; i++) sum += valid[i];
        double mean = sum / n;
        for (long i = 0; i < n; i++) sum2 += (valid[i] - mean) * (valid[i] - mean);
        qsort(valid, (size_t)n, sizeof(float), UMMPCompareFloats);
        double median = (n % 2) ? valid[n / 2] : 0.5 * (valid[n / 2 - 1] + valid[n / 2]);
        [row setObject:@(mean) forKey:@"mean"];
        [row setObject:@(n > 1 ? sqrt(sum2 / (n - 1)) : 0.0) forKey:@"sd"];
        [row setObject:@(median) forKey:@"median"];
        [row setObject:@(valid[0]) forKey:@"min"];
        [row setObject:@(valid[n - 1]) forKey:@"max"];
    }
    free(valid);
    return row;
}

- (void)measure:(id)sender
{
    if (![self requireViewer]) return;
    [self refreshROIsKeepingSelection];
    [_rows removeAllObjects];
    _referenceMean = NAN;
    [_referenceTitle release]; _referenceTitle = nil;

    NSDictionary *reference = [self entryForPopup:_referencePopup];
    if (reference) {
        NSDictionary *r = [self statisticsForEntry:reference];
        if ([r objectForKey:@"mean"]) {
            _referenceMean = [[r objectForKey:@"mean"] doubleValue];
            _referenceTitle = [[reference objectForKey:@"title"] copy];
        }
    }
    for (NSDictionary *e in _roiEntries) {
        NSMutableDictionary *row = [self statisticsForEntry:e];
        if (!row) continue;
        if ([row objectForKey:@"mean"] && isfinite(_referenceMean) && _referenceMean != 0)
            [row setObject:@([[row objectForKey:@"mean"] doubleValue] / _referenceMean) forKey:@"ratio"];
        if (e == reference) [row setObject:@YES forKey:@"isReference"];
        [_rows addObject:row];
    }
    [_table reloadData];
}

- (void)refreshROIsKeepingSelection
{
    [self refreshROIs:nil];
}

- (void)createNormalizedMap:(id)sender
{
    if (![self requireViewer]) return;
    [self measure:nil];
    if (!(isfinite(_referenceMean) && _referenceMean != 0)) {
        NSAlert *alert = [[[NSAlert alloc] init] autorelease];
        [alert setMessageText:@"No usable reference"];
        [alert setInformativeText:@"Draw a reference ROI (e.g. contralateral normal-appearing white matter) on the map, choose it as the reference, and try again. It must contain pixels that are not −1."];
        [alert beginSheetModalForWindow:[self window] completionHandler:nil];
        return;
    }
    if (!_filter) return;
    ViewerController *source = _viewer;
    ViewerController *normalized = [_filter duplicateViewer:source deleteROIs:NO];
    if (!normalized) return;
    for (DCMPix *pix in [normalized pixList]) {
        float *image = [pix fImage];
        long n = (long)[pix pwidth] * [pix pheight];
        for (long i = 0; i < n; i++) {
            if (!isfinite(image[i]) || image[i] == UMMP_NOT_COMPUTED) image[i] = UMMP_NOT_COMPUTED;
            else image[i] = (float)(image[i] / _referenceMean);
        }
    }
    NSString *sourceName = [[[source pixList] objectAtIndex:0] generatedName];
    if (![sourceName length]) sourceName = [[source window] title];
    NSString *name = [NSString stringWithFormat:@"%@ ÷ %@ (reference mean %.4g)", sourceName ? sourceName : @"Map",
                      _referenceTitle, _referenceMean];
    [[[normalized pixList] objectAtIndex:0] setGeneratedName:name];
    [normalized needsDisplayUpdate];
    [normalized setWL:1.0 WW:2.0];
}

- (void)exportCSV:(id)sender
{
    if (![_rows count]) [self measure:nil];
    if (![_rows count]) { NSBeep(); return; }
    NSSavePanel *panel = [NSSavePanel savePanel];
    [panel setNameFieldStringValue:@"UMMPerfusion ROI statistics.csv"];
    [panel beginSheetModalForWindow:[self window] completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSMutableString *csv = [NSMutableString string];
        NSString *viewerTitle = [[_viewerLabel stringValue] stringByReplacingOccurrencesOfString:@"\"" withString:@"'"];
        [csv appendFormat:@"# Viewer: \"%@\"\n", viewerTitle];
        if (_referenceTitle) [csv appendFormat:@"# Reference: \"%@\", mean %.6g\n", _referenceTitle, _referenceMean];
        [csv appendString:@"# Pixels equal to -1 (not computed) excluded\n"];
        [csv appendString:@"roi,slice,valid_pixels,excluded_pixels,mean,sd,median,min,max,mean_over_reference,is_reference\n"];
        for (NSDictionary *r in _rows) {
            NSString *(^num)(NSString *) = ^NSString *(NSString *key) {
                id v = [r objectForKey:key];
                return v ? [NSString stringWithFormat:@"%.6g", [v doubleValue]] : @"";
            };
            [csv appendFormat:@"\"%@\",%@,%@,%@,%@,%@,%@,%@,%@,%@,%@\n",
             [[r objectForKey:@"name"] stringByReplacingOccurrencesOfString:@"\"" withString:@"'"],
             [r objectForKey:@"slice"], [r objectForKey:@"valid"], [r objectForKey:@"excluded"],
             num(@"mean"), num(@"sd"), num(@"median"), num(@"min"), num(@"max"), num(@"ratio"),
             [r objectForKey:@"isReference"] ? @"yes" : @""];
        }
        NSError *error = nil;
        if (![csv writeToURL:[panel URL] atomically:YES encoding:NSUTF8StringEncoding error:&error])
            [[NSAlert alertWithError:error] runModal];
    }];
}

#pragma mark - Table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    return (NSInteger)[_rows count];
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
    NSDictionary *r = [_rows objectAtIndex:row];
    NSString *key = [column identifier];
    id v = [r objectForKey:key];
    if ([key isEqualToString:@"name"])
        return [r objectForKey:@"isReference"] ? [NSString stringWithFormat:@"%@ (ref)", v] : v;
    if (!v) return @"–";
    if ([key isEqualToString:@"slice"] || [key isEqualToString:@"valid"] || [key isEqualToString:@"excluded"]) return v;
    return [NSString stringWithFormat:@"%.4g", [v doubleValue]];
}

#pragma mark - AIF

- (int)baselineFramesForFrames:(int)frames
{
    int bl = [_baselineField intValue];
    if (bl < 1) bl = 1;
    if (bl > frames - 2) bl = frames - 2;
    return bl;
}

- (BOOL)require4D
{
    if (![self requireViewer]) return NO;
    if ([_viewer maxMovieIndex] < 4) {
        [_aifResult setStringValue:@"This needs the 4D DSC series (several time frames) in the viewer, not a map."];
        return NO;
    }
    return YES;
}

- (void)checkAIF:(id)sender
{
    if (![self require4D]) return;
    [self refreshROIsKeepingSelection];
    NSDictionary *entry = [self entryForPopup:_aifPopup];
    if (!entry) { [_aifResult setStringValue:@"Draw an ROI in an artery first, then choose it above."]; return; }
    ROI *roi = [entry objectForKey:@"roi"];
    NSUInteger slice = [[entry objectForKey:@"slice"] unsignedIntegerValue];
    int frames = [_viewer maxMovieIndex];
    int bl = [self baselineFramesForFrames:frames];

    double *meanCurve = (double *)calloc((size_t)frames, sizeof(double));
    float **pixelValues = (float **)calloc((size_t)frames, sizeof(float *));
    long pixels = -1;
    BOOL consistent = YES;
    for (int t = 0; t < frames; t++) {
        DCMPix *pix = [[_viewer pixList:t] objectAtIndex:slice];
        float mean = 0;
        [pix computeROI:roi :&mean :NULL :NULL :NULL :NULL];
        meanCurve[t] = mean;
        long count = 0;
        pixelValues[t] = [pix getROIValue:&count :roi :NULL];
        if (pixels < 0) pixels = count;
        else if (count != pixels) consistent = NO;
    }

    double s0 = 0;
    for (int t = 0; t < bl; t++) s0 += meanCurve[t];
    s0 /= bl;
    double *c = (double *)calloc((size_t)frames, sizeof(double));
    int peakFrame = bl;
    for (int t = 0; t < frames; t++) {
        c[t] = UMMPDSCConcentrationValue(meanCurve[t], s0, YES);
        if (t >= bl && c[t] > c[peakFrame]) peakFrame = t;
    }
    double peak = c[peakFrame];
    int arrival = -1;
    for (int t = bl; t <= peakFrame; t++) if (c[t] > 0.1 * peak) { arrival = t; break; }
    int left = peakFrame, right = peakFrame;
    while (left > 0 && c[left - 1] >= 0.5 * peak) left--;
    while (right < frames - 1 && c[right + 1] >= 0.5 * peak) right++;
    int fwhm = right - left + 1;

    long clipped = 0;
    if (consistent && pixels > 0) {
        for (long i = 0; i < pixels; i++) {
            double b = 0;
            for (int t = 0; t < bl; t++) b += pixelValues[t][i];
            b /= bl;
            if (!(b > 0) || pixelValues[peakFrame][i] / b < 0.05) clipped++;
        }
    }

    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"%@: %ld pixels, baseline signal %.4g.\n", [entry objectForKey:@"title"], pixels, s0];
    [text appendFormat:@"Peak ΔR2*·TE %.2f (signal down to %.0f%% of baseline) at frame %d; arrival frame %d; width at half maximum %d frames.\n",
     peak, 100.0 * exp(-peak), peakFrame + 1, arrival + 1, fwhm];
    if (consistent && pixels > 0)
        [text appendFormat:@"Pixels below 5%% of their baseline at the peak (saturated): %ld (%.0f%%).\n", clipped, 100.0 * clipped / pixels];

    NSMutableArray *warnings = [NSMutableArray array];
    if (pixels > 0 && consistent && clipped > 0.1 * pixels)
        [warnings addObject:@"the signal saturates in many pixels at the bolus peak: the AIF peak is cut off and all maps are biased. Use a smaller artery, or voxels beside it."];
    if (exp(-peak) > 0.7)
        [warnings addObject:@"weak signal drop for an artery: the ROI may be mostly tissue (partial volume). Move it onto the vessel."];
    if (arrival < 0 || arrival < bl)
        [warnings addObject:@"the bolus arrives before the end of the baseline: reduce the baseline length."];
    if (peakFrame >= frames - 2)
        [warnings addObject:@"the peak is at the end of the series: the bolus may not be fully covered."];
    if ([warnings count]) [text appendFormat:@"Warnings: %@", [warnings componentsJoinedByString:@" Also, "]];
    else [text appendString:@"No problems found."];
    [_aifResult setStringValue:text];

    for (int t = 0; t < frames; t++) if (pixelValues[t]) free(pixelValues[t]);
    free(pixelValues);
    free(meanCurve);
    free(c);
}

// Candidate arterial voxels on the current slice: strong, early and narrow first-pass peaks without
// saturation. The best few are marked with a brush ROI "Auto AIF".
- (void)findAIF:(id)sender
{
    if (![self require4D]) return;
    int frames = [_viewer maxMovieIndex];
    int bl = [self baselineFramesForFrames:frames];
    short slice = [[_viewer imageView] curImage];
    NSArray *firstFrame = [_viewer pixList:0];
    if (slice < 0 || slice >= (short)[firstFrame count]) return;
    DCMPix *pix0 = [firstFrame objectAtIndex:slice];
    int width = [pix0 pwidth], height = [pix0 pheight];
    long size = (long)width * height;

    float **img = (float **)calloc((size_t)frames, sizeof(float *));
    for (int t = 0; t < frames; t++) img[t] = [[[_viewer pixList:t] objectAtIndex:slice] fImage];

    double *s0 = (double *)calloc((size_t)size, sizeof(double));
    float *sorted = (float *)malloc(sizeof(float) * (size_t)size);
    long npos = 0;
    for (long i = 0; i < size; i++) {
        for (int t = 0; t < bl; t++) s0[i] += img[t][i];
        s0[i] /= bl;
        if (s0[i] > 0) sorted[npos++] = (float)s0[i];
    }
    double threshold = 0;
    if (npos) { qsort(sorted, (size_t)npos, sizeof(float), UMMPCompareFloats); threshold = 0.1 * sorted[(long)(0.99 * (npos - 1))]; }
    free(sorted);

    typedef struct { long index; double peak; int ttp; int fwhm; } Candidate;
    Candidate *cand = (Candidate *)malloc(sizeof(Candidate) * (size_t)size);
    long nc = 0;
    double *c = (double *)malloc(sizeof(double) * (size_t)frames);
    for (long i = 0; i < size; i++) {
        if (!(s0[i] > threshold)) continue;
        BOOL saturated = NO;
        int peakFrame = bl;
        for (int t = 0; t < frames; t++) {
            double ratio = img[t][i] / s0[i];
            if (!(ratio > 0.05)) { saturated = YES; break; }
            c[t] = -log(ratio);
            if (t >= bl && c[t] > c[peakFrame]) peakFrame = t;
        }
        if (saturated || peakFrame >= frames - 1) continue;
        double peak = c[peakFrame];
        if (!(peak > 0)) continue;
        int left = peakFrame, right = peakFrame;
        while (left > bl && c[left - 1] >= 0.5 * peak) left--;
        while (right < frames - 1 && c[right + 1] >= 0.5 * peak) right++;
        cand[nc].index = i; cand[nc].peak = peak; cand[nc].ttp = peakFrame; cand[nc].fwhm = right - left + 1;
        nc++;
    }
    free(c);

    NSString *result = nil;
    if (nc < 20) {
        result = @"Too few usable voxels on this slice. Go to a slice through the middle cerebral arteries (or the carotids) and try again.";
    } else {
        // strongest 5 % (at least 20), then the earlier half of those, ranked by peak / width
        qsort_b(cand, (size_t)nc, sizeof(Candidate), ^int(const void *a, const void *b) {
            double x = ((const Candidate *)a)->peak, y = ((const Candidate *)b)->peak;
            return (x < y) - (x > y);
        });
        long top = MAX(20, nc / 20);
        if (top > nc) top = nc;
        int *ttps = (int *)malloc(sizeof(int) * (size_t)top);
        for (long k = 0; k < top; k++) ttps[k] = cand[k].ttp;
        qsort_b(ttps, (size_t)top, sizeof(int), ^int(const void *a, const void *b) {
            return *(const int *)a - *(const int *)b;
        });
        int medianTTP = ttps[top / 2];
        free(ttps);
        long early = 0;
        for (long k = 0; k < top; k++) if (cand[k].ttp <= medianTTP) cand[early++] = cand[k];
        qsort_b(cand, (size_t)early, sizeof(Candidate), ^int(const void *a, const void *b) {
            const Candidate *x = a, *y = b;
            double sx = x->peak / x->fwhm, sy = y->peak / y->fwhm;
            return (sx < sy) - (sx > sy);
        });
        long chosen = MIN(8, early);
        unsigned char *mask = (unsigned char *)calloc((size_t)size, 1);
        double meanPeak = 0, meanTTP = 0;
        for (long k = 0; k < chosen; k++) {
            mask[cand[k].index] = 255;
            meanPeak += cand[k].peak;
            meanTTP += cand[k].ttp + 1;
        }
        meanPeak /= chosen; meanTTP /= chosen;

        ROI *roi = [[[ROI alloc] initWithTexture:mask textWidth:width textHeight:height textName:@"Auto AIF"
                                       positionX:0 positionY:0
                                        spacingX:[pix0 pixelSpacingX] spacingY:[pix0 pixelSpacingY]
                                     imageOrigin:NSMakePoint([pix0 originX], [pix0 originY])] autorelease];
        free(mask);
        RGBColor red = {65535, 0, 0};
        [roi setColor:red];
        short movie = [_viewer curMovieIndex];
        [roi setPix:[[_viewer pixList:movie] objectAtIndex:slice]];
        [roi setCurView:[_viewer imageView]];
        [[[_viewer roiList:movie] objectAtIndex:slice] addObject:roi];
        [_viewer needsDisplayUpdate];
        [[NSNotificationCenter defaultCenter] postNotificationName:OsirixROIChangeNotification object:roi userInfo:nil];
        [self refreshROIs:nil];
        for (NSDictionary *e in _roiEntries)
            if ([e objectForKey:@"roi"] == roi) { [_aifPopup selectItemWithTitle:[e objectForKey:@"title"]]; break; }

        result = [NSString stringWithFormat:@"Marked %ld voxels as ROI “Auto AIF” on slice %d (out of %ld usable): mean peak ΔR2*·TE %.2f, mean peak frame %.1f. Check that they lie in or beside a large artery, then choose “Auto AIF” as the arterial ROI in the UMMPerfusion panel.",
                  chosen, slice + 1, nc, meanPeak, meanTTP];
    }
    free(cand);
    free(s0);
    free(img);
    [_aifResult setStringValue:result];
}

@end
