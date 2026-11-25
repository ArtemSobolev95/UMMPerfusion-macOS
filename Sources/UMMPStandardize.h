//
//  UMMPStandardize.h — standardised rCBV (sRCBV), added in the IsiX port. Plain C.
//
//  Histogram standardisation of Nyúl & Udupa (MRM 1999; IEEE TMI 2000) as applied to rCBV maps by
//  Bedekar, Jensen & Schmainda (MRM 2010;64:907): every CBV map is mapped, piecewise linearly, onto a
//  standard scale learnt from a set of calibration (training) maps of the same acquisition protocol.
//  No reference ROI is needed, and maps of different patients and visits share one scale.
//
//   - landmarks: the 1st percentile, the deciles 10…90 and the 99.8th percentile of the computed,
//     positive pixels of the whole map (11 landmarks; pixels marked −1 are left out)
//   - training: each calibration map's landmarks are scaled linearly so that p1 → s1 = 0 and
//     p99.8 → s2 = 50 000; the standard landmarks are the mean of the scaled landmarks
//   - transformation: between landmarks, linear from the map's own landmarks to the standard ones;
//     below p1 the first segment is extended (not below 0); above p99.8 the value is s2 (vessels)
//   - display unit: sRCBV = standardised value ÷ unit, with unit = the mean standardised value of
//     the NAWM reference ROIs of the calibration maps (when they have one), else the standard median
//
//  The calibration is the user's own: the numbers are NOT on the scale of IB Neuro (its calibration
//  is not published), so thresholds from the literature do not transfer as they are.
//
//  Standardisation does not change when a map is multiplied by a constant: a blood-volume map and
//  the same map divided by NAWM give the same sRCBV.
//

#ifndef UMMP_STANDARDIZE_H
#define UMMP_STANDARDIZE_H

#include <math.h>
#include <stdlib.h>
#include <string.h>

#define UMMP_SRCBV_LANDMARKS 11
#define UMMP_SRCBV_S1 0.0
#define UMMP_SRCBV_S2 50000.0
#define UMMP_SRCBV_MEDIAN_INDEX 5          // the 50th percentile among the landmarks
#define UMMP_SRCBV_MIN_PIXELS 500

static const double UMMPSRCBVPercentiles[UMMP_SRCBV_LANDMARKS] =
    {1.0, 10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0, 80.0, 90.0, 99.8};

static int UMMPSRCBVCompareFloats(const void *a, const void *b)
{
    float x = *(const float *)a, y = *(const float *)b;
    return (x > y) - (x < y);
}

// Usable pixel of a CBV map: finite and positive (−1 = not computed, 0 = outside / no flow).
static inline int UMMPSRCBVUsable(float v)
{
    return isfinite(v) && v > 0.0f;
}

// Percentile (0–100) of sorted values, linear interpolation between ranks.
static inline double UMMPSRCBVPercentileSorted(const float *sorted, long n, double percentile)
{
    if (n <= 0) return NAN;
    if (n == 1) return sorted[0];
    double rank = percentile / 100.0 * (double)(n - 1);
    long lo = (long)floor(rank);
    if (lo < 0) lo = 0;
    if (lo >= n - 1) return sorted[n - 1];
    double f = rank - (double)lo;
    return sorted[lo] + f * ((double)sorted[lo + 1] - (double)sorted[lo]);
}

// Landmarks of a map from its usable pixels (values may contain anything; unusable ones are skipped).
// Returns the number of usable pixels, or 0 when there are too few or the histogram has no width.
// The landmarks are made strictly increasing (ties, e.g. many equal values, are spread minimally).
static inline long UMMPSRCBVLandmarks(const float *values, long count, double landmarks[UMMP_SRCBV_LANDMARKS])
{
    if (!values || count <= 0) return 0;
    float *v = (float *)malloc(sizeof(float) * (size_t)count);
    if (!v) return 0;
    long n = 0;
    for (long i = 0; i < count; i++) if (UMMPSRCBVUsable(values[i])) v[n++] = values[i];
    if (n < UMMP_SRCBV_MIN_PIXELS) { free(v); return 0; }
    qsort(v, (size_t)n, sizeof(float), UMMPSRCBVCompareFloats);
    for (int k = 0; k < UMMP_SRCBV_LANDMARKS; k++)
        landmarks[k] = UMMPSRCBVPercentileSorted(v, n, UMMPSRCBVPercentiles[k]);
    free(v);
    double width = landmarks[UMMP_SRCBV_LANDMARKS - 1] - landmarks[0];
    if (!(width > 0.0) || !isfinite(width)) return 0;
    double eps = width * 1e-9;
    for (int k = 1; k < UMMP_SRCBV_LANDMARKS; k++)
        if (landmarks[k] <= landmarks[k - 1]) landmarks[k] = landmarks[k - 1] + eps;
    return n;
}

// A map's landmarks scaled linearly onto the standard range: p1 → s1, p99.8 → s2 (training step).
static inline void UMMPSRCBVScaledLandmarks(const double landmarks[UMMP_SRCBV_LANDMARKS],
                                            double scaled[UMMP_SRCBV_LANDMARKS])
{
    double lo = landmarks[0], hi = landmarks[UMMP_SRCBV_LANDMARKS - 1];
    for (int k = 0; k < UMMP_SRCBV_LANDMARKS; k++)
        scaled[k] = UMMP_SRCBV_S1 + (landmarks[k] - lo) / (hi - lo) * (UMMP_SRCBV_S2 - UMMP_SRCBV_S1);
}

// Standard landmarks = mean of the scaled landmarks of the calibration maps (cases × 11, row-major).
// Returns 0 when there is no case.
static inline int UMMPSRCBVStandardFromCases(const double *caseLandmarks, int cases,
                                             double standard[UMMP_SRCBV_LANDMARKS])
{
    if (cases <= 0) return 0;
    for (int k = 0; k < UMMP_SRCBV_LANDMARKS; k++) standard[k] = 0.0;
    for (int c = 0; c < cases; c++) {
        double scaled[UMMP_SRCBV_LANDMARKS];
        UMMPSRCBVScaledLandmarks(caseLandmarks + (size_t)c * UMMP_SRCBV_LANDMARKS, scaled);
        for (int k = 0; k < UMMP_SRCBV_LANDMARKS; k++) standard[k] += scaled[k] / cases;
    }
    return 1;
}

// One value onto the standard scale (unusable values are returned unchanged).
static inline double UMMPSRCBVTransformValue(double value, const double landmarks[UMMP_SRCBV_LANDMARKS],
                                             const double standard[UMMP_SRCBV_LANDMARKS])
{
    if (!(isfinite(value) && value > 0.0)) return value;
    const int last = UMMP_SRCBV_LANDMARKS - 1;
    if (value >= landmarks[last]) return standard[last];
    int k = 0;                                   // segment [k, k+1]; below p1 the first one is extended
    while (k < last - 1 && value >= landmarks[k + 1]) k++;
    double s = standard[k] + (value - landmarks[k]) / (landmarks[k + 1] - landmarks[k]) * (standard[k + 1] - standard[k]);
    return s < UMMP_SRCBV_S1 ? UMMP_SRCBV_S1 : s;
}

// A whole image in place: usable pixels → standardised value ÷ unit; others → notComputed.
static inline void UMMPSRCBVTransformImage(float *image, long count, const double landmarks[UMMP_SRCBV_LANDMARKS],
                                           const double standard[UMMP_SRCBV_LANDMARKS], double unit, float notComputed)
{
    for (long i = 0; i < count; i++) {
        float v = image[i];
        image[i] = UMMPSRCBVUsable(v) ? (float)(UMMPSRCBVTransformValue(v, landmarks, standard) / unit) : notComputed;
    }
}

#endif
