//
//  UMMPConcentration.h — DCE signal → contrast-agent concentration (IsiX port).
//
//  The original plugin fits (S − S0)/S0 or S − S0 as if it were concentration. On a spoiled
//  gradient-echo (SPGR / FLASH / VIBE / LAVA / THRIVE) DCE the signal is not proportional to the
//  concentration: the arterial curve saturates far more than tissue, and the bias depends on the
//  tissue T1 (Tests/test_tofts.c: ve −26…−44 %, vp +98…+159 %). With the conversion the fit gets
//  concentration in mmol/L and Ktrans, ve, vp are on the scale of the literature.
//
//  SPGR steady state:  S = M0 · sin α · (1 − E) / (1 − cos α · E),  E = exp(−TR · R1)
//  With S0 the baseline (mean of the first frames) and R10 = 1/T10 known:
//      q = S/S0,  A = (1 − E0)/(1 − cos α · E0),  B = q · A,  E = (1 − B)/(1 − B · cos α)
//      R1 = −ln(E)/TR,   C = (R1 − R10) / r1
//  T10 comes from a T1 map (per pixel) or from fixed values (blood for the arterial curve,
//  tissue otherwise). TR and α from the DICOM header of the DCE series; r1 of the agent.
//  Points where B ≥ 1 (signal above what any R1 can give: noise, inflow) are capped.
//

#ifndef UMMP_CONCENTRATION_H
#define UMMP_CONCENTRATION_H

#include <math.h>

// Signal curve → concentration (mmol/L), in place. T10 and TR in s, flip angle in degrees, r1 in
// /mM/s. bl: baseline frames. Returns the number of capped points, or −1 when nothing can be
// converted (no baseline signal or invalid parameters; the curve is then set to 0).
static inline int UMMPSignalToConcentration(float *s, int n, int bl, double T10, double TR, double flipDeg, double r1)
{
    if (!s || n <= 0) return -1;
    if (bl < 1) bl = 1;
    if (bl > n) bl = n;
    double s0 = 0;
    for (int i = 0; i < bl; i++) s0 += s[i];
    s0 /= bl;
    double a = flipDeg * M_PI / 180.0, ca = cos(a);
    if (!(s0 > 0) || !(T10 > 0) || !(TR > 0) || !(r1 > 0) || !(flipDeg > 0 && flipDeg < 180)) {
        for (int i = 0; i < n; i++) s[i] = 0.0f;
        return -1;
    }
    double R10 = 1.0 / T10, E0 = exp(-TR * R10);
    double A = (1.0 - E0) / (1.0 - ca * E0);
    const double Bmax = 1.0 - 1e-4;
    int capped = 0;
    for (int i = 0; i < n; i++) {
        double q = s[i] / s0;
        if (!isfinite(q)) q = 1.0;
        double B = q * A;
        if (B >= Bmax) { B = Bmax; capped++; }
        if (B < 0) B = 0;
        double E = (1.0 - B) / (1.0 - B * ca);
        double R1 = (E > 0) ? -log(E) / TR : R10;
        s[i] = (float)((R1 - R10) / r1);
    }
    return capped;
}

// Typical pre-contrast T1 (s) when no T1 map is used. Blood: ~1.6 s at 1.5 T, ~1.9 s at 3 T.
// Tissue: a brain-lesion / grey-matter-like value (white matter is shorter, oedema longer).
static inline double UMMPDefaultBloodT10(double fieldT) { return fieldT > 2.0 ? 1.93 : 1.55; }
static inline double UMMPDefaultTissueT10(double fieldT) { return fieldT > 2.0 ? 1.60 : 1.30; }

#ifdef __OBJC__
#import <Foundation/Foundation.h>
#import <OsiriXAPI/ViewerController.h>
#import <OsiriXAPI/DCMPix.h>
#import <OsiriXAPI/ROI.h>
#import "DCMObject.h"
#import "UMMPDeltaT1.h"

#define UMMP_CONC_DOMAIN @"com.osirix.UMMPerfusion.DSC"

// Conversion settings of one computation, prepared on the main thread before the fit loops.
// (Each source file that converts has its own copy: prepare and use in the same file.)
typedef struct {
    int mode;               // 0 signal enhancement as chosen in the panel, 1 fixed T1, 2 T1 map
    double TR, flip, r1;    // s, degrees, /mM/s
    double t10Blood, t10Tissue, field;
    float **t10Slices;      // mode 2: T10 (s) per DCE slice and pixel, NAN where the map has none
    long slices;
} UMMPConcSettings;

static UMMPConcSettings UMMPConc = {0, 0, 0, 0, 0, 0, 0, NULL, 0};

static inline id UMMPConcDefault(NSString *key)
{
    return [[[NSUserDefaults standardUserDefaults] persistentDomainForName:UMMP_CONC_DOMAIN] objectForKey:key];
}

static inline double UMMPConcNumber(id v)
{
    if ([v respondsToSelector:@selector(doubleValue)]) return [v doubleValue];
    return NAN;
}

// TR (ms), flip angle (degrees) and field strength (T) of a series' first image; NAN when absent.
static inline void UMMPConcReadHeader(ViewerController *v, double *tr, double *flip, double *field)
{
    *tr = *flip = *field = NAN;
    DCMPix *p0 = [[v pixList] count] ? [[v pixList] objectAtIndex:0] : nil;
    if (!p0) return;
    @try {
        DCMObject *o = [p0 sourceFile] ? [DCMObject objectWithContentsOfFile:[p0 sourceFile] decodingPixelData:NO] : nil;
        *tr = UMMPConcNumber([o attributeValueForKey:@"0018,0080"]);
        *flip = UMMPConcNumber([o attributeValueForKey:@"0018,1314"]);
        *field = UMMPConcNumber([o attributeValueForKey:@"0018,0087"]);
    } @catch (NSException *e) {}
    if (!(*tr > 0)) *tr = [[p0 repetitiontime] doubleValue];
    if (!(*flip > 0)) *flip = [[p0 flipAngle] doubleValue];
    if (*field > 100) *field /= 10000.0;     // some headers give gauss
    if (!(*tr > 0)) *tr = NAN;
    if (!(*flip > 0)) *flip = NAN;
    if (!(*field > 0)) *field = NAN;
}

// The open viewer whose window title was chosen as the T1 map in DSC Tools.
static inline ViewerController *UMMPConcT1MapViewer(void)
{
    NSString *title = UMMPConcDefault(@"dceT1MapTitle");
    if (![title length]) return nil;
    for (ViewerController *v in [ViewerController getDisplayed2DViewers])
        if ([[[v window] title] isEqualToString:title]) return v;
    return nil;
}

static inline void UMMPConcFree(void)
{
    if (UMMPConc.t10Slices) {
        for (long s = 0; s < UMMPConc.slices; s++) free(UMMPConc.t10Slices[s]);
        free(UMMPConc.t10Slices);
    }
    UMMPConc.t10Slices = NULL;
    UMMPConc.slices = 0;
}

// Reads the settings (DSC Tools) and the DCE series' header; with a T1 map, samples it at every
// pixel of the DCE slices (scanner coordinates: the map may have other slices or orientation).
// Returns nil, or a text for the user when the conversion cannot be done (the caller stops).
// summary receives one line for the log / report.
static inline NSString *UMMPConcPrepare(ViewerController *dce, NSString **summary)
{
    UMMPConcFree();
    memset(&UMMPConc, 0, sizeof(UMMPConc));
    id modeValue = UMMPConcDefault(@"dceConversion");
    UMMPConc.mode = modeValue ? (int)[modeValue integerValue] : 0;
    if (summary) *summary = @"input: signal enhancement (no conversion)";
    if (UMMPConc.mode == 0) return nil;

    double tr = NAN, flip = NAN, field = NAN;
    UMMPConcReadHeader(dce, &tr, &flip, &field);
    double trOverride = UMMPConcNumber(UMMPConcDefault(@"dceTR")), flipOverride = UMMPConcNumber(UMMPConcDefault(@"dceFlip"));
    if (trOverride > 0) tr = trOverride;
    if (flipOverride > 0) flip = flipOverride;
    if (!(tr > 0) || !(flip > 0))
        return @"TR or flip angle is missing in the DICOM header of the DCE series: enter them in DSC Tools › DCE concentration.";
    if (!(field > 0)) field = 1.5;
    double r1 = UMMPConcNumber(UMMPConcDefault(@"dceR1"));
    double tb = UMMPConcNumber(UMMPConcDefault(@"dceT10Blood")), tt = UMMPConcNumber(UMMPConcDefault(@"dceT10Tissue"));
    UMMPConc.TR = tr / 1000.0;
    UMMPConc.flip = flip;
    UMMPConc.r1 = (r1 > 0) ? r1 : 4.5;
    UMMPConc.field = field;
    UMMPConc.t10Blood = (tb > 0) ? tb : UMMPDefaultBloodT10(field);
    UMMPConc.t10Tissue = (tt > 0) ? tt : UMMPDefaultTissueT10(field);

    NSString *mapNote = @"fixed tissue T1";
    if (UMMPConc.mode == 2) {
        ViewerController *map = UMMPConcT1MapViewer();
        if (!map)
            return @"The T1 map chosen in DSC Tools › DCE concentration is not open. Open it, or choose “fixed T1”.";
        NSArray *mPix = [map pixList];
        int ns = (int)[mPix count];
        UMMPDT1Slice *st = (UMMPDT1Slice *)calloc((size_t)MAX(ns, 1), sizeof(UMMPDT1Slice));
        double interval = 1.0;
        if (ns > 1) {
            DCMPix *a = [mPix objectAtIndex:0], *b = [mPix objectAtIndex:1];
            interval = sqrt(pow([b originX] - [a originX], 2) + pow([b originY] - [a originY], 2) + pow([b originZ] - [a originZ], 2));
        }
        // Units: a T1 map in ms has a median far above 20.
        long total = 0, nv = 0;
        for (DCMPix *p in mPix) total += (long)[p pwidth] * [p pheight];
        float *vals = (float *)malloc(sizeof(float) * (size_t)MAX(total, 1));
        for (DCMPix *p in mPix) {
            float *img = [p fImage];
            long size = (long)[p pwidth] * [p pheight];
            for (long i = 0; img && i < size; i++) if (isfinite(img[i]) && img[i] > 0) vals[nv++] = img[i];
        }
        double median = 0;
        if (nv) {
            long k = nv / 2;   // quick select-free estimate: sort
            qsort(vals, (size_t)nv, sizeof(float), UMMPDT1CompareFloats);
            median = vals[k];
        }
        free(vals);
        double toSeconds = (median > 20.0) ? 0.001 : 1.0;
        for (int k = 0; k < ns; k++) {
            DCMPix *p = [mPix objectAtIndex:k];
            double o[9];
            [p orientationDouble:o];
            UMMPDT1Slice *s = st + k;
            s->o[0] = [p originX]; s->o[1] = [p originY]; s->o[2] = [p originZ];
            for (int j = 0; j < 3; j++) { s->row[j] = o[j]; s->col[j] = o[3 + j]; }
            UMMPDT1SliceSetNormal(s);
            s->sx = [p pixelSpacingX] > 0 ? [p pixelSpacingX] : 1; s->sy = [p pixelSpacingY] > 0 ? [p pixelSpacingY] : 1;
            s->halfThickness = 0.5 * MAX([p sliceThickness], interval);
            s->w = [p pwidth]; s->h = [p pheight];
            s->img = [p fImage];
        }
        NSArray *dPix = [dce pixList];
        UMMPConc.slices = (long)[dPix count];
        UMMPConc.t10Slices = (float **)calloc((size_t)MAX(UMMPConc.slices, 1), sizeof(float *));
        long covered = 0, pixels = 0;
        for (long s = 0; s < UMMPConc.slices; s++) {
            DCMPix *p = [dPix objectAtIndex:(NSUInteger)s];
            long w = [p pwidth], h = [p pheight];
            double o[9];
            [p orientationDouble:o];
            double ox = [p originX], oy = [p originY], oz = [p originZ], sx = [p pixelSpacingX], sy = [p pixelSpacingY];
            float *t = (float *)malloc(sizeof(float) * (size_t)(w * h));
            for (long y = 0; y < h; y++)
                for (long x = 0; x < w; x++) {
                    double pt[3] = {ox + x * sx * o[0] + y * sy * o[3], oy + x * sx * o[1] + y * sy * o[4], oz + x * sx * o[2] + y * sy * o[5]};
                    float v = UMMPDT1SampleStack(st, ns, pt);
                    double t10 = isfinite(v) ? v * toSeconds : NAN;
                    // Implausible values (fit failures of the map) fall back to the fixed tissue T1.
                    t[y * w + x] = (t10 > 0.1 && t10 < 6.0) ? (float)t10 : NAN;
                    if (isfinite(t[y * w + x])) covered++;
                    pixels++;
                }
            UMMPConc.t10Slices[s] = t;
        }
        free(st);
        mapNote = [NSString stringWithFormat:@"T1 map “%@” (%@, %.0f %% of DCE pixels covered; others %.2f s)",
                   [[map window] title], toSeconds < 1 ? @"ms" : @"s", pixels ? 100.0 * covered / pixels : 0.0, UMMPConc.t10Tissue];
    }
    if (summary)
        *summary = [NSString stringWithFormat:@"input: concentration (SPGR; TR %.2f ms, flip %.0f°, %.1f T, r1 %.2f /mM/s, "
                    @"blood T1 %.2f s, %@)", UMMPConc.TR * 1000, UMMPConc.flip, UMMPConc.field, UMMPConc.r1,
                    UMMPConc.t10Blood, UMMPConc.mode == 2 ? mapNote : [NSString stringWithFormat:@"tissue T1 %.2f s", UMMPConc.t10Tissue]];
    return nil;
}

// Tissue T10 of one DCE pixel (slice, index in the slice).
static inline double UMMPConcTissueT10(long slice, long index)
{
    if (UMMPConc.mode == 2 && UMMPConc.t10Slices && slice >= 0 && slice < UMMPConc.slices) {
        float v = UMMPConc.t10Slices[slice][index];
        if (isfinite(v)) return v;
    }
    return UMMPConc.t10Tissue;
}

// Mean tissue T10 inside an ROI of the DCE series (ROI-based fits).
static inline double UMMPConcTissueT10ForROI(ROI *roi, DCMPix *pix, long slice)
{
    if (UMMPConc.mode != 2 || !roi || !pix) return UMMPConc.t10Tissue;
    long count = 0;
    float *loc = NULL;
    float *values = [pix getROIValue:&count :roi :&loc];
    double sum = 0; long n = 0;
    long w = [pix pwidth], h = [pix pheight];
    for (long i = 0; loc && i < count; i++) {
        long x = lroundf(loc[2 * i]), y = lroundf(loc[2 * i + 1]);
        if (x < 0 || y < 0 || x >= w || y >= h) continue;
        double t = UMMPConcTissueT10(slice, y * w + x);
        if (t > 0) { sum += t; n++; }
    }
    if (values) free(values);
    if (loc) free(loc);
    return n ? sum / n : UMMPConc.t10Tissue;
}

// Replaces lmuEnhancement for the DCE tracers (0 relative, 1 absolute signal enhancement) when a
// conversion is chosen; the T2*-DSC tracer and mode 0 keep the original behaviour.
void lmuEnhancement(float *aif, int n, int bl, int tracer);
static inline void UMMPDCEEnhance(float *curve, int n, int bl, int tracer, double T10)
{
    if (UMMPConc.mode == 0 || tracer > 1) { lmuEnhancement(curve, n, bl, tracer); return; }
    UMMPSignalToConcentration(curve, n, bl, T10, UMMPConc.TR, UMMPConc.flip, UMMPConc.r1);
}
#endif

#endif
