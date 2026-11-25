//
//  UMMPDeltaT1.h — ΔT1 map from a pre- and a post-contrast T1-weighted series (IsiX port). Plain C.
//
//  As in the ΔT1 maps of Schmainda's group (Bedekar et al. 2010; Prah et al. AJNR 2015), the two
//  series are brought to a common intensity scale before they are subtracted, so that tissue that
//  does not enhance comes out near 0 whatever the scanner gain of each series:
//
//   - head mask: pixels of the PRE series above a fraction (default 10 %) of its 99th percentile
//   - each series is divided by the median of its own pixels inside that mask (mostly white and grey
//     matter, which do not enhance; the small enhancing volume barely moves a median)
//   - ΔT1 = post / median(post) − pre / median(pre), in units of the median head signal
//     (0 = no change, 0.3 = enhancement by 30 % of the typical tissue signal); 0 outside the mask
//
//  This is an intensity normalisation per pair, not the trained standardisation of IB Delta Suite:
//  thresholds from that software do not transfer. Both series must have the same geometry
//  (same matrix, slices and position: the same 3D sequence, or the post series resampled onto
//  the pre series) and the same weighting. Motion between them shows as rims of ±ΔT1.
//

#ifndef UMMP_DELTAT1_H
#define UMMP_DELTAT1_H

#include <math.h>
#include <stdlib.h>
#include <string.h>

static int UMMPDT1CompareFloats(const void *a, const void *b)
{
    float x = *(const float *)a, y = *(const float *)b;
    return (x > y) - (x < y);
}

// Percentile (0–100) of the finite values; NAN if none.
static inline double UMMPDT1Percentile(const float *values, long count, double percentile)
{
    float *v = (float *)malloc(sizeof(float) * (size_t)(count > 0 ? count : 1));
    long n = 0;
    for (long i = 0; i < count; i++) if (isfinite(values[i])) v[n++] = values[i];
    double r = NAN;
    if (n > 0) {
        qsort(v, (size_t)n, sizeof(float), UMMPDT1CompareFloats);
        double rank = percentile / 100.0 * (double)(n - 1);
        long lo = (long)floor(rank);
        r = (lo >= n - 1) ? v[n - 1] : v[lo] + (rank - lo) * ((double)v[lo + 1] - v[lo]);
    }
    free(v);
    return r;
}

// Median of values[i] where mask[i]; NAN if none.
static inline double UMMPDT1MaskedMedian(const float *values, const unsigned char *mask, long count)
{
    float *v = (float *)malloc(sizeof(float) * (size_t)(count > 0 ? count : 1));
    long n = 0;
    for (long i = 0; i < count; i++) if (mask[i] && isfinite(values[i])) v[n++] = values[i];
    double r = NAN;
    if (n > 0) {
        qsort(v, (size_t)n, sizeof(float), UMMPDT1CompareFloats);
        r = (n % 2) ? v[n / 2] : 0.5 * ((double)v[n / 2 - 1] + v[n / 2]);
    }
    free(v);
    return r;
}

typedef struct {
    double maskThreshold;   // signal of the pre series below which a pixel is outside the head
    double medianPre;       // normalisation of the pre series
    double medianPost;      // normalisation of the post series
    long   maskPixels;      // pixels inside the mask
} UMMPDT1Result;

// pre, post: the whole volumes (same length). dt1: output (may be one of the inputs' copies).
// maskFraction: fraction of the pre series' 99th percentile (0.10). Returns 0 on failure.
static inline int UMMPDT1Compute(const float *pre, const float *post, float *dt1, long count,
                                 double maskFraction, UMMPDT1Result *result)
{
    if (!pre || !post || !dt1 || count <= 0) return 0;
    double p99 = UMMPDT1Percentile(pre, count, 99.0);
    if (!(p99 > 0)) return 0;
    double threshold = maskFraction * p99;
    unsigned char *mask = (unsigned char *)calloc((size_t)count, 1);
    long inside = 0;
    for (long i = 0; i < count; i++)
        if (isfinite(pre[i]) && isfinite(post[i]) && pre[i] > threshold) { mask[i] = 1; inside++; }
    if (inside < 100) { free(mask); return 0; }
    double mPre = UMMPDT1MaskedMedian(pre, mask, count);
    double mPost = UMMPDT1MaskedMedian(post, mask, count);
    if (!(mPre > 0) || !(mPost > 0)) { free(mask); return 0; }
    for (long i = 0; i < count; i++)
        dt1[i] = mask[i] ? (float)(post[i] / mPost - pre[i] / mPre) : 0.0f;
    free(mask);
    if (result) {
        result->maskThreshold = threshold;
        result->medianPre = mPre;
        result->medianPost = mPost;
        result->maskPixels = inside;
    }
    return 1;
}

#endif
