// Checks of the Modified (extended) Tofts fit of UMMPerfusion (Sources/MPCurveFit.c, MPFit.c).
//   mkdir -p /tmp/inc && ln -sf $PWD/Sources/MPFit.h /tmp/inc/mpfit.h && ln -sf $PWD/Sources/MPCurveFit.h /tmp/inc/mpcurvefit.h
//   cc -O2 -I/tmp/inc -o /tmp/test_tofts Tests/test_tofts.c Sources/MPCurveFit.c Sources/MPFit.c -lm && /tmp/test_tofts
//
// Model: Ct(t) = vp·Cp(t) + Ktrans·∫ Cp(τ)·exp(−kep(t−τ)) dτ,  kep = Ktrans/ve.
// Truth curves are made by fine numerical integration (0.05 s steps), independently of the plugin's
// own piecewise-linear convolution, then sampled every 3 s.
//
// Part A: concentration in, parameters out (the maths of the fit).
// Part C: the same signals converted with UMMPConcentration.h; part D: tissue T1 assumed ±20 %.
// Part B: what the plugin actually feeds the fit — relative signal enhancement (S − S0)/S0 of a
//         spoiled-gradient-echo signal, not concentration — to show the size of that bias.

#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>
#include "../Sources/UMMPConcentration.h"

int fitSingleInletModifiedTofts(int m, double *p, int *fixed, int *limited, double *limits, int maxiterations,
                                int maxFunctionEvaluation, double *time, float *aif, float *tissue, double *curveFit,
                                double *pv, double *imt, double *iv, double *per, double *akaikeError,
                                double *chiSquare, double *xError);
void lmuEnhancement(float *aif, int n, int bl, int tracer);

// Parker et al. MRM 2006 population AIF (blood, mmol/L), t in minutes.
static double parkerBlood(double tmin)
{
    double A1 = 0.809, A2 = 0.330, T1 = 0.17046, T2 = 0.365, s1 = 0.0563, s2 = 0.132;
    double al = 1.050, be = 0.1685, s = 38.078, tau = 0.483;
    if (tmin < 0) return 0;
    return A1 / (s1 * sqrt(2 * M_PI)) * exp(-pow(tmin - T1, 2) / (2 * s1 * s1)) +
           A2 / (s2 * sqrt(2 * M_PI)) * exp(-pow(tmin - T2, 2) / (2 * s2 * s2)) +
           al * exp(-be * tmin) / (1 + exp(-s * (tmin - tau)));
}

#define DT 3.0          // s, sampling
#define N 100           // 300 s
#define BL 10           // baseline frames (30 s) before injection
#define HCT 0.45

static double cpPlasma(double t) { return parkerBlood((t - BL * DT) / 60.0) / (1 - HCT); }   // t in s

// Exact (fine-step) tissue concentration.
static double tissueConc(double t, double ktrans_s, double ve, double vp)
{
    double kep = ktrans_s / ve, conv = 0, h = 0.05;
    for (double tau = 0; tau < t; tau += h) conv += cpPlasma(tau + 0.5 * h) * exp(-kep * (t - tau - 0.5 * h)) * h;
    return vp * cpPlasma(t) + ktrans_s * conv;
}

// Spoiled gradient echo, relative to M0.
static double spgr(double R1, double TR, double fa)
{
    double E = exp(-TR * R1);
    return sin(fa) * (1 - E) / (1 - cos(fa) * E);
}

static unsigned long long rs = 88172645463325252ULL;
static double urand(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return (rs >> 11) * (1.0 / 9007199254740992.0); }
static double nrand(void) { double u = urand(), v = urand(); if (u < 1e-12) u = 1e-12; return sqrt(-2 * log(u)) * cos(2 * M_PI * v); }

// One fit with the plugin's default preset (vp+ve 0.3, ve/(vp+ve) 2/3, Ktrans 12/6000 per s).
static void fit(double *time, float *aif, float *tissue, double *ktrans_min, double *ve, double *vp)
{
    double p[3] = {0.3, 2.0 / 3, 12.0 / 6000};
    int fixed[3] = {0, 0, 0}, limited[6] = {1, 0, 1, 0, 0, 0};
    double limits[6] = {0, 0, 0, 0, 0, 0};
    double curve[N], pv, imt, iv, per, aic, chi;
    fitSingleInletModifiedTofts(N, p, fixed, limited, limits, 200, 1000, time, aif, tissue, curve, &pv, &imt, &iv, &per, &aic, &chi, NULL);
    *ktrans_min = per / 100.0;   // ml/100ml/min → /min
    *ve = iv / 100.0;
    *vp = pv / 100.0;
}

int main(void)
{
    double time[N];
    float aifC[N];
    for (int i = 0; i < N; i++) { time[i] = i * DT; aifC[i] = (float)cpPlasma(time[i]); }
    const double cases[][3] = {{0.01, 0.10, 0.01}, {0.05, 0.20, 0.02}, {0.15, 0.30, 0.05}, {0.30, 0.40, 0.08}, {0.60, 0.25, 0.10}};
    const int nc = sizeof(cases) / sizeof(cases[0]);
    int failures = 0;

    printf("A. Concentration in (plasma AIF, no noise)\n");
    printf("   %-22s %-26s %s\n", "truth Ktrans ve vp", "fitted", "error Ktrans / ve / vp");
    for (int c = 0; c < nc; c++) {
        float tis[N];
        for (int i = 0; i < N; i++) tis[i] = (float)tissueConc(time[i], cases[c][0] / 60, cases[c][1], cases[c][2]);
        double k, ve, vp;
        fit(time, aifC, tis, &k, &ve, &vp);
        double ek = (k - cases[c][0]) / cases[c][0], ee = (ve - cases[c][1]) / cases[c][1], ep = (vp - cases[c][2]) / cases[c][2];
        printf("   %.2f/min %.2f %.2f   %.3f/min %.3f %.3f   %+.1f %% / %+.1f %% / %+.1f %%\n",
               cases[c][0], cases[c][1], cases[c][2], k, ve, vp, 100 * ek, 100 * ee, 100 * ep);
        if (!(fabs(ek) < 0.05 && fabs(ee) < 0.05 && fabs(ep) < 0.10)) failures++;
    }

    printf("\nA2. Same with noise (SNR ≈ 20 at peak tissue), 200 repetitions, median and IQR of Ktrans\n");
    for (int c = 1; c < 4; c++) {
        float clean[N], tis[N];
        double peak = 0;
        for (int i = 0; i < N; i++) { clean[i] = (float)tissueConc(time[i], cases[c][0] / 60, cases[c][1], cases[c][2]); if (clean[i] > peak) peak = clean[i]; }
        double ks[200];
        for (int r = 0; r < 200; r++) {
            for (int i = 0; i < N; i++) tis[i] = clean[i] + (float)(peak / 20 * nrand());
            double ve, vp;
            fit(time, aifC, tis, &ks[r], &ve, &vp);
        }
        for (int i = 0; i < 200; i++) for (int j = i + 1; j < 200; j++) if (ks[j] < ks[i]) { double t = ks[i]; ks[i] = ks[j]; ks[j] = t; }
        printf("   truth %.2f/min: median %.3f, IQR %.3f–%.3f\n", cases[c][0], ks[100], ks[50], ks[150]);
    }

    printf("\nB. What the plugin feeds the fit: relative signal enhancement of an SPGR signal\n");
    printf("   (TR 5 ms, FA 15°, r1 4.5 /mM/s, T10 blood 1.6 s, tissue 1.2 s, Hct %.2f)\n", HCT);
    double TR = 0.005, fa = 15 * M_PI / 180, r1 = 4.5;
    float aifS[N];
    for (int i = 0; i < N; i++) aifS[i] = (float)spgr(1 / 1.6 + r1 * parkerBlood((time[i] - BL * DT) / 60.0), TR, fa);
    lmuEnhancement(aifS, N, BL, 0);
    for (int i = 0; i < N; i++) aifS[i] /= (1 - HCT);          // as the plugin does
    for (int c = 0; c < nc; c++) {
        float tis[N];
        for (int i = 0; i < N; i++) tis[i] = (float)spgr(1 / 1.2 + r1 * tissueConc(time[i], cases[c][0] / 60, cases[c][1], cases[c][2]), TR, fa);
        lmuEnhancement(tis, N, BL, 0);
        double k, ve, vp;
        fit(time, aifS, tis, &k, &ve, &vp);
        printf("   truth %.2f/min %.2f %.2f → %.3f/min %.3f %.3f   (Ktrans %+.0f %%, ve %+.0f %%, vp %+.0f %%)\n",
               cases[c][0], cases[c][1], cases[c][2], k, ve, vp,
               100 * (k - cases[c][0]) / cases[c][0], 100 * (ve - cases[c][1]) / cases[c][1], 100 * (vp - cases[c][2]) / cases[c][2]);
    }

    printf("\nC. Same signals converted to concentration first (UMMPConcentration.h, fixed T1 = truth)\n");
    {
        float aifK[N];
        for (int i = 0; i < N; i++) aifK[i] = (float)spgr(1 / 1.6 + r1 * parkerBlood((time[i] - BL * DT) / 60.0), TR, fa);
        UMMPSignalToConcentration(aifK, N, BL, 1.6, TR, 15, r1);
        for (int i = 0; i < N; i++) aifK[i] /= (1 - HCT);
        for (int c = 0; c < nc; c++) {
            float tis[N];
            for (int i = 0; i < N; i++) tis[i] = (float)spgr(1 / 1.2 + r1 * tissueConc(time[i], cases[c][0] / 60, cases[c][1], cases[c][2]), TR, fa);
            UMMPSignalToConcentration(tis, N, BL, 1.2, TR, 15, r1);
            double k, ve, vp;
            fit(time, aifK, tis, &k, &ve, &vp);
            double ek = (k - cases[c][0]) / cases[c][0], ee = (ve - cases[c][1]) / cases[c][1], ep = (vp - cases[c][2]) / cases[c][2];
            printf("   truth %.2f/min %.2f %.2f → %.3f/min %.3f %.3f   (Ktrans %+.1f %%, ve %+.1f %%, vp %+.1f %%)\n",
                   cases[c][0], cases[c][1], cases[c][2], k, ve, vp, 100 * ek, 100 * ee, 100 * ep);
            if (!(fabs(ek) < 0.05 && fabs(ee) < 0.05 && fabs(ep) < 0.10)) failures++;
        }
    }
    printf("\nD. Tissue T1 assumed wrong by ±20 %% (true 1.2 s, fixed 0.96 / 1.44 s)\n");
    {
        float aifK[N];
        for (int i = 0; i < N; i++) aifK[i] = (float)spgr(1 / 1.6 + r1 * parkerBlood((time[i] - BL * DT) / 60.0), TR, fa);
        UMMPSignalToConcentration(aifK, N, BL, 1.6, TR, 15, r1);
        for (int i = 0; i < N; i++) aifK[i] /= (1 - HCT);
        double wrong[2] = {0.96, 1.44};
        for (int w = 0; w < 2; w++) {
            int c = 2;
            float tis[N];
            for (int i = 0; i < N; i++) tis[i] = (float)spgr(1 / 1.2 + r1 * tissueConc(time[i], cases[c][0] / 60, cases[c][1], cases[c][2]), TR, fa);
            UMMPSignalToConcentration(tis, N, BL, wrong[w], TR, 15, r1);
            double k, ve, vp;
            fit(time, aifK, tis, &k, &ve, &vp);
            printf("   T1 %.2f s: truth %.2f/min %.2f %.2f → %.3f/min %.3f %.3f   (Ktrans %+.0f %%, ve %+.0f %%, vp %+.0f %%)\n",
                   wrong[w], cases[c][0], cases[c][1], cases[c][2], k, ve, vp,
                   100 * (k - cases[c][0]) / cases[c][0], 100 * (ve - cases[c][1]) / cases[c][1], 100 * (vp - cases[c][2]) / cases[c][2]);
        }
    }
    printf("\n%s\n", failures ? "FAILED" : "parts A and C: all checks passed");
    return failures != 0;
}
