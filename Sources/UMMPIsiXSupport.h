//
//  UMMPIsiXSupport.h — helpers added for the IsiX port of UMMPerfusion.
//

#import <Foundation/Foundation.h>
#import <OsiriXAPI/ViewerController.h>
#import <OsiriXAPI/DCMPix.h>
#if __has_include(<OsiriXAPI/ViewerController+ROI.h>)   // IsiX; in Horos these are in ViewerController.h
#import <OsiriXAPI/ViewerController+ROI.h>
#endif
#import <OsiriXAPI/ROI.h>
#include <math.h>
#include <string.h>
#include <stdlib.h>

// Pixels where a fit or the deconvolution failed come out as NaN or ±Inf.
// IsiX smooths maps when it displays them, and a non-finite pixel blanks the
// whole neighbourhood the filter reads from: black rectangles on the map.
// Such pixels (no usable signal, see UMMPFastDeconvolution.m) are set to -1, the plugin's
// "not computed" value, before the viewers are redrawn: they stay distinct from real zeros.
static inline void UMMPSanitizeMapViewers(ViewerController **viewers, size_t count)
{
    for (size_t v = 0; v < count; v++) {
        ViewerController *viewer = viewers[v];
        if (!viewer) continue;
        for (DCMPix *pix in [viewer pixList]) {
            float *image = [pix fImage];
            if (!image) continue;
            long n = (long)[pix pwidth] * (long)[pix pheight];
            for (long i = 0; i < n; i++)
                if (!isfinite(image[i])) image[i] = -1.0f;
        }
    }
}

#pragma mark - DCE pixel maps (IsiX port)

// Options of the DCE pixel maps, edited in the DSC Tools window (domain com.osirix.UMMPerfusion.DSC).
static inline BOOL UMMPDCEOption(NSString *key, BOOL fallback)
{
    id v = [[[NSUserDefaults standardUserDefaults] persistentDomainForName:@"com.osirix.UMMPerfusion.DSC"] objectForKey:key];
    return v ? [v boolValue] : fallback;
}

static inline double UMMPDCEMaskFraction(void)
{
    id v = [[[NSUserDefaults standardUserDefaults] persistentDomainForName:@"com.osirix.UMMPerfusion.DSC"] objectForKey:@"maskFraction"];
    double f = v ? [v doubleValue] : 0.10;
    return (f >= 0.0 && f < 1.0) ? f : 0.10;
}

static int UMMPCompareFloatValues(const void *a, const void *b)
{
    float x = *(const float *)a, y = *(const float *)b;
    return (x > y) - (x < y);
}

// Mean of the first bl frames (from start) of one slice; caller frees.
static inline float *UMMPBaselineImage(NSArray *srcPix, int start, int bl, NSUInteger slice, long size)
{
    float *s0 = (float *)calloc((size_t)size, sizeof(float));
    if (bl < 1) bl = 1;
    for (int t = 0; t < bl; t++) {
        DCMPix *pix = [[srcPix objectAtIndex:start + t] objectAtIndex:slice];
        float *img = [pix fImage];
        if (!img) continue;
        for (long i = 0; i < size; i++) s0[i] += img[i];
    }
    for (long i = 0; i < size; i++) s0[i] /= bl;
    return s0;
}

// Brain-mask threshold: fraction × 99th percentile of the baseline signal over the slices used.
static inline double UMMPMaskThreshold(NSArray *srcPix, int start, int bl, int sliceFrom, int sliceTo, double fraction)
{
    NSArray *frame = [srcPix objectAtIndex:start];
    if (sliceFrom < 0) sliceFrom = 0;
    if (sliceTo >= (int)[frame count]) sliceTo = (int)[frame count] - 1;
    if (sliceTo < sliceFrom) return 0.0;
    DCMPix *pix0 = [frame objectAtIndex:sliceFrom];
    long size = (long)[pix0 pwidth] * [pix0 pheight];
    long total = size * (sliceTo - sliceFrom + 1), n = 0;
    float *values = (float *)malloc(sizeof(float) * (size_t)total);
    for (int s = sliceFrom; s <= sliceTo; s++) {
        float *s0 = UMMPBaselineImage(srcPix, start, bl, (NSUInteger)s, size);
        for (long i = 0; i < size; i++) if (s0[i] > 0 && isfinite(s0[i])) values[n++] = s0[i];
        free(s0);
    }
    double threshold = 0.0;
    if (n > 0) {
        qsort(values, (size_t)n, sizeof(float), UMMPCompareFloatValues);
        threshold = fraction * values[(long)(0.99 * (n - 1))];
    }
    free(values);
    return threshold;
}

// 3×3 mean of one frame over the pixels that are computed (not -1); edges use the neighbours available.
static inline void UMMPSmooth3x3(double *img, int width, int height)
{
    double *copy = (double *)malloc(sizeof(double) * (size_t)width * height);
    memcpy(copy, img, sizeof(double) * (size_t)width * height);
    for (int y = 0; y < height; y++)
        for (int x = 0; x < width; x++) {
            long i = (long)y * width + x;
            if (copy[i] == -1.0) continue;
            double sum = 0; int count = 0;
            for (int dy = -1; dy <= 1; dy++)
                for (int dx = -1; dx <= 1; dx++) {
                    int xx = x + dx, yy = y + dy;
                    if (xx < 0 || yy < 0 || xx >= width || yy >= height) continue;
                    double v = copy[(long)yy * width + xx];
                    if (v == -1.0 || !isfinite(v)) continue;
                    sum += v; count++;
                }
            if (count) img[i] = sum / count;
        }
    free(copy);
}

// Window of a new map viewer: 2nd-98th percentile of its computed pixels (-1 left out). The map
// viewers otherwise keep the window of the source series, far too wide for maps.
static inline void UMMPAutoWindowMapViewers(ViewerController **viewers, size_t count)
{
    for (size_t v = 0; v < count; v++) {
        ViewerController *viewer = viewers[v];
        if (!viewer) continue;
        long total = 0;
        for (DCMPix *pix in [viewer pixList]) total += (long)[pix pwidth] * [pix pheight];
        if (total <= 0) continue;
        float *values = (float *)malloc(sizeof(float) * (size_t)total);
        long n = 0;
        for (DCMPix *pix in [viewer pixList]) {
            float *img = [pix fImage];
            if (!img) continue;
            long size = (long)[pix pwidth] * [pix pheight];
            for (long i = 0; i < size; i++) if (isfinite(img[i]) && img[i] != -1.0f) values[n++] = img[i];
        }
        if (n > 10) {
            qsort(values, (size_t)n, sizeof(float), UMMPCompareFloatValues);
            double lo = values[(long)(0.02 * (n - 1))], hi = values[(long)(0.98 * (n - 1))];
            // Maps that are 0 almost everywhere (Ktrans in brain with an intact barrier): take the
            // upper end from the non-zero pixels, so the lesion is not saturated.
            long first = 0;
            while (first < n && values[first] <= 0.0f) first++;
            if (n - first > 10) hi = values[first + (long)(0.98 * (n - first - 1))];
            if (!(hi > lo)) hi = lo + (fabs(lo) > 0 ? fabs(lo) : 1.0);
            [viewer setWL:(float)(0.5 * (lo + hi)) WW:(float)(hi - lo)];
        }
        free(values);
    }
}

// Colour table for new maps (DSC Tools; "" = keep grey). Default Rainbow2.
static inline NSString *UMMPMapCLUTName(void)
{
    id v = [[[NSUserDefaults standardUserDefaults] persistentDomainForName:@"com.osirix.UMMPerfusion.DSC"] objectForKey:@"mapCLUT"];
    return [v isKindOfClass:[NSString class]] ? v : @"Rainbow2";
}

// Colour table, then a window fitted to the values, for every new map viewer.
static inline void UMMPApplyMapAppearance(ViewerController **viewers, size_t count)
{
    NSString *clut = UMMPMapCLUTName();
    for (size_t v = 0; v < count; v++)
        if (viewers[v] && [clut length]) [viewers[v] ApplyCLUTString:clut];
    UMMPAutoWindowMapViewers(viewers, count);
}

// Mean of the computed pixels (not -1) of `map` inside every ROI whose name contains "nawm" or "ref",
// taking the ROIs from `roiSource` (the map itself or the DSC series it was computed from; same
// matrix and slices). All time frames of roiSource are searched; the first frame holding such ROIs
// is used, so an ROI is not counted twice. NAN when there is none. title receives the names used.
static inline double UMMPReferenceMeanFromNamedROIsIn(ViewerController *roiSource, ViewerController *map, NSString **title)
{
    double sum = 0; long n = 0;
    NSMutableArray *names = [NSMutableArray array];
    NSArray *pixList = [map pixList];
    if (!roiSource || !pixList) { if (title) *title = @""; return NAN; }
    int frames = MAX(1, (int)[roiSource maxMovieIndex]);
    int current = (int)[roiSource curMovieIndex];
    for (int k = 0; k < frames && n == 0; k++) {
        int t = (k == 0) ? current : (k <= current ? k - 1 : k);   // current frame first, then the others
        if (t < 0 || t >= frames) continue;
        NSArray *perSlice = [roiSource roiList:t];
        for (NSUInteger s = 0; s < [perSlice count] && s < [pixList count]; s++) {
            DCMPix *pix = [pixList objectAtIndex:s];
            for (ROI *roi in [perSlice objectAtIndex:s]) {
                NSString *name = [[roi name] lowercaseString];
                if (!name || ([name rangeOfString:@"nawm"].location == NSNotFound && [name rangeOfString:@"ref"].location == NSNotFound)) continue;
                long count = 0;
                float *values = [pix getROIValue:&count :roi :NULL];
                for (long i = 0; i < count; i++)
                    if (isfinite(values[i]) && values[i] != -1.0f) { sum += values[i]; n++; }
                if (values) free(values);
                if (![names containsObject:[roi name]]) [names addObject:[roi name]];
            }
        }
    }
    if (title) *title = [names componentsJoinedByString:@", "];
    return n > 0 ? sum / n : NAN;
}

static inline double UMMPReferenceMeanFromNamedROIs(ViewerController *map, NSString **title)
{
    return UMMPReferenceMeanFromNamedROIsIn(map, map, title);
}

// Median of the computed, positive pixels of a map (whole brain inside the mask).
static inline double UMMPMedianOfMap(ViewerController *map)
{
    long total = 0;
    for (DCMPix *pix in [map pixList]) total += (long)[pix pwidth] * [pix pheight];
    if (total <= 0) return NAN;
    float *values = (float *)malloc(sizeof(float) * (size_t)total);
    long n = 0;
    for (DCMPix *pix in [map pixList]) {
        float *img = [pix fImage];
        long size = (long)[pix pwidth] * [pix pheight];
        for (long i = 0; img && i < size; i++) if (isfinite(img[i]) && img[i] > 0.0f) values[n++] = img[i];
    }
    double median = NAN;
    if (n > 0) {
        qsort(values, (size_t)n, sizeof(float), UMMPCompareFloatValues);
        median = (n % 2) ? values[n / 2] : 0.5 * (values[n / 2 - 1] + values[n / 2]);
    }
    free(values);
    return median;
}
