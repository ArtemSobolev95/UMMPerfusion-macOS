// Checks of the sRCBV maths (Sources/UMMPStandardize.h). Plain C, runs anywhere:
//   cc -O2 -o /tmp/test_standardize Tests/test_standardize.c -lm && /tmp/test_standardize
//
// Synthetic "brain" CBV maps: white matter, grey matter, vessels, a tumour, background −1.
// Each patient gets a different arbitrary scale (AIF, gain) and a different GM/WM contrast.

#include <stdio.h>
#include "../Sources/UMMPStandardize.h"

static unsigned long long rngState = 88172645463325252ULL;
static double urand(void) { rngState ^= rngState << 13; rngState ^= rngState >> 7; rngState ^= rngState << 17; return (rngState >> 11) * (1.0 / 9007199254740992.0); }
static double nrand(void) { double u = urand(), v = urand(); if (u < 1e-12) u = 1e-12; return sqrt(-2 * log(u)) * cos(2 * M_PI * v); }

#define N 40000
enum { BG, WM, GM, VES, TUM };

// Fills a map; returns the true class of every pixel in cls.
static void makeMap(float *map, int *cls, double scale, double gmRatio, double noise, int tumourPixels)
{
    for (int i = 0; i < N; i++) {
        double u = urand(), v;
        int c;
        if (u < 0.15) c = BG; else if (u < 0.55) c = WM; else if (u < 0.95) c = GM; else c = VES;
        if (i < tumourPixels) c = TUM;
        switch (c) {
            case WM:  v = 1.0; break;
            case GM:  v = gmRatio; break;
            case VES: v = 6.0 + 4.0 * urand(); break;
            case TUM: v = 3.0; break;
            default:  v = -1; break;
        }
        if (c != BG) v = v * exp(noise * nrand()) * scale;
        map[i] = (c == BG) ? -1.0f : (float)v;
        cls[i] = c;
    }
}

static double classMean(const float *map, const int *cls, int c)
{
    double s = 0; long n = 0;
    for (int i = 0; i < N; i++) if (cls[i] == c && map[i] != -1.0f) { s += map[i]; n++; }
    return n ? s / n : NAN;
}

static int failures = 0;
static void check(int ok, const char *what) { printf("%s  %s\n", ok ? "ok  " : "FAIL", what); if (!ok) failures++; }

int main(void)
{
    static float map[N], copy[N];
    static int cls[N];
    enum { CASES = 8 };
    double caseLm[CASES * UMMP_SRCBV_LANDMARKS], nawmRaw[CASES];

    // Calibration: 8 patients, scales 0.5–40 (arbitrary units), GM/WM 2.0–2.8, no tumour.
    for (int c = 0; c < CASES; c++) {
        double scale = 0.5 * pow(80.0, c / (double)(CASES - 1));
        makeMap(map, cls, scale, 2.0 + 0.8 * urand(), 0.25, 0);
        check(UMMPSRCBVLandmarks(map, N, caseLm + c * UMMP_SRCBV_LANDMARKS) > 0, "calibration case has landmarks");
        nawmRaw[c] = classMean(map, cls, WM);
    }
    double standard[UMMP_SRCBV_LANDMARKS];
    UMMPSRCBVStandardFromCases(caseLm, CASES, standard);
    check(standard[0] == 0.0 && fabs(standard[10] - 50000.0) < 1e-6, "standard scale runs from 0 to 50 000");
    int increasing = 1;
    for (int k = 1; k < UMMP_SRCBV_LANDMARKS; k++) if (!(standard[k] > standard[k - 1])) increasing = 0;
    check(increasing, "standard landmarks strictly increasing");

    double unit = 0;
    for (int c = 0; c < CASES; c++) unit += UMMPSRCBVTransformValue(nawmRaw[c], caseLm + c * UMMP_SRCBV_LANDMARKS, standard) / CASES;
    printf("     standard landmarks:");
    for (int k = 0; k < UMMP_SRCBV_LANDMARKS; k++) printf(" %.0f", standard[k]);
    printf("\n     unit (mean standardised NAWM) = %.0f\n", unit);

    // New patients with tumour, at very different scales: NAWM and tumour must land on the same sRCBV.
    double wmS[3], tumS[3], scales[3] = {0.03, 1.0, 500.0};
    for (int p = 0; p < 3; p++) {
        rngState = 12345;                              // same anatomy, only the scale differs
        makeMap(map, cls, scales[p], 2.4, 0.25, 1200);
        double lm[UMMP_SRCBV_LANDMARKS];
        UMMPSRCBVLandmarks(map, N, lm);
        UMMPSRCBVTransformImage(map, N, lm, standard, unit, -1.0f);
        wmS[p] = classMean(map, cls, WM);
        tumS[p] = classMean(map, cls, TUM);
        printf("     scale %-6g  sRCBV WM %.3f  tumour %.3f\n", scales[p], wmS[p], tumS[p]);
    }
    check(fabs(wmS[0] - wmS[2]) < 1e-3 && fabs(tumS[0] - tumS[2]) < 1e-3, "independent of the map's scale (CBV vs CBV÷NAWM)");
    check(fabs(wmS[1] - 1.0) < 0.15, "NAWM ≈ 1 on a typical case");
    check(tumS[1] > 2.0 * wmS[1], "tumour stays well above NAWM");

    // Different patients (other anatomy, other GM/WM, other noise): NAWM spread after standardisation.
    double lo = 1e9, hi = -1e9;
    for (int p = 0; p < 10; p++) {
        makeMap(map, cls, 0.2 * pow(10, 3 * urand()), 2.0 + 0.8 * urand(), 0.2 + 0.1 * urand(), 800);
        double lm[UMMP_SRCBV_LANDMARKS] = {0};
        UMMPSRCBVLandmarks(map, N, lm);
        UMMPSRCBVTransformImage(map, N, lm, standard, unit, -1.0f);
        double w = classMean(map, cls, WM);
        if (w < lo) lo = w;
        if (w > hi) hi = w;
    }
    printf("     NAWM sRCBV over 10 new patients: %.3f – %.3f\n", lo, hi);
    check(lo > 0.85 && hi < 1.15, "NAWM within ±15 % across patients without any ROI");

    // Edge cases
    rngState = 999;
    makeMap(map, cls, 1.0, 2.4, 0.25, 0);
    double lm[UMMP_SRCBV_LANDMARKS];
    UMMPSRCBVLandmarks(map, N, lm);
    check(UMMPSRCBVTransformValue(lm[10] * 5, lm, standard) == standard[10], "above p99.8 → s2");
    check(UMMPSRCBVTransformValue(lm[0] * 0.01, lm, standard) >= 0.0, "below p1 never negative");
    check(UMMPSRCBVTransformValue(-1.0, lm, standard) == -1.0, "−1 stays −1");
    memcpy(copy, map, sizeof(map));
    int mono = 1; double prev = -1;
    for (double x = lm[0] * 0.5; x < lm[10] * 1.2; x += (lm[10] - lm[0]) / 1000) {
        double s = UMMPSRCBVTransformValue(x, lm, standard);
        if (s < prev) mono = 0;
        prev = s;
    }
    check(mono, "transformation monotonic");
    float few[100]; for (int i = 0; i < 100; i++) few[i] = 1.0f + i;
    check(UMMPSRCBVLandmarks(few, 100, lm) == 0, "too few pixels refused");
    float flat[1000]; for (int i = 0; i < 1000; i++) flat[i] = 2.0f;
    check(UMMPSRCBVLandmarks(flat, 1000, lm) == 0, "constant map refused");

    printf("%s\n", failures ? "FAILED" : "all checks passed");
    return failures != 0;
}
