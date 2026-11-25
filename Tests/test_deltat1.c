// Checks of the ΔT1 maths (Sources/UMMPDeltaT1.h). Plain C:
//   cc -O2 -o /tmp/test_deltat1 Tests/test_deltat1.c -lm && /tmp/test_deltat1
//
// Synthetic head: background, white matter, grey matter, scalp fat, a lesion that enhances by 60 %
// of the white-matter signal and vessels; the post series has another gain than the pre series.

#include <stdio.h>
#include "../Sources/UMMPDeltaT1.h"

static unsigned long long rs = 88172645463325252ULL;
static double urand(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return (rs >> 11) * (1.0 / 9007199254740992.0); }
static double nrand(void) { double u = urand(), v = urand(); if (u < 1e-12) u = 1e-12; return sqrt(-2 * log(u)) * cos(2 * M_PI * v); }

#define N 50000
enum { BG, WM, GM, FAT, LES, VES };
static int failures = 0;
static void check(int ok, const char *what) { printf("%s  %s\n", ok ? "ok  " : "FAIL", what); if (!ok) failures++; }

int main(void)
{
    static float pre[N], post[N], dt1[N];
    static int cls[N];
    double gainPre = 830.0, gainPost = 1370.0, noise = 0.02;
    for (int i = 0; i < N; i++) {
        double u = urand(); int c;
        if (u < 0.30) c = BG; else if (u < 0.62) c = WM; else if (u < 0.90) c = GM; else if (u < 0.98) c = FAT; else c = VES;
        if (i < 600) c = LES;
        double base, enh;                         // pre signal (WM = 1) and enhancement (in WM units)
        switch (c) {
            case WM:  base = 1.0;  enh = 0.0; break;
            case GM:  base = 0.8;  enh = 0.0; break;
            case FAT: base = 1.6;  enh = 0.0; break;
            case LES: base = 0.75; enh = 0.6; break;
            case VES: base = 0.6;  enh = 1.0; break;
            default:  base = 0.02; enh = 0.0; break;
        }
        pre[i]  = (float)(gainPre  * base * (1 + noise * nrand()));
        post[i] = (float)(gainPost * (base + enh) * (1 + noise * nrand()));
        cls[i] = c;
    }
    UMMPDT1Result r;
    check(UMMPDT1Compute(pre, post, dt1, N, 0.10, &r), "computed");
    double s[6] = {0}; long n[6] = {0};
    for (int i = 0; i < N; i++) { s[cls[i]] += dt1[i]; n[cls[i]]++; }
    for (int c = 0; c < 6; c++) s[c] /= n[c];
    printf("     medians pre %.0f post %.0f, mask %ld px\n", r.medianPre, r.medianPost, r.maskPixels);
    printf("     mean ΔT1: WM %.3f  GM %.3f  fat %.3f  lesion %.3f  vessels %.3f  background %.3f\n",
           s[WM], s[GM], s[FAT], s[LES], s[VES], s[BG]);
    check(fabs(s[WM]) < 0.05 && fabs(s[GM]) < 0.05 && fabs(s[FAT]) < 0.08, "non-enhancing tissue ≈ 0 despite different gains");
    check(s[LES] > 0.4, "lesion clearly positive");
    check(s[BG] == 0.0, "background 0");

    // Same pair with the post gain changed: identical map.
    static float post2[N], dt2[N];
    for (int i = 0; i < N; i++) post2[i] = post[i] * 0.37f;
    UMMPDT1Compute(pre, post2, dt2, N, 0.10, NULL);
    double maxDiff = 0;
    for (int i = 0; i < N; i++) if (fabs(dt2[i] - dt1[i]) > maxDiff) maxDiff = fabs(dt2[i] - dt1[i]);
    check(maxDiff < 1e-4, "independent of the series' gain");

    float zero[1000] = {0};
    check(!UMMPDT1Compute(zero, zero, dt2, 1000, 0.10, NULL), "empty series refused");

    // Sampling an axial "rCBV" stack (2 × 2 mm pixels, 5 mm slices with 1 mm gap) at scanner points.
    {
        enum { W = 20, H = 20, S = 4 };
        static float img[S][W * H];
        UMMPDT1Slice st[S];
        for (int k = 0; k < S; k++) {
            for (int i = 0; i < W * H; i++) img[k][i] = (float)(1 + k);      // slice k holds k+1
            img[k][5 * W + 5] = -1.0f;                                       // one pixel not computed
            UMMPDT1Slice sl = {{-20, -20, 6.0 * k}, {1, 0, 0}, {0, 1, 0}, {0, 0, 0}, 2, 2, 2.5, W, H, img[k]};
            UMMPDT1SliceSetNormal(&sl);
            st[k] = sl;
        }
        double p1[3] = {0, 0, 12.4}, p2[3] = {0, 0, 15.0}, p3[3] = {100, 0, 6}, p4[3] = {-10, -10, 0}, p5[3] = {-8.6, -9.6, 0};
        check(UMMPDT1SampleStack(st, S, p1) == 3.0f, "point in slice 3 reads its value");
        check(isnan(UMMPDT1SampleStack(st, S, p2)), "point in the gap between slices: no value");
        check(isnan(UMMPDT1SampleStack(st, S, p3)), "point outside the field of view: no value");
        check(isnan(UMMPDT1SampleStack(st, S, p4)), "pixel marked −1: no value");
        check(UMMPDT1SampleStack(st, S, p5) == 1.0f, "next to a −1 pixel: nearest computed pixel");
        check(UMMPDT1BurdenClass(0.5f, 1.0, 1.75) == 0 && UMMPDT1BurdenClass(1.2f, 1.0, 1.75) == 1 &&
              UMMPDT1BurdenClass(1.75f, 1.0, 1.75) == 2, "burden classes");
    }
    printf("%s\n", failures ? "FAILED" : "all checks passed");
    return failures != 0;
}
