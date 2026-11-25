//
//  UMMPSRCBV.h — standardised rCBV maps and their calibration (IsiX port). See UMMPStandardize.h.
//
//  The calibration is a list of cases in the defaults domain com.osirix.UMMPerfusion.DSC, key
//  "srcbvCases": per case its 11 raw landmarks, the mean raw value of its NAWM/ref ROIs (if any),
//  a title and the date it was added. The standard scale and the display unit are recomputed from
//  the cases every time, so adding or removing a case is enough. Export/Import shares the file
//  between colleagues who use the same DSC protocol.
//

#import <Foundation/Foundation.h>
#import <OsiriXAPI/PluginFilter.h>
#import <OsiriXAPI/ViewerController.h>
#import <OsiriXAPI/DCMPix.h>
#import "UMMPStandardize.h"
#import "UMMPIsiXSupport.h"

#define UMMP_SRCBV_DOMAIN @"com.osirix.UMMPerfusion.DSC"
#define UMMP_SRCBV_KEY @"srcbvCases"
#define UMMP_SRCBV_RECOMMENDED_CASES 10

static inline NSArray *UMMPSRCBVCases(void)
{
    id v = [[[NSUserDefaults standardUserDefaults] persistentDomainForName:UMMP_SRCBV_DOMAIN] objectForKey:UMMP_SRCBV_KEY];
    if (![v isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray *valid = [NSMutableArray array];
    for (id c in v) {
        if (![c isKindOfClass:[NSDictionary class]]) continue;
        NSArray *lm = [c objectForKey:@"landmarks"];
        if ([lm isKindOfClass:[NSArray class]] && [lm count] == UMMP_SRCBV_LANDMARKS) [valid addObject:c];
    }
    return valid;
}

static inline void UMMPSRCBVSaveCases(NSArray *cases)
{
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:
        [[NSUserDefaults standardUserDefaults] persistentDomainForName:UMMP_SRCBV_DOMAIN] ?: @{}];
    [d setObject:cases ?: @[] forKey:UMMP_SRCBV_KEY];
    [[NSUserDefaults standardUserDefaults] setPersistentDomain:d forName:UMMP_SRCBV_DOMAIN];
}

static inline void UMMPSRCBVCaseLandmarks(NSDictionary *c, double lm[UMMP_SRCBV_LANDMARKS])
{
    NSArray *a = [c objectForKey:@"landmarks"];
    for (int k = 0; k < UMMP_SRCBV_LANDMARKS; k++) lm[k] = [[a objectAtIndex:k] doubleValue];
}

// Standard landmarks and display unit from the stored cases. NO when there is no case.
// unitFromNAWM: YES when the unit is the mean standardised NAWM of the cases that have one.
static inline BOOL UMMPSRCBVCalibration(double standard[UMMP_SRCBV_LANDMARKS], double *unit,
                                        BOOL *unitFromNAWM, int *caseCount, int *nawmCount)
{
    NSArray *cases = UMMPSRCBVCases();
    int n = (int)[cases count];
    if (caseCount) *caseCount = n;
    if (nawmCount) *nawmCount = 0;
    if (n == 0) return NO;
    double *all = (double *)malloc(sizeof(double) * (size_t)n * UMMP_SRCBV_LANDMARKS);
    for (int c = 0; c < n; c++) UMMPSRCBVCaseLandmarks([cases objectAtIndex:c], all + (size_t)c * UMMP_SRCBV_LANDMARKS);
    UMMPSRCBVStandardFromCases(all, n, standard);
    double sum = 0; int m = 0;
    for (int c = 0; c < n; c++) {
        NSNumber *nawm = [[cases objectAtIndex:c] objectForKey:@"nawm"];
        if (![nawm isKindOfClass:[NSNumber class]] || !([nawm doubleValue] > 0)) continue;
        sum += UMMPSRCBVTransformValue([nawm doubleValue], all + (size_t)c * UMMP_SRCBV_LANDMARKS, standard);
        m++;
    }
    free(all);
    if (nawmCount) *nawmCount = m;
    double u = (m > 0) ? sum / m : standard[UMMP_SRCBV_MEDIAN_INDEX];
    if (unitFromNAWM) *unitFromNAWM = (m > 0);
    if (unit) *unit = (u > 0 && isfinite(u)) ? u : 1.0;
    return YES;
}

static inline NSString *UMMPSRCBVCalibrationSummary(void)
{
    double standard[UMMP_SRCBV_LANDMARKS], unit; BOOL fromNAWM; int n = 0, nawm = 0;
    if (!UMMPSRCBVCalibration(standard, &unit, &fromNAWM, &n, &nawm))
        return @"Calibration: no case yet. Add the blood-volume (or rCBV) maps of patients scanned with your DSC protocol.";
    NSString *unitText = fromNAWM
        ? [NSString stringWithFormat:@"1 = mean NAWM of %d case%@", nawm, nawm == 1 ? @"" : @"s"]
        : @"1 = median brain (no case had an NAWM ROI)";
    NSString *advice = (n < UMMP_SRCBV_RECOMMENDED_CASES)
        ? [NSString stringWithFormat:@" At least %d cases recommended.", UMMP_SRCBV_RECOMMENDED_CASES] : @"";
    return [NSString stringWithFormat:@"Calibration: %d case%@, %@.%@", n, n == 1 ? @"" : @"s", unitText, advice];
}

// Landmarks of a whole map viewer (all slices). Returns the number of usable pixels, 0 if unusable.
static inline long UMMPSRCBVMapLandmarks(ViewerController *map, double lm[UMMP_SRCBV_LANDMARKS])
{
    long total = 0;
    for (DCMPix *pix in [map pixList]) total += (long)[pix pwidth] * [pix pheight];
    if (total <= 0) return 0;
    float *values = (float *)malloc(sizeof(float) * (size_t)total);
    long n = 0;
    for (DCMPix *pix in [map pixList]) {
        float *img = [pix fImage];
        if (!img) continue;
        long size = (long)[pix pwidth] * [pix pheight];
        memcpy(values + n, img, sizeof(float) * (size_t)size);
        n += size;
    }
    long usable = UMMPSRCBVLandmarks(values, n, lm);
    free(values);
    return usable;
}

// Adds a map (blood volume or rCBV) to the calibration. NAWM: the mean of ROIs named "NAWM"/"ref"
// on the map, else on roiSource (the DSC series), if any. Returns nil or an error text.
static inline NSString *UMMPSRCBVAddCase(ViewerController *map, ViewerController *roiSource, NSString *title)
{
    double lm[UMMP_SRCBV_LANDMARKS];
    long usable = UMMPSRCBVMapLandmarks(map, lm);
    if (!usable)
        return [NSString stringWithFormat:@"The map has fewer than %d computed pixels, or all of them have the same value.", UMMP_SRCBV_MIN_PIXELS];
    NSMutableArray *a = [NSMutableArray array];
    for (int k = 0; k < UMMP_SRCBV_LANDMARKS; k++) [a addObject:@(lm[k])];
    for (NSDictionary *existing in UMMPSRCBVCases()) {
        double e[UMMP_SRCBV_LANDMARKS]; BOOL same = YES;
        UMMPSRCBVCaseLandmarks(existing, e);
        for (int k = 0; k < UMMP_SRCBV_LANDMARKS; k++) if (fabs(e[k] - lm[k]) > 1e-6 * fabs(lm[k])) same = NO;
        if (same) return @"This map is already in the calibration.";
    }
    NSMutableDictionary *c = [NSMutableDictionary dictionaryWithObjectsAndKeys:
        a, @"landmarks", @(usable), @"pixels", [NSDate date], @"added", title ?: @"Map", @"title", nil];
    NSString *refNames = nil;
    double nawm = UMMPReferenceMeanFromNamedROIs(map, &refNames);
    if (!(isfinite(nawm) && nawm > 0) && roiSource) nawm = UMMPReferenceMeanFromNamedROIsIn(roiSource, map, &refNames);
    if (isfinite(nawm) && nawm > 0) [c setObject:@(nawm) forKey:@"nawm"];
    NSMutableArray *cases = [NSMutableArray arrayWithArray:UMMPSRCBVCases()];
    [cases addObject:c];
    UMMPSRCBVSaveCases(cases);
    NSLog(@"UMMP sRCBV: case added (%@, %ld pixels, p1 %.4g, median %.4g, p99.8 %.4g%@)", title, usable,
          lm[0], lm[UMMP_SRCBV_MEDIAN_INDEX], lm[UMMP_SRCBV_LANDMARKS - 1],
          (isfinite(nawm) && nawm > 0) ? [NSString stringWithFormat:@", NAWM %.4g", nawm] : @", no NAWM ROI");
    return nil;
}

// A new viewer with the sRCBV map of `map`, or nil (error text in *error). Colour table, window 0–4.
static inline ViewerController *UMMPSRCBVCreateMap(PluginFilter *filter, ViewerController *map, NSString **error)
{
    double standard[UMMP_SRCBV_LANDMARKS], unit, lm[UMMP_SRCBV_LANDMARKS];
    BOOL fromNAWM; int n = 0, nawm = 0;
    if (!UMMPSRCBVCalibration(standard, &unit, &fromNAWM, &n, &nawm)) {
        if (error) *error = @"No sRCBV calibration yet: add calibration cases in DSC Tools first.";
        return nil;
    }
    if (!UMMPSRCBVMapLandmarks(map, lm)) {
        if (error) *error = [NSString stringWithFormat:@"The map has fewer than %d computed pixels, or all of them have the same value.", UMMP_SRCBV_MIN_PIXELS];
        return nil;
    }
    ViewerController *out = [filter duplicateViewer:map deleteROIs:NO];
    if (!out) { if (error) *error = @"Could not create a viewer."; return nil; }
    for (DCMPix *pix in [out pixList]) {
        float *img = [pix fImage];
        if (img) UMMPSRCBVTransformImage(img, (long)[pix pwidth] * [pix pheight], lm, standard, unit, -1.0f);
    }
    NSString *name = [NSString stringWithFormat:@"sRCBV (calibration %d case%@, %@)", n, n == 1 ? @"" : @"s",
                      fromNAWM ? @"1 = NAWM" : @"1 = median brain"];
    [[[out pixList] objectAtIndex:0] setGeneratedName:name];
    [out needsDisplayUpdate];
    ViewerController *v[] = {out};
    UMMPApplyMapAppearance(v, 1);
    [out setWL:2.0 WW:4.0];
    NSLog(@"UMMP sRCBV: %@; map landmarks p1 %.4g, median %.4g, p99.8 %.4g; unit %.4g", name,
          lm[0], lm[UMMP_SRCBV_MEDIAN_INDEX], lm[UMMP_SRCBV_LANDMARKS - 1], unit);
    return out;
}
