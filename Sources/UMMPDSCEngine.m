//
//  UMMPDSCEngine.m — DSC-MRI extensions added in the IsiX port of UMMPerfusion.
//  See UMMPDSCEngine.h. Manual reference counting.
//

#import "UMMPDSCEngine.h"
#import "SVDcmp.h"
#import <OsiriXAPI/DCMPix.h>
#include <math.h>
#include <float.h>
#include <stdlib.h>
#include <string.h>

UMMPDSCContext UMMPDSCCurrent;

#define UMMP_DSC_DOMAIN @"com.osirix.UMMPerfusion.DSC"
#define UMMP_DSC_SIGNAL_FLOOR 0.01

#pragma mark - Settings

static id UMMPDSCValue(NSDictionary *d, NSString *key, id fallback)
{
    id v = [d objectForKey:key];
    return v ? v : fallback;
}

UMMPDSCSettings UMMPDSCLoadSettings(void)
{
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] persistentDomainForName:UMMP_DSC_DOMAIN];
    UMMPDSCSettings s;
    s.mask         = [UMMPDSCValue(d, @"mask", @YES) boolValue];
    s.maskFraction = [UMMPDSCValue(d, @"maskFraction", @0.10) doubleValue];
    s.leakage      = [UMMPDSCValue(d, @"leakage", @YES) boolValue];
    s.oSVD         = [UMMPDSCValue(d, @"oSVD", @YES) boolValue];
    s.oiThreshold  = [UMMPDSCValue(d, @"oiThreshold", @0.095) doubleValue];
    s.firstPass    = [UMMPDSCValue(d, @"firstPass", @NO) boolValue];
    s.clamp        = [UMMPDSCValue(d, @"clamp", @NO) boolValue];
    if (!(s.maskFraction >= 0.0 && s.maskFraction < 1.0)) s.maskFraction = 0.10;
    if (!(s.oiThreshold > 0.0 && s.oiThreshold < 1.0)) s.oiThreshold = 0.095;
    return s;
}

void UMMPDSCSaveSettings(UMMPDSCSettings s)
{
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:
        [[NSUserDefaults standardUserDefaults] persistentDomainForName:UMMP_DSC_DOMAIN] ?: @{}];
    [d addEntriesFromDictionary:[NSDictionary dictionaryWithObjectsAndKeys:
                       [NSNumber numberWithBool:s.mask], @"mask",
                       [NSNumber numberWithDouble:s.maskFraction], @"maskFraction",
                       [NSNumber numberWithBool:s.leakage], @"leakage",
                       [NSNumber numberWithBool:s.oSVD], @"oSVD",
                       [NSNumber numberWithDouble:s.oiThreshold], @"oiThreshold",
                       [NSNumber numberWithBool:s.firstPass], @"firstPass",
                       [NSNumber numberWithBool:s.clamp], @"clamp", nil]];
    [[NSUserDefaults standardUserDefaults] setPersistentDomain:d forName:UMMP_DSC_DOMAIN];
}

NSString *UMMPDSCSettingsDescription(UMMPDSCSettings s)
{
    return [NSString stringWithFormat:@"mask %@ (%.0f%%), leakage correction %@, deconvolution %@, blood volume %@, zero-signal frames %@",
            s.mask ? @"on" : @"off", s.maskFraction * 100.0,
            s.leakage ? @"on" : @"off",
            s.oSVD ? [NSString stringWithFormat:@"oSVD (OI ≤ %.3f)", s.oiThreshold] : @"sSVD",
            s.firstPass ? @"first pass" : @"whole curve",
            s.clamp ? @"clamped" : @"excluded"];
}

#pragma mark - Concentration

double UMMPDSCConcentrationValue(double signal, double baseline, BOOL clamp)
{
    if (!(baseline > DBL_EPSILON) || !isfinite(signal)) return NAN;
    double ratio = signal / baseline;
    if (!(ratio > 0.0) || ratio < UMMP_DSC_SIGNAL_FLOOR) {
        if (!clamp) return (ratio > 0.0) ? -log(ratio) : NAN;
        ratio = UMMP_DSC_SIGNAL_FLOOR;
    }
    return -log(ratio);
}

#pragma mark - Preparation

static int UMMPCompareDoubles(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

void UMMPDSCPrepare(NSArray *srcPix, int start, int n, int bl, int sliceFrom, int sliceTo, UMMPDSCSettings settings)
{
    UMMPDSCFinish();
    UMMPDSCCurrent.active = YES;
    UMMPDSCCurrent.settings = settings;
    UMMPDSCCurrent.n = n;
    UMMPDSCCurrent.maskThreshold = DBL_EPSILON;
    UMMPDSCCurrent.fpStart = 0;
    UMMPDSCCurrent.fpEnd = n - 1;

    if (n < 3 || bl < 1 || start < 0 || start + n > (int)[srcPix count]) return;
    NSArray *firstFrame = [srcPix objectAtIndex:start];
    if (sliceFrom < 0) sliceFrom = 0;
    if (sliceTo >= (int)[firstFrame count]) sliceTo = (int)[firstFrame count] - 1;
    if (sliceTo < sliceFrom) return;
    if (bl > n) bl = n;

    DCMPix *pix0 = [firstFrame objectAtIndex:sliceFrom];
    long width = [pix0 pwidth], height = [pix0 pheight], size = width * height;
    int slices = sliceTo - sliceFrom + 1;
    if (size <= 0) return;

    // Pass 1: baseline signal of every pixel, and the 99th percentile of the positive ones.
    double *s0 = (double *)calloc((size_t)slices * (size_t)size, sizeof(double));
    double *positive = (double *)malloc((size_t)slices * (size_t)size * sizeof(double));
    long npos = 0;
    for (int s = 0; s < slices; s++) {
        double *row = s0 + (size_t)s * size;
        for (int t = 0; t < bl; t++) {
            DCMPix *pix = [[srcPix objectAtIndex:start + t] objectAtIndex:sliceFrom + s];
            float *img = [pix fImage];
            if (!img || (long)[pix pwidth] * [pix pheight] != size) continue;
            for (long i = 0; i < size; i++) row[i] += img[i];
        }
        for (long i = 0; i < size; i++) {
            row[i] /= bl;
            if (row[i] > 0 && isfinite(row[i])) positive[npos++] = row[i];
        }
    }
    if (npos > 0 && settings.mask) {
        qsort(positive, (size_t)npos, sizeof(double), UMMPCompareDoubles);
        double p99 = positive[(long)floor(0.99 * (npos - 1))];
        UMMPDSCCurrent.maskThreshold = MAX(DBL_EPSILON, settings.maskFraction * p99);
    }
    free(positive);

    // Pass 2: whole-brain mean ΔR2*·TE curve (leakage reference, first-pass window).
    if (settings.leakage || settings.firstPass) {
        double *sum = (double *)calloc((size_t)n, sizeof(double));
        double *curve = (double *)malloc((size_t)n * sizeof(double));
        float **frames = (float **)malloc((size_t)n * sizeof(float *));
        long used = 0;
        for (int s = 0; s < slices; s++) {
            BOOL ok = YES;
            for (int t = 0; t < n; t++) {
                DCMPix *pix = [[srcPix objectAtIndex:start + t] objectAtIndex:sliceFrom + s];
                frames[t] = [pix fImage];
                if (!frames[t] || (long)[pix pwidth] * [pix pheight] != size) ok = NO;
            }
            if (!ok) continue;
            double *row = s0 + (size_t)s * size;
            for (long i = 0; i < size; i++) {
                if (!(row[i] >= UMMPDSCCurrent.maskThreshold)) continue;
                BOOL valid = YES;
                for (int t = 0; t < n && valid; t++) {
                    curve[t] = UMMPDSCConcentrationValue(frames[t][i], row[i], settings.clamp);
                    if (isnan(curve[t])) valid = NO;
                }
                if (!valid) continue;
                for (int t = 0; t < n; t++) sum[t] += curve[t];
                used++;
            }
        }
        free(frames);
        free(curve);
        if (used > 0) {
            for (int t = 0; t < n; t++) sum[t] /= used;
            UMMPDSCCurrent.reference = sum;
            UMMPDSCCurrent.referencePixels = used;

            // First-pass window: from the end of the baseline to the first minimum after the peak
            // of the (3-point smoothed) whole-brain curve.
            double *smooth = (double *)malloc((size_t)n * sizeof(double));
            for (int t = 0; t < n; t++) {
                int a = MAX(0, t - 1), b = MIN(n - 1, t + 1);
                smooth[t] = (sum[a] + sum[t] + sum[b]) / 3.0;
            }
            int from = MIN(bl, n - 1), peak = from;
            for (int t = from; t < n; t++) if (smooth[t] > smooth[peak]) peak = t;
            int end = n - 1;
            for (int t = peak + 1; t < n - 1; t++)
                if (smooth[t] <= smooth[t - 1] && smooth[t] < smooth[t + 1]) { end = t; break; }
            UMMPDSCCurrent.fpStart = MAX(0, from - 1);
            UMMPDSCCurrent.fpEnd = end;
            free(smooth);
        } else {
            free(sum);
        }
    }
    free(s0);

    NSLog(@"UMMP DSC: %@", UMMPDSCSettingsDescription(settings));
    NSLog(@"UMMP DSC: mask threshold %.2f, reference from %ld pixels, first pass frames %d-%d of %d",
          UMMPDSCCurrent.maskThreshold, UMMPDSCCurrent.referencePixels,
          UMMPDSCCurrent.fpStart + 1, UMMPDSCCurrent.fpEnd + 1, n);
}

void UMMPDSCFinish(void)
{
    if (UMMPDSCCurrent.reference) free(UMMPDSCCurrent.reference);
    memset(&UMMPDSCCurrent, 0, sizeof(UMMPDSCCurrent));
}

#pragma mark - Leakage correction (Boxerman-Weisskoff)

static void UMMPCumulativeIntegral(const double *y, const double *time, int n, double *out)
{
    out[0] = 0.0;
    for (int k = 1; k < n; k++)
        out[k] = out[k - 1] + 0.5 * (y[k] + y[k - 1]) * (time[k] - time[k - 1]);
}

void UMMPDSCCorrectLeakage(double *p, int n, int imageSize, const double *time, float *k2)
{
    const double *R = UMMPDSCCurrent.reference;
    if (!R || UMMPDSCCurrent.n != n) {
        if (k2) for (int j = 0; j < imageSize; j++) k2[j] = NAN;
        return;
    }
    double *I = (double *)malloc((size_t)n * sizeof(double));
    UMMPCumulativeIntegral(R, time, n, I);

    double a11 = 0, a12 = 0, a22 = 0;
    for (int k = 0; k < n; k++) { a11 += R[k] * R[k]; a12 += R[k] * I[k]; a22 += I[k] * I[k]; }
    double det = a11 * a22 - a12 * a12;

    for (int j = 0; j < imageSize; j++) {
        double *y = p + (size_t)j * n;
        if (isnan(y[0]) || !(fabs(det) > DBL_EPSILON)) { if (k2) k2[j] = isnan(y[0]) ? NAN : 0.0f; continue; }
        double b1 = 0, b2 = 0;
        for (int k = 0; k < n; k++) { b1 += R[k] * y[k]; b2 += I[k] * y[k]; }
        // y ≈ K1·R − K2·I  (least squares)
        double K2 = (a12 * b1 - a11 * b2) / det;
        for (int k = 0; k < n; k++) y[k] += K2 * I[k];
        if (k2) k2[j] = (float)K2;
    }
    free(I);
}

#pragma mark - First-pass blood volume

void UMMPDSCFirstPassVolume(const double *p, int n, int imageSize, const float *aif, const double *time, double *vdOut)
{
    int a = UMMPDSCCurrent.fpStart, b = UMMPDSCCurrent.fpEnd;
    if (a < 0) a = 0;
    if (b > n - 1) b = n - 1;
    double denominator = 0;
    for (int k = a + 1; k <= b; k++) denominator += 0.5 * (aif[k] + aif[k - 1]) * (time[k] - time[k - 1]);
    for (int j = 0; j < imageSize; j++) {
        const double *y = p + (size_t)j * n;
        if (isnan(y[0]) || !(fabs(denominator) > DBL_EPSILON)) { vdOut[j] = NAN; continue; }
        double numerator = 0;
        for (int k = a + 1; k <= b; k++) numerator += 0.5 * (y[k] + y[k - 1]) * (time[k] - time[k - 1]);
        vdOut[j] = numerator / denominator;
    }
}

#pragma mark - oSVD

static double *UMMPSVWeights;
static int UMMPCompareBySVDescending(const void *a, const void *b)
{
    double x = UMMPSVWeights[*(const int *)a], y = UMMPSVWeights[*(const int *)b];
    return (x < y) - (x > y);
}

void UMMPDSCoSVD(const double *p, int n, int imageSize, const float *aif, double dt, double oiMax,
                 double *flowOut, double *volumeOut)
{
    int N = 2 * n, i, j, r;
    double **U = (double **)malloc((size_t)N * sizeof(double *));
    double **V = (double **)malloc((size_t)N * sizeof(double *));
    for (i = 0; i < N; i++) {
        U[i] = (double *)calloc((size_t)N, sizeof(double));
        V[i] = (double *)calloc((size_t)N, sizeof(double));
    }
    double *w = (double *)calloc((size_t)N, sizeof(double));

    // Block-circulant convolution matrix of the zero-padded AIF.
    for (i = 0; i < N; i++)
        for (j = 0; j < N; j++) {
            int k = (i - j + N) % N;
            U[i][j] = (k < n) ? dt * aif[k] : 0.0;
        }
    [SVDcmp svdcmp:U :N :N :w :V];   // U now holds the left singular vectors

    int *order = (int *)malloc((size_t)N * sizeof(int));
    for (i = 0; i < N; i++) order[i] = i;
    @synchronized ([SVDcmp class]) {   // qsort comparator uses a static
        UMMPSVWeights = w;
        qsort(order, (size_t)N, sizeof(int), UMMPCompareBySVDescending);
        UMMPSVWeights = NULL;
    }
    double wmax = w[order[0]];
    double wmin = wmax * 1e-10;

    double *c = (double *)calloc((size_t)N, sizeof(double));
    double *coef = (double *)calloc((size_t)N, sizeof(double));
    double *f = (double *)calloc((size_t)N, sizeof(double));

    for (int px = 0; px < imageSize; px++) {
        const double *y = p + (size_t)px * n;
        if (isnan(y[0])) { flowOut[px] = NAN; volumeOut[px] = NAN; continue; }
        for (i = 0; i < n; i++) c[i] = y[i];
        for (i = n; i < N; i++) c[i] = 0.0;
        for (r = 0; r < N; r++) {
            int idx = order[r];
            if (w[idx] <= wmin) { coef[idx] = 0.0; continue; }
            double dot = 0.0;
            for (i = 0; i < N; i++) dot += U[i][idx] * c[i];
            coef[idx] = dot / w[idx];
        }
        memset(f, 0, (size_t)N * sizeof(double));
        double bestFlow = NAN, bestVolume = NAN, firstFlow = NAN, firstVolume = NAN;
        for (r = 0; r < N; r++) {
            int idx = order[r];
            if (w[idx] <= wmin) break;
            double b = coef[idx];
            for (i = 0; i < N; i++) f[i] += V[i][idx] * b;
            double fmax = f[0], area = 0.0;
            for (i = 0; i < N; i++) { if (f[i] > fmax) fmax = f[i]; area += f[i]; }
            area *= dt;
            if (r == 0) { firstFlow = fmax; firstVolume = area; }
            if (!(fmax > 0.0)) continue;
            double osc = 0.0;
            for (i = 2; i < N; i++) osc += fabs(f[i] - 2.0 * f[i - 1] + f[i - 2]);
            osc /= (N * fmax);
            if (osc <= oiMax) { bestFlow = fmax; bestVolume = area; }   // keep the lowest threshold that passes
        }
        if (isnan(bestFlow)) { bestFlow = firstFlow; bestVolume = firstVolume; }
        flowOut[px] = bestFlow;
        volumeOut[px] = bestVolume;
    }

    free(c); free(coef); free(f); free(order); free(w);
    for (i = 0; i < N; i++) { free(U[i]); free(V[i]); }
    free(U); free(V);
}
