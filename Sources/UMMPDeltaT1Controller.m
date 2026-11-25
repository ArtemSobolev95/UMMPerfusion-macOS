//
//  UMMPDeltaT1Controller.m — "UMMPerfusion ΔT1 & Tumour Burden" window (IsiX port).
//

#import "UMMPDeltaT1Controller.h"
#import "UMMPUIHelpers.h"
#import "UMMPDeltaT1.h"
#import "UMMPIsiXSupport.h"
#import "UMMPerfusionFilter.h"
#import "DCMObject.h"
#import <OsiriXAPI/ViewerController.h>
#import <OsiriXAPI/DCMPix.h>
#import <OsiriXAPI/DCMView.h>
#import <OsiriXAPI/ROI.h>
#import <OsiriXAPI/Notifications.h>
#import <CommonCrypto/CommonDigest.h>

#define UMMP_DT1_DOMAIN @"com.osirix.UMMPerfusion.DSC"
#define UMMP_DT1_HISTORY_KEY @"dt1History"

// Volumetric thresholds of the modified RANO criteria (Ellingson, Wen & Cloughesy 2017):
// progression ≥ +40 % from nadir, partial response ≤ −65 % from baseline (the volumetric
// equivalents of +25 % / −50 % in the product of two diameters).
#define UMMP_PROGRESSION_FRACTION 0.40
#define UMMP_RESPONSE_FRACTION (-0.65)

static NSString *const UMMPEnhancingPrefix = @"Enhancing";
static NSString *const UMMPBurdenPrefix = @"FTB";
static NSString *const UMMPOverlayPrefix = @"ΔT1 overlay";

#pragma mark - Geometry helpers

// The viewer at this address if it is still open, else nil. Compares addresses only: a stored
// (non-retained) pointer to a closed viewer must never receive a message.
static ViewerController *UMMPOpenViewer(void *address)
{
    if (!address) return nil;
    for (ViewerController *v in [ViewerController getDisplayed2DViewers])
        if ((void *)v == address) return v;
    return nil;
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

// Distance between the first two slices (mm), else the slice thickness, else 1.
static double UMMPSliceInterval(NSArray *pixList)
{
    DCMPix *p0 = [pixList count] ? [pixList objectAtIndex:0] : nil;
    if (!p0) return 1.0;
    if ([pixList count] > 1) {
        DCMPix *p1 = [pixList objectAtIndex:1];
        double d = sqrt(pow([p1 originX] - [p0 originX], 2) + pow([p1 originY] - [p0 originY], 2) + pow([p1 originZ] - [p0 originZ], 2));
        if (d > 0) return d;
    }
    return [p0 sliceThickness] > 0 ? [p0 sliceThickness] : 1.0;
}

// YES when the middle slice of the viewer holds the given values.
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
// malloc'ed; the viewer's volume data takes ownership). IsiX fills a viewer made by
// duplicateViewer: asynchronously with the source pixels, so that is not used.
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

// Removes from every slice of the viewer the ROIs whose names start with one of the prefixes.
static void UMMPRemoveROIsWithPrefixes(ViewerController *v, NSArray *prefixes)
{
    for (NSMutableArray *slice in [v roiList:0]) {
        NSMutableArray *drop = [NSMutableArray array];
        for (ROI *roi in slice)
            for (NSString *p in prefixes)
                if ([[roi name] hasPrefix:p]) { [drop addObject:roi]; break; }
        [slice removeObjectsInArray:drop];
    }
}

// Adds one brush ROI per slice from a per-voxel label volume (the voxels equal to `label`).
static long UMMPAddBrushROIs(ViewerController *v, const unsigned char *labels, unsigned char label,
                             NSString *name, RGBColor color, float opacity)
{
    long offset = 0, total = 0;
    NSArray *pixList = [v pixList];
    NSArray *rois = [v roiList:0];
    for (NSUInteger s = 0; s < [pixList count]; s++) {
        DCMPix *pix = [pixList objectAtIndex:s];
        long w = [pix pwidth], h = [pix pheight], size = w * h, here = 0;
        unsigned char *mask = (unsigned char *)calloc((size_t)size, 1);
        for (long i = 0; i < size; i++) if (labels[offset + i] == label) { mask[i] = 255; here++; }
        offset += size;
        if (here && s < [rois count]) {
            ROI *roi = [[[ROI alloc] initWithTexture:mask textWidth:(int)w textHeight:(int)h textName:name
                                           positionX:0 positionY:0
                                            spacingX:[pix pixelSpacingX] spacingY:[pix pixelSpacingY]
                                         imageOrigin:NSMakePoint([pix originX], [pix originY])] autorelease];
            [roi setColor:color];
            if (opacity > 0) [roi setOpacity:opacity];
            [roi setPix:pix];
            [roi setCurView:[v imageView]];
            [[rois objectAtIndex:s] addObject:roi];
            total += here;
        }
        free(mask);
    }
    return total;
}

// ROI types that enclose an area (lines, angles, arrows, text and points do not).
static BOOL UMMPIsAreaROI(ROI *roi)
{
    long t = (long)[roi type];
    return !(t == tMesure || t == tArrow || t == tText || t == tAngle || t == t2DPoint || t == tOPolygon);
}

// Patient name, ID, study date and study UID of a viewer's first image (DICOM header).
static NSDictionary *UMMPPatientInfo(ViewerController *v)
{
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    @try {
        DCMPix *p = [[v pixList] count] ? [[v pixList] objectAtIndex:0] : nil;
        NSString *file = [p sourceFile];
        DCMObject *o = file ? [DCMObject objectWithContentsOfFile:file decodingPixelData:NO] : nil;
        id pid = [o attributeValueForKey:@"0010,0020"], name = [o attributeValueForKey:@"0010,0010"];
        id date = [o attributeValueForKey:@"0008,0020"] ?: [o attributeValueForKey:@"0008,0022"];
        id uid = [o attributeValueForKey:@"0020,000D"];
        if (pid) [info setObject:[pid description] forKey:@"patientID"];
        if (name) [info setObject:[name description] forKey:@"patientName"];
        if (uid) [info setObject:[uid description] forKey:@"studyUID"];
        if ([date respondsToSelector:@selector(descriptionWithCalendarFormat:)])
            [info setObject:[date descriptionWithCalendarFormat:@"%Y-%m-%d"] forKey:@"studyDate"];
        else if (date)
            [info setObject:[date description] forKey:@"studyDate"];
    } @catch (NSException *e) {
        NSLog(@"UMMP ΔT1: patient information not readable: %@", e);
    }
    return info;
}

// The history is stored under a one-way hash of the patient ID, not the ID itself.
static NSString *UMMPPatientKey(NSString *patientID)
{
    if (![patientID length]) return nil;
    NSData *d = [[@"UMMP-dT1:" stringByAppendingString:patientID] dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char h[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256([d bytes], (CC_LONG)[d length], h);
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [s appendFormat:@"%02x", h[i]];
    return s;
}

static NSString *UMMPPercent(double fraction)
{
    if (!isfinite(fraction)) return @"–";
    return [NSString stringWithFormat:@"%+.0f %%", fraction * 100.0];
}

#pragma mark -

@interface UMMPDeltaT1Controller ()
{
    UMMPerfusionFilter *_filter;              // not retained
    NSMutableArray *_viewers;                 // NSValue (non-retained ViewerController), order of every popup
    ViewerController *_lastCreated;           // not retained: the ΔT1 viewer made last

    NSPopUpButton *_prePopup, *_postPopup, *_dt1Popup, *_mapPopup;
    NSButton *_registerBox, *_shadingBox, *_createButton;
    NSTextField *_createResult;

    NSTextField *_thresholdField, *_measureResult;
    NSTextField *_lowField, *_highField, *_burdenResult;
    NSPopUpButton *_overlayPopup;
    NSButton *_overlayInsideBox;
    NSTextField *_overlayResult;

    NSTextField *_patientLabel;
    NSTableView *_historyTable;
    NSMutableArray *_history;                 // measurements of the current patient, by study date
    NSString *_patientKey;

    NSMutableDictionary *_current;            // the last measurement (enhancing volume, burden)
    NSMutableData *_enhancing;                // 1 per enhancing voxel inside the ROIs, on the ΔT1 grid
    ViewerController *_enhancingViewer;       // not retained: the ΔT1 viewer of _enhancing
    NSMutableData *_burdenClasses;            // FTB class per voxel (1 low, 2 intermediate, 3 high, 4 no data)
    ViewerController *_burdenViewer;          // not retained: the ΔT1 viewer of _burdenClasses
}
@end

@implementation UMMPDeltaT1Controller

+ (UMMPDeltaT1Controller *)sharedController
{
    static UMMPDeltaT1Controller *shared = nil;
    if (!shared) shared = [[UMMPDeltaT1Controller alloc] init];
    return shared;
}

- (id)init
{
    NSPanel *panel = [[[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 700, 960)
                                                 styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                           NSWindowStyleMaskResizable | NSWindowStyleMaskUtilityWindow
                                                   backing:NSBackingStoreBuffered defer:YES] autorelease];
    self = [super initWithWindow:panel];
    if (self) {
        [panel setTitle:@"UMMPerfusion ΔT1 & Tumour Burden"];
        [panel setFloatingPanel:YES];
        [panel setLevel:NSFloatingWindowLevel];
        [panel setHidesOnDeactivate:YES];
        [panel setBecomesKeyOnlyIfNeeded:NO];
        [panel setCollectionBehavior:NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorMoveToActiveSpace];
        [panel setReleasedWhenClosed:NO];
        [panel setMinSize:NSMakeSize(640, 880)];
        [panel setDelegate:self];
        _viewers = [[NSMutableArray alloc] init];
        _history = [[NSMutableArray alloc] init];
        [self buildInterface];
        [self loadSettings];
        [panel center];
        [panel setFrameAutosaveName:@"UMMPDeltaT1Window"];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(viewerWillClose:)
                                                     name:OsirixCloseViewerNotification object:nil];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_viewers release];
    [_history release];
    [_patientKey release];
    [_current release];
    [_enhancing release];
    [_burdenClasses release];
    [super dealloc];
}

- (void)showWithFilter:(UMMPerfusionFilter *)filter
{
    if (filter) _filter = filter;
    [self refreshViewers:nil];
    [self showWindow:nil];
    [[self window] makeKeyAndOrderFront:nil];
}

#pragma mark - Interface

static NSTextField *UMMPWrapping(NSString *text, BOOL secondary)
{
    NSTextField *f = [NSTextField wrappingLabelWithString:text];
    [f setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    if (secondary) [f setTextColor:[NSColor secondaryLabelColor]];
    [f setSelectable:YES];
    return f;
}

static NSPopUpButton *UMMPPopup(CGFloat maxWidth)
{
    NSPopUpButton *b = [[[NSPopUpButton alloc] init] autorelease];
    [b setControlSize:NSControlSizeSmall];
    [b setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    [[b widthAnchor] constraintLessThanOrEqualToConstant:maxWidth].active = YES;
    return b;
}

static NSStackView *UMMPColumn(NSArray *views, NSArray *fullWidth)
{
    NSStackView *c = [NSStackView stackViewWithViews:views];
    [c setOrientation:NSUserInterfaceLayoutOrientationVertical];
    [c setAlignment:NSLayoutAttributeLeading];
    [c setSpacing:6];
    for (NSView *v in fullWidth) [[v widthAnchor] constraintEqualToAnchor:[c widthAnchor]].active = YES;
    return c;
}

- (void)buildInterface
{
    NSView *content = [[self window] contentView];

    // 1. ΔT1 map
    _prePopup = UMMPPopup(240);
    _postPopup = UMMPPopup(240);
    _registerBox = UMMPCheckbox(@"Align post onto pre (head movement)", self, NULL);
    _shadingBox = UMMPCheckbox(@"Correct coil shading", self, NULL);
    [_registerBox setState:NSControlStateValueOn];
    [_shadingBox setState:NSControlStateValueOn];
    _createButton = UMMPButton(@"Create ΔT1 Map", self, @selector(createDeltaT1Map:));
    _createResult = UMMPWrapping(@"Pre- and post-contrast 3D T1 of the same sequence and slices. ΔT1 = post ÷ its median − "
                                 @"pre ÷ its median (0 = no enhancement). Not the IB Delta Suite scale.", YES);
    NSStackView *create = UMMPColumn(@[UMMPRow(@[UMMPLabel(@"Pre:"), _prePopup, UMMPLabel(@"Post:"), _postPopup,
                                                 UMMPButton(@"Refresh", self, @selector(refreshViewers:))]),
                                       UMMPRow(@[_registerBox, _shadingBox, _createButton]), _createResult], @[_createResult]);

    // 2. Enhancing volume in the ROIs
    _dt1Popup = UMMPPopup(300);
    [_dt1Popup setTarget:self];
    [_dt1Popup setAction:@selector(dt1ViewerChanged:)];
    _thresholdField = UMMPNumberField(@"0.2", 44);
    _measureResult = UMMPWrapping(@"Draw closed ROIs (polygon, oval, pencil or brush; any name) around the lesion or the "
                                  @"resection bed on the slices it covers — on the ΔT1 map or on the pre- or post-contrast "
                                  @"series. Normal enhancement (dura, vessels, choroid plexus) outside the ROIs is ignored.", YES);
    NSStackView *measure = UMMPColumn(@[UMMPRow(@[UMMPLabel(@"ΔT1 map:"), _dt1Popup]),
                                        UMMPRow(@[UMMPLabel(@"Enhancing where ΔT1 >"), _thresholdField,
                                                  UMMPButton(@"Measure Enhancing in ROIs", self, @selector(measureEnhancing:))]),
                                        _measureResult], @[_measureResult]);

    // 3. Fractional tumour burden
    _mapPopup = UMMPPopup(300);
    _lowField = UMMPNumberField(@"1.0", 44);
    _highField = UMMPNumberField(@"1.75", 44);
    _burdenResult = UMMPWrapping(@"Each enhancing voxel gets the blood volume of the rCBV or sRCBV map at the same scanner "
                                 @"position: low (below the first value, treatment-effect-like), intermediate, or high (at "
                                 @"or above the second, tumour-like). Thresholds of your own scale: not validated.", YES);
    NSStackView *burden = UMMPColumn(@[UMMPRow(@[UMMPLabel(@"Perfusion map:"), _mapPopup]),
                                       UMMPRow(@[UMMPLabel(@"Low below"), _lowField, UMMPLabel(@"high from"), _highField,
                                                 UMMPButton(@"Compute Tumour Burden", self, @selector(computeBurden:))]),
                                       _burdenResult], @[_burdenResult]);

    // Overlay on the post-contrast T1 (anatomy underneath, sub-threshold voxels transparent)
    _overlayPopup = [[[NSPopUpButton alloc] init] autorelease];
    [_overlayPopup setControlSize:NSControlSizeSmall];
    [_overlayPopup setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    [_overlayPopup addItemsWithTitles:@[@"ΔT1 graded (yellow · orange · red)", @"FTB classes (green · yellow · red)"]];
    _overlayInsideBox = UMMPCheckbox(@"only inside my ROIs", self, NULL);
    [_overlayInsideBox setState:NSControlStateValueOn];
    _overlayResult = UMMPWrapping(@"Draws the result on the Post series chosen in section 1. ΔT1 graded: threshold–2×, "
                                  @"2–3.5×, ≥ 3.5× the threshold (0.2 → 0.2–0.4 yellow, 0.4–0.7 orange, ≥ 0.7 red).", YES);
    NSStackView *overlay = UMMPColumn(@[UMMPRow(@[_overlayPopup, _overlayInsideBox,
                                                  UMMPButton(@"Show on Post-contrast T1", self, @selector(showOverlay:)),
                                                  UMMPButton(@"Remove", self, @selector(removeOverlay:))]),
                                        _overlayResult], @[_overlayResult]);

    // 4. Follow-up
    _patientLabel = UMMPLabel(@"Patient: –");
    [_patientLabel setLineBreakMode:NSLineBreakByTruncatingTail];
    _historyTable = [[[NSTableView alloc] init] autorelease];
    NSArray *columns = @[@[@"date", @"Study date", @82], @[@"enhancing", @"Enhancing ml", @84],
                         @[@"baseline", @"vs baseline", @74], @[@"nadir", @"vs nadir", @66],
                         @[@"high", @"High CBV", @64], @[@"assessment", @"Volumetric range", @150]];
    for (NSArray *c in columns) {
        NSTableColumn *col = [[[NSTableColumn alloc] initWithIdentifier:[c objectAtIndex:0]] autorelease];
        [[col headerCell] setStringValue:[c objectAtIndex:1]];
        [col setWidth:[[c objectAtIndex:2] doubleValue]];
        [_historyTable addTableColumn:col];
    }
    [_historyTable setDataSource:self];
    [_historyTable setDelegate:self];
    [_historyTable setRowSizeStyle:NSTableViewRowSizeStyleSmall];
    [_historyTable setUsesAlternatingRowBackgroundColors:YES];
    NSScrollView *scroll = [[[NSScrollView alloc] init] autorelease];
    [scroll setDocumentView:_historyTable];
    [scroll setHasVerticalScroller:YES];
    [scroll setBorderType:NSBezelBorder];
    [[scroll heightAnchor] constraintGreaterThanOrEqualToConstant:120].active = YES;
    NSTextField *followNote = UMMPWrapping(@"Volumetric ranges of the modified RANO criteria: progression ≥ +40 % from the "
                                           @"smallest earlier volume (nadir), response ≤ −65 % from baseline (the first "
                                           @"study). Same sequence, threshold and ROI rules at every visit. A reading aid, "
                                           @"not a response category.", YES);
    NSStackView *follow = UMMPColumn(@[_patientLabel, scroll,
                                       UMMPRow(@[UMMPButton(@"Save Current Measurement", self, @selector(saveMeasurement:)),
                                                 UMMPButton(@"Delete Selected", self, @selector(deleteMeasurement:)),
                                                 UMMPButton(@"Export CSV…", self, @selector(exportHistory:))]),
                                       followNote], @[_patientLabel, scroll, followNote]);

    NSBox *b1 = UMMPSection(@"1. ΔT1 map", create);
    NSBox *b2 = UMMPSection(@"2. Enhancing volume inside your ROIs", measure);
    NSBox *b3 = UMMPSection(@"3. Fractional tumour burden (ΔT1 × rCBV)", burden);
    NSBox *b4 = UMMPSection(@"4. Follow-up of this patient", follow);
    NSBox *b5 = UMMPSection(@"Colour overlay on the post-contrast T1", overlay);
    NSStackView *main = [NSStackView stackViewWithViews:@[b1, b2, b3, b5, b4]];
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
        [[b1 widthAnchor] constraintEqualToAnchor:[main widthAnchor]],
        [[b2 widthAnchor] constraintEqualToAnchor:[main widthAnchor]],
        [[b3 widthAnchor] constraintEqualToAnchor:[main widthAnchor]],
        [[b4 widthAnchor] constraintEqualToAnchor:[main widthAnchor]],
        [[b5 widthAnchor] constraintEqualToAnchor:[main widthAnchor]]]];
    [b4 setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];
}

- (void)showMessage:(NSString *)title text:(NSString *)text
{
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    [alert setMessageText:title];
    [alert setInformativeText:text ?: @""];
    [alert beginSheetModalForWindow:[self window] completionHandler:nil];
}

#pragma mark - Settings

- (NSDictionary *)domain
{
    return [[NSUserDefaults standardUserDefaults] persistentDomainForName:UMMP_DT1_DOMAIN] ?: @{};
}

- (void)setDomainValue:(id)value forKey:(NSString *)key
{
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:[self domain]];
    if (value) [d setObject:value forKey:key]; else [d removeObjectForKey:key];
    [[NSUserDefaults standardUserDefaults] setPersistentDomain:d forName:UMMP_DT1_DOMAIN];
}

- (void)loadSettings
{
    NSDictionary *d = [self domain];
    id t = [d objectForKey:@"dt1Threshold"], lo = [d objectForKey:@"ftbLow"], hi = [d objectForKey:@"ftbHigh"];
    id reg = [d objectForKey:@"dt1Register"], sh = [d objectForKey:@"dt1Shading"];
    if (t) [_thresholdField setStringValue:[NSString stringWithFormat:@"%g", [t doubleValue]]];
    if (lo) [_lowField setStringValue:[NSString stringWithFormat:@"%g", [lo doubleValue]]];
    if (hi) [_highField setStringValue:[NSString stringWithFormat:@"%g", [hi doubleValue]]];
    if (reg) [_registerBox setState:[reg boolValue] ? NSControlStateValueOn : NSControlStateValueOff];
    if (sh) [_shadingBox setState:[sh boolValue] ? NSControlStateValueOn : NSControlStateValueOff];
}

- (void)saveSettings
{
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:[self domain]];
    [d setObject:@([_thresholdField doubleValue]) forKey:@"dt1Threshold"];
    [d setObject:@([_lowField doubleValue]) forKey:@"ftbLow"];
    [d setObject:@([_highField doubleValue]) forKey:@"ftbHigh"];
    [d setObject:@([_registerBox state] == NSControlStateValueOn) forKey:@"dt1Register"];
    [d setObject:@([_shadingBox state] == NSControlStateValueOn) forKey:@"dt1Shading"];
    [[NSUserDefaults standardUserDefaults] setPersistentDomain:d forName:UMMP_DT1_DOMAIN];
}

#pragma mark - Viewers

static BOOL UMMPTitleContains(ViewerController *v, NSString *text)
{
    NSString *t = [[v window] title];
    NSString *g = [[v pixList] count] ? [[[v pixList] objectAtIndex:0] generatedName] : nil;
    return (t && [t rangeOfString:text].location != NSNotFound) || (g && [g rangeOfString:text].location != NSNotFound);
}

// Every open single-frame 2D viewer, in all four popups (same order). Keeps the selections.
- (void)refreshViewers:(id)sender
{
    ViewerController *pre = [self viewerForPopup:_prePopup], *post = [self viewerForPopup:_postPopup];
    ViewerController *dt1 = [self viewerForPopup:_dt1Popup], *map = [self viewerForPopup:_mapPopup];
    [_viewers removeAllObjects];
    for (NSPopUpButton *p in @[_prePopup, _postPopup, _dt1Popup, _mapPopup]) [p removeAllItems];
    for (ViewerController *v in [ViewerController getDisplayed2DViewers]) {
        if ([v maxMovieIndex] > 1) continue;
        NSString *title = [[v window] title];
        if (![title length]) title = @"Viewer";
        NSString *g = [[v pixList] count] ? [[[v pixList] objectAtIndex:0] generatedName] : nil;
        if ([g length] && [title rangeOfString:g].location == NSNotFound) title = [NSString stringWithFormat:@"%@ — %@", title, g];
        NSString *unique = title;
        for (int k = 2; [_prePopup itemWithTitle:unique]; k++) unique = [NSString stringWithFormat:@"%@ (%d)", title, k];
        for (NSPopUpButton *p in @[_prePopup, _postPopup, _dt1Popup, _mapPopup]) [p addItemWithTitle:unique];
        [_viewers addObject:[NSValue valueWithPointer:v]];
    }
    NSInteger n = (NSInteger)[_viewers count];
    // Defaults: ΔT1 map = the last one made (or any viewer named ΔT1); perfusion map = sRCBV, else rCBV.
    NSInteger dt1Guess = -1, mapGuess = -1, srcbvGuess = -1;
    for (NSInteger i = 0; i < n; i++) {
        ViewerController *v = (ViewerController *)[[_viewers objectAtIndex:i] pointerValue];
        if (v == _lastCreated || UMMPTitleContains(v, @"ΔT1")) dt1Guess = (v == _lastCreated || dt1Guess < 0) ? i : dt1Guess;
        if (UMMPTitleContains(v, @"sRCBV")) srcbvGuess = i;
        else if (UMMPTitleContains(v, @"rCBV")) mapGuess = i;
    }
    if (srcbvGuess >= 0) mapGuess = srcbvGuess;
    [self select:pre in:_prePopup fallback:0];
    [self select:post in:_postPopup fallback:(n > 1 ? 1 : 0)];
    [self select:dt1 in:_dt1Popup fallback:dt1Guess];
    [self select:map in:_mapPopup fallback:mapGuess];
    if (dt1 != [self viewerForPopup:_dt1Popup]) [self dt1ViewerChanged:nil];
}

- (void)select:(ViewerController *)v in:(NSPopUpButton *)popup fallback:(NSInteger)fallback
{
    NSInteger index = -1;
    for (NSInteger i = 0; i < (NSInteger)[_viewers count]; i++)
        if ([[_viewers objectAtIndex:i] pointerValue] == (void *)v) index = i;
    if (index < 0) index = fallback;
    if (index >= 0 && index < [popup numberOfItems]) [popup selectItemAtIndex:index];
}

- (ViewerController *)viewerForPopup:(NSPopUpButton *)popup
{
    NSInteger i = [popup indexOfSelectedItem];
    if (i < 0 || i >= (NSInteger)[_viewers count]) return nil;
    return UMMPOpenViewer([[_viewers objectAtIndex:i] pointerValue]);
}

- (void)viewerWillClose:(NSNotification *)note
{
    void *v = (void *)[note object];
    if (v == (void *)_lastCreated) _lastCreated = nil;
    if (v == (void *)_enhancingViewer) { _enhancingViewer = nil; [_enhancing release]; _enhancing = nil; }
    if (v == (void *)_burdenViewer) { _burdenViewer = nil; [_burdenClasses release]; _burdenClasses = nil; }
    // Forget the closing viewer now (it is freed before the refresh below runs), keeping the
    // popups in the same order as the list.
    for (NSUInteger i = 0; i < [_viewers count]; i++)
        if ([[_viewers objectAtIndex:i] pointerValue] == v) {
            [_viewers replaceObjectAtIndex:i withObject:[NSValue valueWithPointer:NULL]];
            dispatch_async(dispatch_get_main_queue(), ^{ [self refreshViewers:nil]; });
        }
}

- (void)windowDidBecomeKey:(NSNotification *)note
{
    [self refreshViewers:nil];
}

#pragma mark - 1. ΔT1 map

- (void)createDeltaT1Map:(id)sender
{
    [self refreshViewers:nil];
    [self saveSettings];
    ViewerController *pre = [self viewerForPopup:_prePopup], *post = [self viewerForPopup:_postPopup];
    if (!pre || !post || pre == post) {
        [self showMessage:@"Choose two series" text:@"Open the pre- and the post-contrast T1 series in two viewers and choose them as Pre and Post."];
        return;
    }
    // IsiX/Horos load a series in the background: wait until every slice is in memory.
    [pre checkEverythingLoaded];
    [post checkEverythingLoaded];
    NSString *mismatch = UMMPGeometryMismatch(pre, post);
    if (mismatch) {
        [self showMessage:@"The two series do not overlap"
                     text:[NSString stringWithFormat:@"Pre and post must have the same matrix, slices and position (%@). "
                           @"Use the same 3D T1 sequence before and after contrast.", mismatch]];
        return;
    }
    long n = 0, m = 0;
    float *a = UMMPVolumeCopy(pre, &n), *b = UMMPVolumeCopy(post, &m);
    NSArray *prePix = [pre pixList];
    DCMPix *p0 = [prePix objectAtIndex:0];
    long nx = [p0 pwidth], ny = [p0 pheight], nz = (long)[prePix count];
    double dx = [p0 pixelSpacingX] > 0 ? [p0 pixelSpacingX] : 1.0, dy = [p0 pixelSpacingY] > 0 ? [p0 pixelSpacingY] : 1.0;
    double dz = UMMPSliceInterval(prePix);
    BOOL doRegister = ([_registerBox state] == NSControlStateValueOn);
    BOOL doShading = ([_shadingBox state] == NSControlStateValueOn);
    double maskFraction = UMMPDCEMaskFraction();
    if (n != m || n != nx * ny * nz) {
        free(a); free(b);
        [self showMessage:@"No ΔT1 map" text:@"The two series do not have the same number of pixels."];
        return;
    }
    [_createButton setEnabled:NO];
    [_createResult setTextColor:[NSColor labelColor]];
    [_createResult setStringValue:doRegister ? @"Aligning post onto pre and computing ΔT1…" : @"Computing ΔT1…"];
    NSDate *start = [NSDate date];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        float *d = (float *)malloc(sizeof(float) * (size_t)(n > 0 ? n : 1));
        UMMPDT1Report rep;
        memset(&rep, 0, sizeof(rep));
        int ok = d && UMMPDT1Pipeline(a, b, nx, ny, nz, dx, dy, dz, doRegister, doShading, maskFraction, d, &rep);
        free(a); free(b);
        dispatch_async(dispatch_get_main_queue(), ^{
            [_createButton setEnabled:YES];
            if (!ok) {
                free(d);
                [_createResult setStringValue:@"No ΔT1 map."];
                [self showMessage:@"No ΔT1 map" text:@"The pre series has too few pixels above the head-mask threshold, or no signal."];
                return;
            }
            NSString *steps = [NSString stringWithFormat:@"%@%@ (%.0f s)",
                doRegister ? [NSString stringWithFormat:@"post aligned: rotation %.1f° %.1f° %.1f°, shift %.1f %.1f %.1f mm, local r %.2f; ",
                              rep.transform.rx * 180 / M_PI, rep.transform.ry * 180 / M_PI, rep.transform.rz * 180 / M_PI,
                              rep.transform.tx, rep.transform.ty, rep.transform.tz, rep.correlation] : @"not aligned; ",
                doShading ? @"shading corrected" : @"no shading correction", -[start timeIntervalSinceNow]];
            [self finishDeltaT1:d count:n pre:pre steps:steps];
        });
    });
}

- (void)finishDeltaT1:(float *)d count:(long)n pre:(ViewerController *)pre steps:(NSString *)steps
{
    if (!UMMPOpenViewer(pre)) {
        free(d);
        [_createResult setStringValue:@"The pre-contrast viewer was closed: no ΔT1 map."];
        return;
    }
    NSData *check = [NSData dataWithBytes:d length:sizeof(float) * (size_t)n];
    NSString *error = nil;
    ViewerController *out = UMMPNewViewerFromVolume(pre, d, n, &error);   // takes d
    if (!out) {
        [self showMessage:@"No ΔT1 viewer" text:error ?: @"IsiX did not open a new viewer."];
        return;
    }
    if ([[out pixList] count]) [[[out pixList] objectAtIndex:0] setGeneratedName:@"ΔT1 (post ÷ median − pre ÷ median)"];
    for (DCMPix *pix in [out pixList]) [pix changeWLWW:0.25 :1.0];
    [out setWL:0.25 WW:1.0];
    [out refresh];
    [out needsDisplayUpdate];
    _lastCreated = out;
    [_createResult setStringValue:[NSString stringWithFormat:@"ΔT1 map created: %@.%@ Next: draw ROIs around the lesion, then section 2.",
                                   steps, UMMPDeltaT1Intact(out, check) ? @"" : @" WARNING: the viewer does not hold the computed values."]];
    [self refreshViewers:nil];
    [self select:out in:_dt1Popup fallback:[_dt1Popup indexOfSelectedItem]];
    [self dt1ViewerChanged:nil];
}

#pragma mark - 2. Enhancing volume inside the ROIs

- (void)dt1ViewerChanged:(id)sender
{
    [self loadPatientFor:[self viewerForPopup:_dt1Popup]];
}

- (BOOL)measureEnhancingQuietly:(BOOL)quiet
{
    ViewerController *dt1 = [self viewerForPopup:_dt1Popup];
    if (!dt1) {
        if (!quiet) [self showMessage:@"No ΔT1 map" text:@"Create a ΔT1 map (section 1) or choose its viewer."];
        return NO;
    }
    [self saveSettings];
    double threshold = [_thresholdField doubleValue];
    NSArray *dPix = [dt1 pixList];
    long total = 0;
    for (DCMPix *p in dPix) total += (long)[p pwidth] * [p pheight];
    if (!total) return NO;

    // Union of the area ROIs drawn on the ΔT1 map or on any open viewer with the same geometry.
    unsigned char *inRoi = (unsigned char *)calloc((size_t)total, 1);
    NSMutableOrderedSet *names = [NSMutableOrderedSet orderedSet];
    NSMutableOrderedSet *sources = [NSMutableOrderedSet orderedSet];
    long roiSlices = 0;
    NSMutableArray *candidates = [NSMutableArray arrayWithObject:dt1];
    for (ViewerController *v in [ViewerController getDisplayed2DViewers])
        if (v != dt1 && [v maxMovieIndex] <= 1 && !UMMPGeometryMismatch(v, dt1)) [candidates addObject:v];
    for (ViewerController *v in candidates) {
        NSArray *rois = [v roiList:0], *pix = [v pixList];
        long offset = 0;
        for (NSUInteger s = 0; s < [pix count]; s++) {
            DCMPix *p = [pix objectAtIndex:s];
            long w = [p pwidth], h = [p pheight];
            BOOL any = NO;
            for (ROI *roi in (s < [rois count] ? [rois objectAtIndex:s] : @[])) {
                NSString *name = [roi name] ?: @"";
                if ([name hasPrefix:UMMPEnhancingPrefix] || [name hasPrefix:UMMPBurdenPrefix] || [name hasPrefix:UMMPOverlayPrefix] || !UMMPIsAreaROI(roi)) continue;
                long count = 0;
                float *loc = NULL;
                float *values = [p getROIValue:&count :roi :&loc];
                for (long i = 0; loc && i < count; i++) {
                    long x = lroundf(loc[2 * i]), y = lroundf(loc[2 * i + 1]);
                    if (x >= 0 && y >= 0 && x < w && y < h) inRoi[offset + y * w + x] = 1;
                }
                if (values) free(values);
                if (loc) free(loc);
                if (count > 0) {
                    any = YES;
                    [names addObject:[name length] ? name : @"(unnamed)"];
                    [sources addObject:(v == dt1) ? @"ΔT1 map" : ([[v window] title] ?: @"viewer")];
                }
            }
            if (any) roiSlices++;
            offset += w * h;
        }
    }

    // Enhancing voxels inside the ROIs, from the ΔT1 values of the map viewer.
    NSMutableData *enh = [NSMutableData dataWithLength:(NSUInteger)total];
    unsigned char *e = (unsigned char *)[enh mutableBytes];
    long roiVox = 0, enhVox = 0, offset = 0;
    double sumD = 0;
    for (DCMPix *p in dPix) {
        long size = (long)[p pwidth] * [p pheight];
        float *img = [p fImage];
        for (long i = 0; i < size; i++) {
            if (!inRoi[offset + i]) continue;
            roiVox++;
            float v = img ? img[i] : NAN;
            if (isfinite(v) && v > threshold) { e[offset + i] = 1; enhVox++; sumD += v; }
        }
        offset += size;
    }
    free(inRoi);
    if (!roiVox) {
        if (!quiet) [self showMessage:@"No ROI"
                                 text:@"Draw closed ROIs around the lesion on the ΔT1 map or on the pre- or post-contrast series "
                                      @"(same slices), then measure again."];
        return NO;
    }
    DCMPix *p0 = [dPix objectAtIndex:0];
    double voxelMl = [p0 pixelSpacingX] * [p0 pixelSpacingY] * UMMPSliceInterval(dPix) / 1000.0;

    UMMPRemoveROIsWithPrefixes(dt1, @[UMMPEnhancingPrefix, UMMPBurdenPrefix]);
    RGBColor orange = {65535, 32768, 0};
    UMMPAddBrushROIs(dt1, e, 1, [NSString stringWithFormat:@"Enhancing in ROI (ΔT1 > %g)", threshold], orange, 0);
    [dt1 needsDisplayUpdate];

    [_enhancing release];
    _enhancing = [enh retain];
    _enhancingViewer = dt1;
    [_burdenClasses release];
    _burdenClasses = nil;
    _burdenViewer = nil;
    NSDictionary *patient = UMMPPatientInfo(dt1);
    [_current release];
    _current = [[NSMutableDictionary alloc] initWithDictionary:@{
        @"roiNames": [[names array] componentsJoinedByString:@", "], @"roiVolume": @(roiVox * voxelMl),
        @"enhancingVolume": @(enhVox * voxelMl), @"meanDT1": @(enhVox ? sumD / enhVox : 0), @"threshold": @(threshold),
        @"studyDate": [patient objectForKey:@"studyDate"] ?: @"", @"studyUID": [patient objectForKey:@"studyUID"] ?: @""}];
    [_measureResult setTextColor:[NSColor labelColor]];
    [_measureResult setStringValue:[NSString stringWithFormat:
        @"ROIs “%@” on %ld slices (drawn on %@): %.2f ml. Enhancing (ΔT1 > %g): %.2f ml = %.0f %% of the ROIs, mean ΔT1 %.2f. "
        @"Shown as an orange ROI on the ΔT1 map.",
        [_current objectForKey:@"roiNames"], roiSlices, [[sources array] componentsJoinedByString:@", "], roiVox * voxelMl,
        threshold, enhVox * voxelMl, 100.0 * enhVox / roiVox, enhVox ? sumD / enhVox : 0.0]];
    [_burdenResult setTextColor:[NSColor secondaryLabelColor]];
    [_burdenResult setStringValue:@"Not computed for this measurement yet."];
    [self loadPatientFor:dt1];
    return YES;
}

- (void)measureEnhancing:(id)sender
{
    [self measureEnhancingQuietly:NO];
}

#pragma mark - 3. Fractional tumour burden

- (void)computeBurden:(id)sender
{
    ViewerController *dt1 = [self viewerForPopup:_dt1Popup];
    if (!_enhancing || _enhancingViewer != dt1) {
        if (![self measureEnhancingQuietly:NO]) return;
    }
    ViewerController *map = [self viewerForPopup:_mapPopup];
    if (!map || map == dt1) {
        [self showMessage:@"Choose the perfusion map" text:@"Open the rCBV or sRCBV map (made by Fast Deconvolution or DSC Tools) and choose it as Perfusion map."];
        return;
    }
    [self saveSettings];
    double low = [_lowField doubleValue], high = [_highField doubleValue];
    if (!(high > low)) {
        [self showMessage:@"Thresholds" text:@"The high threshold must be above the low one."];
        return;
    }

    // The map's slices in scanner coordinates.
    NSArray *mPix = [map pixList];
    int ns = (int)[mPix count];
    UMMPDT1Slice *slices = (UMMPDT1Slice *)calloc((size_t)MAX(ns, 1), sizeof(UMMPDT1Slice));
    double interval = UMMPSliceInterval(mPix);
    for (int k = 0; k < ns; k++) {
        DCMPix *p = [mPix objectAtIndex:k];
        double o[9];
        [p orientationDouble:o];
        UMMPDT1Slice *s = slices + k;
        s->o[0] = [p originX]; s->o[1] = [p originY]; s->o[2] = [p originZ];
        for (int j = 0; j < 3; j++) { s->row[j] = o[j]; s->col[j] = o[3 + j]; }
        UMMPDT1SliceSetNormal(s);
        s->sx = [p pixelSpacingX] > 0 ? [p pixelSpacingX] : 1; s->sy = [p pixelSpacingY] > 0 ? [p pixelSpacingY] : 1;
        s->halfThickness = 0.5 * MAX([p sliceThickness], interval);   // slice gaps belong to the nearer slice
        s->w = [p pwidth]; s->h = [p pheight];
        s->img = [p fImage];
    }

    // Each enhancing voxel of the ΔT1 grid at its scanner position.
    NSArray *dPix = [dt1 pixList];
    const unsigned char *e = (const unsigned char *)[_enhancing bytes];
    long total = (long)[_enhancing length];
    unsigned char *cls = (unsigned char *)calloc((size_t)total, 1);   // 0 none, 1 low, 2 intermediate, 3 high, 4 no data
    long counts[5] = {0};
    double sumCBV = 0;
    long offset = 0;
    for (DCMPix *p in dPix) {
        long w = [p pwidth], h = [p pheight];
        double o[9];
        [p orientationDouble:o];
        double ox = [p originX], oy = [p originY], oz = [p originZ], sx = [p pixelSpacingX], sy = [p pixelSpacingY];
        for (long y = 0; y < h && offset + y * w < total; y++)
            for (long x = 0; x < w; x++) {
                long i = offset + y * w + x;
                if (!e[i]) continue;
                double pt[3] = {ox + x * sx * o[0] + y * sy * o[3], oy + x * sx * o[1] + y * sy * o[4], oz + x * sx * o[2] + y * sy * o[5]};
                float v = UMMPDT1SampleStack(slices, ns, pt);
                if (!isfinite(v)) { cls[i] = 4; counts[4]++; continue; }
                int c = UMMPDT1BurdenClass(v, low, high);
                cls[i] = (unsigned char)(c + 1);
                counts[c + 1]++;
                sumCBV += v;
            }
        offset += w * h;
    }
    free(slices);

    long enh = counts[1] + counts[2] + counts[3] + counts[4], covered = counts[1] + counts[2] + counts[3];
    DCMPix *p0 = [dPix objectAtIndex:0];
    double voxelMl = [p0 pixelSpacingX] * [p0 pixelSpacingY] * UMMPSliceInterval(dPix) / 1000.0;
    UMMPRemoveROIsWithPrefixes(dt1, @[UMMPEnhancingPrefix, UMMPBurdenPrefix]);
    RGBColor red = {65535, 0, 0}, yellow = {65535, 60000, 0}, green = {0, 52000, 0}, grey = {38000, 38000, 38000};
    UMMPAddBrushROIs(dt1, cls, 3, [NSString stringWithFormat:@"FTB high CBV (≥ %g)", high], red, 0);
    UMMPAddBrushROIs(dt1, cls, 2, @"FTB intermediate CBV", yellow, 0);
    UMMPAddBrushROIs(dt1, cls, 1, [NSString stringWithFormat:@"FTB low CBV (< %g)", low], green, 0);
    UMMPAddBrushROIs(dt1, cls, 4, @"FTB no perfusion data", grey, 0);
    [dt1 needsDisplayUpdate];
    [_burdenClasses release];
    _burdenClasses = [[NSMutableData alloc] initWithBytesNoCopy:cls length:(NSUInteger)total freeWhenDone:YES];
    _burdenViewer = dt1;

    NSString *mapName = [[map window] title] ?: @"map";
    BOOL standardised = UMMPTitleContains(map, @"sRCBV");
    double fl = covered ? (double)counts[1] / covered : NAN, fm = covered ? (double)counts[2] / covered : NAN,
           fh = covered ? (double)counts[3] / covered : NAN;
    [_current addEntriesFromDictionary:@{@"ftbLow": @(fl), @"ftbIntermediate": @(fm), @"ftbHigh": @(fh),
                                         @"ftbCoveredVolume": @(covered * voxelMl), @"ftbMap": standardised ? @"sRCBV" : @"rCBV",
                                         @"ftbLowThreshold": @(low), @"ftbHighThreshold": @(high),
                                         @"meanCBV": @(covered ? sumCBV / covered : NAN)}];
    [_burdenResult setTextColor:[NSColor labelColor]];
    if (!covered) {
        [_burdenResult setStringValue:[NSString stringWithFormat:@"None of the %.2f ml enhancing lies inside the perfusion map "
            @"(%@): check that it is the same patient and study, and that the DSC slices cover the lesion.", enh * voxelMl, mapName]];
        return;
    }
    [_burdenResult setStringValue:[NSString stringWithFormat:
        @"%@ map “%@”. Of %.2f ml enhancing, %.2f ml lies inside the DSC slices (%.0f %%). High CBV (≥ %g): %.0f %% · "
        @"intermediate: %.0f %% · low (< %g): %.0f %%; mean %.2f. ROIs on the ΔT1 map: red high, yellow intermediate, green "
        @"low, grey no perfusion data. Positions in scanner coordinates: if the head moved between DSC and T1 the colours "
        @"shift — compare with the map.",
        standardised ? @"sRCBV" : @"rCBV", mapName, enh * voxelMl, covered * voxelMl, 100.0 * covered / MAX(enh, 1),
        high, 100 * fh, 100 * fm, low, 100 * fl, sumCBV / covered]];
}

#pragma mark - Colour overlay on the post-contrast T1

- (ViewerController *)overlayTarget:(ViewerController *)dt1
{
    ViewerController *post = [self viewerForPopup:_postPopup];
    if (post && post != dt1 && !UMMPGeometryMismatch(post, dt1)) return post;
    // Else another open series of the same grid that is not the chosen Pre series (nor the ΔT1 map).
    ViewerController *pre = [self viewerForPopup:_prePopup];
    for (ViewerController *v in [ViewerController getDisplayed2DViewers])
        if (v != dt1 && v != pre && [v maxMovieIndex] <= 1 && !UMMPGeometryMismatch(v, dt1)) return v;
    return nil;
}

- (void)showOverlay:(id)sender
{
    ViewerController *dt1 = [self viewerForPopup:_dt1Popup];
    if (!dt1) { [self showMessage:@"No ΔT1 map" text:@"Create a ΔT1 map (section 1) or choose its viewer in section 2."]; return; }
    ViewerController *target = [self overlayTarget:dt1];
    if (!target) {
        [self showMessage:@"No post-contrast viewer"
                     text:@"Open the post-contrast T1 (same series as used for the ΔT1 map) and choose it as Post in section 1."];
        return;
    }
    BOOL inside = ([_overlayInsideBox state] == NSControlStateValueOn);
    BOOL burden = ([_overlayPopup indexOfSelectedItem] == 1);
    long total = 0;
    for (DCMPix *p in [dt1 pixList]) total += (long)[p pwidth] * [p pheight];
    if (burden && (!_burdenClasses || _burdenViewer != dt1)) {
        [self showMessage:@"No tumour burden yet" text:@"Compute the tumour burden (section 3) for this ΔT1 map first."];
        return;
    }
    if (!burden && inside && (!_enhancing || _enhancingViewer != dt1)) {
        if (![self measureEnhancingQuietly:NO]) return;
    }

    unsigned char *labels = (unsigned char *)calloc((size_t)MAX(total, 1), 1);
    long counts[5] = {0};
    if (burden) {
        memcpy(labels, [_burdenClasses bytes], (size_t)MIN(total, (long)[_burdenClasses length]));
        for (long i = 0; i < total; i++) if (labels[i] < 5) counts[labels[i]]++;
    } else {
        double t = [_thresholdField doubleValue];
        const unsigned char *e = inside ? (const unsigned char *)[_enhancing bytes] : NULL;
        long offset = 0;
        for (DCMPix *p in [dt1 pixList]) {
            long size = (long)[p pwidth] * [p pheight];
            float *img = [p fImage];
            for (long i = 0; img && i < size; i++) {
                float v = img[i];
                if (!(isfinite(v) && v > t) || (e && !e[offset + i])) continue;
                unsigned char c = (v >= 3.5 * t) ? 3 : (v >= 2 * t ? 2 : 1);
                labels[offset + i] = c;
                counts[c]++;
            }
            offset += size;
        }
    }
    UMMPRemoveROIsWithPrefixes(target, @[UMMPOverlayPrefix]);
    double t = [_thresholdField doubleValue];
    if (burden) {
        RGBColor red = {65535, 0, 0}, yellow = {65535, 60000, 0}, green = {0, 52000, 0};
        UMMPAddBrushROIs(target, labels, 3, [UMMPOverlayPrefix stringByAppendingString:@" FTB high CBV"], red, 0.55f);
        UMMPAddBrushROIs(target, labels, 2, [UMMPOverlayPrefix stringByAppendingString:@" FTB intermediate"], yellow, 0.55f);
        UMMPAddBrushROIs(target, labels, 1, [UMMPOverlayPrefix stringByAppendingString:@" FTB low CBV"], green, 0.55f);
    } else {
        RGBColor yellow = {65535, 60000, 0}, orange = {65535, 32768, 0}, red = {65535, 0, 0};
        UMMPAddBrushROIs(target, labels, 1, [NSString stringWithFormat:@"%@ %g–%g", UMMPOverlayPrefix, t, 2 * t], yellow, 0.55f);
        UMMPAddBrushROIs(target, labels, 2, [NSString stringWithFormat:@"%@ %g–%g", UMMPOverlayPrefix, 2 * t, 3.5 * t], orange, 0.55f);
        UMMPAddBrushROIs(target, labels, 3, [NSString stringWithFormat:@"%@ ≥ %g", UMMPOverlayPrefix, 3.5 * t], red, 0.55f);
    }
    free(labels);
    [target needsDisplayUpdate];
    [[target window] orderFront:nil];
    [_overlayResult setTextColor:[NSColor labelColor]];
    if (burden)
        [_overlayResult setStringValue:[NSString stringWithFormat:@"FTB classes drawn on “%@”: high %ld, intermediate %ld, low %ld voxels (grey “no perfusion data” not drawn).",
                                        [[target window] title], counts[3], counts[2], counts[1]]];
    else
        [_overlayResult setStringValue:[NSString stringWithFormat:@"ΔT1 drawn on “%@”%@: %g–%g yellow %ld, %g–%g orange %ld, ≥ %g red %ld voxels.",
                                        [[target window] title], inside ? @" (inside your ROIs)" : @" (whole series: includes normal enhancement)",
                                        t, 2 * t, counts[1], 2 * t, 3.5 * t, counts[2], 3.5 * t, counts[3]]];
}

- (void)removeOverlay:(id)sender
{
    ViewerController *dt1 = [self viewerForPopup:_dt1Popup];
    ViewerController *target = dt1 ? [self overlayTarget:dt1] : [self viewerForPopup:_postPopup];
    if (!target) { NSBeep(); return; }
    UMMPRemoveROIsWithPrefixes(target, @[UMMPOverlayPrefix]);
    [target needsDisplayUpdate];
    [_overlayResult setStringValue:@"Overlay removed."];
}

#pragma mark - 4. Follow-up

- (void)loadPatientFor:(ViewerController *)v
{
    NSDictionary *info = v ? UMMPPatientInfo(v) : nil;
    NSString *key = UMMPPatientKey([info objectForKey:@"patientID"]);
    [_patientKey release];
    _patientKey = [key copy];
    [_history removeAllObjects];
    if (key) {
        NSArray *stored = [[[self domain] objectForKey:UMMP_DT1_HISTORY_KEY] objectForKey:key];
        if ([stored isKindOfClass:[NSArray class]]) [_history addObjectsFromArray:stored];
        [_history sortUsingComparator:^NSComparisonResult(id a, id b) {
            return [[a objectForKey:@"studyDate"] ?: @"" compare:[b objectForKey:@"studyDate"] ?: @""];
        }];
        [_patientLabel setStringValue:[NSString stringWithFormat:@"Patient: %@ (%@) — %lu saved measurement%@",
                                       [info objectForKey:@"patientName"] ?: @"?", [info objectForKey:@"patientID"],
                                       (unsigned long)[_history count], [_history count] == 1 ? @"" : @"s"]];
    } else {
        [_patientLabel setStringValue:v ? @"Patient: not readable from the DICOM header" : @"Patient: –"];
    }
    [_historyTable reloadData];
}

- (void)storeHistory
{
    if (!_patientKey) return;
    NSMutableDictionary *all = [NSMutableDictionary dictionaryWithDictionary:[[self domain] objectForKey:UMMP_DT1_HISTORY_KEY] ?: @{}];
    if ([_history count]) [all setObject:[[_history copy] autorelease] forKey:_patientKey];
    else [all removeObjectForKey:_patientKey];
    [self setDomainValue:all forKey:UMMP_DT1_HISTORY_KEY];
}

- (void)saveMeasurement:(id)sender
{
    ViewerController *dt1 = [self viewerForPopup:_dt1Popup];
    if (!_current || _enhancingViewer != dt1) {
        [self showMessage:@"Nothing to save" text:@"Measure the enhancing volume (section 2) first; the tumour burden (section 3) is saved with it when computed."];
        return;
    }
    [self loadPatientFor:dt1];
    if (!_patientKey) {
        [self showMessage:@"No patient ID" text:@"The patient ID could not be read from the DICOM header, so the measurement cannot be filed."];
        return;
    }
    NSMutableDictionary *m = [[_current mutableCopy] autorelease];
    [m setObject:[NSDate date] forKey:@"savedAt"];
    for (NSString *k in [m allKeys]) {           // no NaN / infinity in the stored list
        id x = [m objectForKey:k];
        if ([x isKindOfClass:[NSNumber class]] && !isfinite([x doubleValue])) [m removeObjectForKey:k];
    }
    NSString *uid = [m objectForKey:@"studyUID"], *date = [m objectForKey:@"studyDate"];
    NSInteger replace = NSNotFound;
    for (NSUInteger i = 0; i < [_history count]; i++) {
        NSDictionary *h = [_history objectAtIndex:i];
        if (([uid length] && [[h objectForKey:@"studyUID"] isEqual:uid]) || (![uid length] && [[h objectForKey:@"studyDate"] isEqual:date]))
            replace = (NSInteger)i;
    }
    if (replace != NSNotFound) [_history replaceObjectAtIndex:(NSUInteger)replace withObject:m];
    else [_history addObject:m];
    [_history sortUsingComparator:^NSComparisonResult(id a, id b) {
        return [[a objectForKey:@"studyDate"] ?: @"" compare:[b objectForKey:@"studyDate"] ?: @""];
    }];
    [self storeHistory];
    [self loadPatientFor:dt1];
    [_measureResult setStringValue:[[_measureResult stringValue] stringByAppendingString:
        replace != NSNotFound ? @" Saved (replaced the earlier measurement of this study)." : @" Saved."]];
}

- (void)deleteMeasurement:(id)sender
{
    NSInteger row = [_historyTable selectedRow];
    if (row < 0 || row >= (NSInteger)[_history count]) { NSBeep(); return; }
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    [alert setMessageText:@"Delete this measurement?"];
    [alert setInformativeText:[NSString stringWithFormat:@"Study of %@.", [[_history objectAtIndex:(NSUInteger)row] objectForKey:@"studyDate"]]];
    [alert addButtonWithTitle:@"Delete"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:[self window] completionHandler:^(NSModalResponse r) {
        if (r != NSAlertFirstButtonReturn || row >= (NSInteger)[_history count]) return;
        [_history removeObjectAtIndex:(NSUInteger)row];
        [self storeHistory];
        [_historyTable reloadData];
    }];
}

// Change of the enhancing volume of row i from baseline (row 0) and from the nadir before it.
- (void)changesForRow:(NSUInteger)i baseline:(double *)fromBaseline nadir:(double *)fromNadir
{
    double v = [[[_history objectAtIndex:i] objectForKey:@"enhancingVolume"] doubleValue];
    double base = [[[_history objectAtIndex:0] objectForKey:@"enhancingVolume"] doubleValue];
    double nadir = INFINITY;
    for (NSUInteger k = 0; k < i; k++) nadir = MIN(nadir, [[[_history objectAtIndex:k] objectForKey:@"enhancingVolume"] doubleValue]);
    *fromBaseline = (i > 0 && base > 0) ? (v - base) / base : NAN;
    *fromNadir = (i > 0 && nadir > 0 && isfinite(nadir)) ? (v - nadir) / nadir : NAN;
}

- (NSString *)assessmentForRow:(NSUInteger)i
{
    if (i == 0) return @"baseline";
    double b, n;
    [self changesForRow:i baseline:&b nadir:&n];
    if (isfinite(n) && n >= UMMP_PROGRESSION_FRACTION) return @"progression range (≥ +40 % nadir)";
    if (isfinite(b) && b <= UMMP_RESPONSE_FRACTION) return @"response range (≤ −65 % baseline)";
    return @"stable range";
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    return (NSInteger)[_history count];
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
    NSDictionary *h = [_history objectAtIndex:(NSUInteger)row];
    NSString *c = [column identifier];
    if ([c isEqualToString:@"date"]) return [h objectForKey:@"studyDate"];
    if ([c isEqualToString:@"enhancing"]) return [NSString stringWithFormat:@"%.2f", [[h objectForKey:@"enhancingVolume"] doubleValue]];
    if ([c isEqualToString:@"high"]) {
        NSNumber *f = [h objectForKey:@"ftbHigh"];
        return (f && isfinite([f doubleValue])) ? [NSString stringWithFormat:@"%.0f %%", 100 * [f doubleValue]] : @"–";
    }
    if ([c isEqualToString:@"assessment"]) return [self assessmentForRow:(NSUInteger)row];
    double b, n;
    [self changesForRow:(NSUInteger)row baseline:&b nadir:&n];
    if ([c isEqualToString:@"baseline"]) return UMMPPercent(b);
    if ([c isEqualToString:@"nadir"]) return UMMPPercent(n);
    return nil;
}

- (void)tableView:(NSTableView *)tableView willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
    if ([cell respondsToSelector:@selector(setFont:)]) [cell setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
}

- (void)exportHistory:(id)sender
{
    if (![_history count]) { NSBeep(); return; }
    NSSavePanel *panel = [NSSavePanel savePanel];
    [panel setNameFieldStringValue:@"dT1 follow-up.csv"];
    [panel beginSheetModalForWindow:[self window] completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSMutableString *csv = [NSMutableString stringWithString:
            @"study_date,roi_ml,enhancing_ml,mean_dT1,dT1_threshold,change_vs_baseline,change_vs_nadir,volumetric_range,"
            @"ftb_map,ftb_low_threshold,ftb_high_threshold,ftb_low,ftb_intermediate,ftb_high,ftb_covered_ml,mean_cbv,rois\n"];
        for (NSUInteger i = 0; i < [_history count]; i++) {
            NSDictionary *h = [_history objectAtIndex:i];
            double b, n;
            [self changesForRow:i baseline:&b nadir:&n];
            NSString *(^num)(NSString *) = ^NSString *(NSString *k) {
                NSNumber *x = [h objectForKey:k];
                return (x && isfinite([x doubleValue])) ? [NSString stringWithFormat:@"%.4g", [x doubleValue]] : @"";
            };
            [csv appendFormat:@"%@,%@,%@,%@,%@,%@,%@,%@,%@,%@,%@,%@,%@,%@,%@,%@,\"%@\"\n",
                [h objectForKey:@"studyDate"] ?: @"", num(@"roiVolume"), num(@"enhancingVolume"), num(@"meanDT1"), num(@"threshold"),
                isfinite(b) ? [NSString stringWithFormat:@"%.4f", b] : @"", isfinite(n) ? [NSString stringWithFormat:@"%.4f", n] : @"",
                [self assessmentForRow:i], [h objectForKey:@"ftbMap"] ?: @"", num(@"ftbLowThreshold"), num(@"ftbHighThreshold"),
                num(@"ftbLow"), num(@"ftbIntermediate"), num(@"ftbHigh"), num(@"ftbCoveredVolume"), num(@"meanCBV"),
                [[h objectForKey:@"roiNames"] ?: @"" stringByReplacingOccurrencesOfString:@"\"" withString:@"'"]];
        }
        NSError *err = nil;
        if (![csv writeToURL:[panel URL] atomically:YES encoding:NSUTF8StringEncoding error:&err])
            [self showMessage:@"Export failed" text:[err localizedDescription]];
    }];
}

@end
