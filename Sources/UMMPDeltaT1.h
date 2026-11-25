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

#ifndef MIN
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#endif
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

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

// ---- Rigid registration of post onto pre, and shading correction ----

// A volume on a regular grid: nx × ny × nz voxels (x fastest), voxel size in mm.
typedef struct {
    const float *v;
    long nx, ny, nz;
    double dx, dy, dz;
    double ox, oy, oz;          // position (mm) of voxel 0 in the frame of the full-resolution grid
} UMMPDT1Volume;

// Rigid transform in mm about the volume centre: p' = R (p − c) + c + t, R = Rz·Ry·Rx (radians).
typedef struct { double rx, ry, rz, tx, ty, tz; } UMMPDT1Rigid;

static inline void UMMPDT1Matrix(const UMMPDT1Rigid *t, double R[9])
{
    double cx = cos(t->rx), sx = sin(t->rx), cy = cos(t->ry), sy = sin(t->ry), cz = cos(t->rz), sz = sin(t->rz);
    R[0] = cz * cy; R[1] = cz * sy * sx - sz * cx; R[2] = cz * sy * cx + sz * sx;
    R[3] = sz * cy; R[4] = sz * sy * sx + cz * cx; R[5] = sz * sy * cx - cz * sx;
    R[6] = -sy;     R[7] = cy * sx;                R[8] = cy * cx;
}

// Trilinear sample at voxel coordinates (x, y, z); NAN outside the grid.
static inline float UMMPDT1Sample(const UMMPDT1Volume *g, double x, double y, double z)
{
    if (x < 0 || y < 0 || z < 0 || x > g->nx - 1 || y > g->ny - 1 || z > g->nz - 1) return NAN;
    long x0 = (long)x, y0 = (long)y, z0 = (long)z;
    if (x0 >= g->nx - 1) x0 = g->nx - 2;
    if (y0 >= g->ny - 1) y0 = g->ny - 2;
    if (z0 >= g->nz - 1) z0 = g->nz - 2;
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (z0 < 0) z0 = 0;
    double fx = x - x0, fy = y - y0, fz = z - z0;
    long sxy = g->nx * g->ny;
    const float *p = g->v + z0 * sxy + y0 * g->nx + x0;
    long ox = (g->nx > 1) ? 1 : 0, oy = (g->ny > 1) ? g->nx : 0, oz = (g->nz > 1) ? sxy : 0;
    double c00 = p[0] * (1 - fx) + p[ox] * fx;
    double c10 = p[oy] * (1 - fx) + p[oy + ox] * fx;
    double c01 = p[oz] * (1 - fx) + p[oz + ox] * fx;
    double c11 = p[oz + oy] * (1 - fx) + p[oz + oy + ox] * fx;
    double c0 = c00 * (1 - fy) + c10 * fy, c1 = c01 * (1 - fy) + c11 * fy;
    return (float)(c0 * (1 - fz) + c1 * fz);
}

// Block average by integer factors (caller frees out->v).
static inline UMMPDT1Volume UMMPDT1Downsample(const UMMPDT1Volume *g, long fx, long fy, long fz)
{
    UMMPDT1Volume o;
    if (fx < 1) fx = 1;
    if (fy < 1) fy = 1;
    if (fz < 1) fz = 1;
    o.nx = g->nx / fx; o.ny = g->ny / fy; o.nz = g->nz / fz;
    if (o.nx < 1) o.nx = 1;
    if (o.ny < 1) o.ny = 1;
    if (o.nz < 1) o.nz = 1;
    o.dx = g->dx * fx; o.dy = g->dy * fy; o.dz = g->dz * fz;
    o.ox = g->ox + 0.5 * (fx - 1) * g->dx; o.oy = g->oy + 0.5 * (fy - 1) * g->dy; o.oz = g->oz + 0.5 * (fz - 1) * g->dz;
    float *v = (float *)calloc((size_t)(o.nx * o.ny * o.nz), sizeof(float));
    for (long z = 0; z < o.nz; z++)
        for (long y = 0; y < o.ny; y++)
            for (long x = 0; x < o.nx; x++) {
                double s = 0; long n = 0;
                for (long k = 0; k < fz; k++)
                    for (long j = 0; j < fy; j++) {
                        const float *row = g->v + (z * fz + k) * g->nx * g->ny + (y * fy + j) * g->nx + x * fx;
                        for (long i = 0; i < fx; i++) if (isfinite(row[i])) { s += row[i]; n++; }
                    }
                v[(z * o.ny + y) * o.nx + x] = n ? (float)(s / n) : 0.0f;
            }
    o.v = v;
    return o;
}

// Maps a grid point (voxel indices of the fixed grid) through t into voxel coordinates of the
// moving grid (same geometry, possibly another voxel size).
static inline void UMMPDT1MapPoint(const double R[9], const UMMPDT1Rigid *t, double cx, double cy, double cz,
                                   double px, double py, double pz, double *qx, double *qy, double *qz)
{
    double ax = px - cx, ay = py - cy, az = pz - cz;
    *qx = R[0] * ax + R[1] * ay + R[2] * az + cx + t->tx;
    *qy = R[3] * ax + R[4] * ay + R[5] * az + cy + t->ty;
    *qz = R[6] * ax + R[7] * ay + R[8] * az + cz + t->tz;
}

// Negative mean local correlation of fixed and moving∘t: the normalised cross-correlation is
// computed in blocks of about blockMM and averaged (weighted by voxels), so a slow intensity
// difference between the series (coil shading) does not pull the alignment. Fixed voxels above
// maskLevel only.
static inline double UMMPDT1Cost(const UMMPDT1Volume *fixed, const UMMPDT1Volume *moving, const UMMPDT1Rigid *t,
                                 double maskLevel, const double c[3])
{
    const double blockMM = 24.0;
    double R[9];
    UMMPDT1Matrix(t, R);
    long bx = (long)ceil(blockMM / fixed->dx), by = (long)ceil(blockMM / fixed->dy), bz = (long)ceil(blockMM / fixed->dz);
    if (bx < 2) bx = 2;
    if (by < 2) by = 2;
    if (bz < 2) bz = 2;
    long gx = (fixed->nx + bx - 1) / bx, gy = (fixed->ny + by - 1) / by, gz = (fixed->nz + bz - 1) / bz;
    long gn = gx * gy * gz;
    double *acc = (double *)calloc((size_t)gn * 6, sizeof(double));   // n, sa, sb, saa, sbb, sab per block
    long inside = 0, used = 0;
    for (long z = 0; z < fixed->nz; z++)
        for (long y = 0; y < fixed->ny; y++)
            for (long x = 0; x < fixed->nx; x++) {
                float a = fixed->v[(z * fixed->ny + y) * fixed->nx + x];
                if (!(a > maskLevel)) continue;
                inside++;
                double qx, qy, qz;
                UMMPDT1MapPoint(R, t, c[0], c[1], c[2], fixed->ox + x * fixed->dx, fixed->oy + y * fixed->dy, fixed->oz + z * fixed->dz, &qx, &qy, &qz);
                float b = UMMPDT1Sample(moving, (qx - moving->ox) / moving->dx, (qy - moving->oy) / moving->dy, (qz - moving->oz) / moving->dz);
                if (!isfinite(b)) continue;
                double *k = acc + 6 * (((z / bz) * gy + (y / by)) * gx + (x / bx));
                k[0] += 1; k[1] += a; k[2] += b; k[3] += (double)a * a; k[4] += (double)b * b; k[5] += (double)a * b;
                used++;
            }
    if (used < 100 || used < inside / 2) { free(acc); return 1.0; }   // mostly outside the moving volume
    double sum = 0, weight = 0;
    for (long i = 0; i < gn; i++) {
        double *k = acc + 6 * i, nn = k[0];
        if (nn < 20) continue;
        double va = k[3] - k[1] * k[1] / nn, vb = k[4] - k[2] * k[2] / nn;
        if (!(va > 0) || !(vb > 0)) continue;
        sum += nn * (k[5] - k[1] * k[2] / nn) / sqrt(va * vb);
        weight += nn;
    }
    free(acc);
    return weight > 0 ? -sum / weight : 1.0;
}

// Pattern search over the 6 parameters, steps halved down to the given minimum.
static inline double UMMPDT1Optimise(const UMMPDT1Volume *fixed, const UMMPDT1Volume *moving, UMMPDT1Rigid *t,
                                     double maskLevel, const double c[3], double angleStep, double shiftStep,
                                     double minFraction, int *evaluations)
{
    double best = UMMPDT1Cost(fixed, moving, t, maskLevel, c);
    int evals = 1;
    double scale = 1.0;
    while (scale >= minFraction) {
        int improved = 1;
        while (improved && evals < 4000) {
            improved = 0;
            for (int k = 0; k < 6; k++) {
                double step = (k < 3 ? angleStep : shiftStep) * scale;
                for (int sgn = -1; sgn <= 1; sgn += 2) {
                    UMMPDT1Rigid trial = *t;
                    double *p = &trial.rx + k;
                    *p += sgn * step;
                    double cost = UMMPDT1Cost(fixed, moving, &trial, maskLevel, c);
                    evals++;
                    if (cost < best - 1e-7) { best = cost; *t = trial; improved = 1; break; }
                }
            }
        }
        scale *= 0.5;
    }
    if (evaluations) *evaluations += evals;
    return best;
}

// Registers moving onto fixed (same grid). maskLevel: head threshold in fixed intensities.
// Levels of about 6, 3 and 1.5 mm. Returns the final mean local correlation (0–1).
static inline double UMMPDT1Register(const UMMPDT1Volume *fixed, const UMMPDT1Volume *moving, double maskLevel,
                                     UMMPDT1Rigid *t, int *evaluations)
{
    UMMPDT1Rigid r = {0, 0, 0, 0, 0, 0};
    double cost = 1.0;
    double c[3] = {fixed->ox + 0.5 * (fixed->nx - 1) * fixed->dx, fixed->oy + 0.5 * (fixed->ny - 1) * fixed->dy,
                   fixed->oz + 0.5 * (fixed->nz - 1) * fixed->dz};
    // Coarse to fine; the finest level is about 1.5 mm (or the voxel size, if coarser).
    const double levels[3] = {6.0, 3.0, 1.5};
    for (int l = 0; l < 3; l++) {
        long fx = (long)lround(levels[l] / fixed->dx), fy = (long)lround(levels[l] / fixed->dy), fz = (long)lround(levels[l] / fixed->dz);
        UMMPDT1Volume f = UMMPDT1Downsample(fixed, fx, fy, fz), m = UMMPDT1Downsample(moving, fx, fy, fz);
        // At the coarse level the voxel averages blur the head edge: lower the mask a little.
        const double angle[3] = {4.0, 1.0, 0.25}, shift[3] = {8.0, 2.0, 0.5}, stop[3] = {0.1, 0.1, 0.1};
        cost = UMMPDT1Optimise(&f, &m, &r, maskLevel * (l == 0 ? 0.8 : 1.0), c,
                               angle[l] * M_PI / 180, shift[l], stop[l], evaluations);
        free((void *)f.v); free((void *)m.v);
    }
    *t = r;
    return -cost;
}

// moving resampled through t onto the fixed grid (NAN outside). out must hold nx·ny·nz floats.
static inline void UMMPDT1Resample(const UMMPDT1Volume *fixed, const UMMPDT1Volume *moving, const UMMPDT1Rigid *t, float *out)
{
    double R[9];
    UMMPDT1Matrix(t, R);
    double cx = fixed->ox + 0.5 * (fixed->nx - 1) * fixed->dx, cy = fixed->oy + 0.5 * (fixed->ny - 1) * fixed->dy,
           cz = fixed->oz + 0.5 * (fixed->nz - 1) * fixed->dz;
    for (long z = 0; z < fixed->nz; z++)
        for (long y = 0; y < fixed->ny; y++)
            for (long x = 0; x < fixed->nx; x++) {
                double qx, qy, qz;
                UMMPDT1MapPoint(R, t, cx, cy, cz, fixed->ox + x * fixed->dx, fixed->oy + y * fixed->dy, fixed->oz + z * fixed->dz, &qx, &qy, &qz);
                out[(z * fixed->ny + y) * fixed->nx + x] = UMMPDT1Sample(moving, (qx - moving->ox) / moving->dx, (qy - moving->oy) / moving->dy, (qz - moving->oz) / moving->dz);
            }
}

// Slow intensity ratio post/pre (shading, coil sensitivity), from the median ratio of the head
// voxels of blocks of ≈ blockMM, smoothed over the neighbouring blocks; post is divided by it in
// place. A compact enhancing lesion is a minority of its block and barely moves the median.
// Returns the number of blocks with enough head voxels.
static inline long UMMPDT1CorrectShading(const UMMPDT1Volume *pre, float *post, double maskLevel, double blockMM)
{
    long bx = (long)lround(blockMM / pre->dx), by = (long)lround(blockMM / pre->dy), bz = (long)lround(blockMM / pre->dz);
    if (bx < 2) bx = 2;
    if (by < 2) by = 2;
    if (bz < 2) bz = 2;
    long gx = (pre->nx + bx - 1) / bx, gy = (pre->ny + by - 1) / by, gz = (pre->nz + bz - 1) / bz, gn = gx * gy * gz;
    float *ratio = (float *)malloc(sizeof(float) * (size_t)gn);
    float *buf = (float *)malloc(sizeof(float) * (size_t)(bx * by * bz));
    long good = 0;
    for (long Z = 0; Z < gz; Z++)
        for (long Y = 0; Y < gy; Y++)
            for (long X = 0; X < gx; X++) {
                long n = 0, total = 0;
                for (long z = Z * bz; z < MIN((Z + 1) * bz, pre->nz); z++)
                    for (long y = Y * by; y < MIN((Y + 1) * by, pre->ny); y++)
                        for (long x = X * bx; x < MIN((X + 1) * bx, pre->nx); x++) {
                            long i = (z * pre->ny + y) * pre->nx + x;
                            total++;
                            float a = pre->v[i], b = post[i];
                            if (a > maskLevel && isfinite(b) && b > 0) buf[n++] = b / a;
                        }
                float r = NAN;
                if (n >= 30 && n * 5 >= total) {      // at least 20 % of the block in the head
                    qsort(buf, (size_t)n, sizeof(float), UMMPDT1CompareFloats);
                    r = buf[n / 2];
                    good++;
                }
                ratio[(Z * gy + Y) * gx + X] = r;
            }
    free(buf);
    if (!good) { free(ratio); return 0; }
    // Fill blocks without a value from their neighbours (repeatedly), then smooth 3×3×3.
    float *tmp = (float *)malloc(sizeof(float) * (size_t)gn);
    for (int pass = 0; pass < 64; pass++) {
        long missing = 0;
        memcpy(tmp, ratio, sizeof(float) * (size_t)gn);
        for (long Z = 0; Z < gz; Z++)
            for (long Y = 0; Y < gy; Y++)
                for (long X = 0; X < gx; X++) {
                    long i = (Z * gy + Y) * gx + X;
                    if (isfinite(ratio[i])) continue;
                    double s = 0; long c = 0;
                    for (long k = -1; k <= 1; k++) for (long j = -1; j <= 1; j++) for (long h = -1; h <= 1; h++) {
                        long xx = X + h, yy = Y + j, zz = Z + k;
                        if (xx < 0 || yy < 0 || zz < 0 || xx >= gx || yy >= gy || zz >= gz) continue;
                        float v = ratio[(zz * gy + yy) * gx + xx];
                        if (isfinite(v)) { s += v; c++; }
                    }
                    if (c) tmp[i] = (float)(s / c); else missing++;
                }
        memcpy(ratio, tmp, sizeof(float) * (size_t)gn);
        if (!missing) break;
    }
    for (long Z = 0; Z < gz; Z++)
        for (long Y = 0; Y < gy; Y++)
            for (long X = 0; X < gx; X++) {
                double s = 0; long c = 0;
                for (long k = -1; k <= 1; k++) for (long j = -1; j <= 1; j++) for (long h = -1; h <= 1; h++) {
                    long xx = X + h, yy = Y + j, zz = Z + k;
                    if (xx < 0 || yy < 0 || zz < 0 || xx >= gx || yy >= gy || zz >= gz) continue;
                    float v = ratio[(zz * gy + yy) * gx + xx];
                    if (isfinite(v)) { s += v; c++; }
                }
                tmp[(Z * gy + Y) * gx + X] = c ? (float)(s / c) : 1.0f;
            }
    // Divide post by the ratio, interpolated trilinearly between block centres.
    UMMPDT1Volume grid = {tmp, gx, gy, gz, 1, 1, 1, 0, 0, 0};
    for (long z = 0; z < pre->nz; z++)
        for (long y = 0; y < pre->ny; y++)
            for (long x = 0; x < pre->nx; x++) {
                long i = (z * pre->ny + y) * pre->nx + x;
                if (!isfinite(post[i])) continue;
                double X = ((x + 0.5) / bx) - 0.5, Y = ((y + 0.5) / by) - 0.5, Z = ((z + 0.5) / bz) - 0.5;
                if (X < 0) X = 0;
                if (Y < 0) Y = 0;
                if (Z < 0) Z = 0;
                if (X > gx - 1) X = gx - 1;
                if (Y > gy - 1) Y = gy - 1;
                if (Z > gz - 1) Z = gz - 1;
                float r = (gx > 1 && gy > 1 && gz > 1) ? UMMPDT1Sample(&grid, X, Y, Z) : tmp[0];
                if (r > 0 && isfinite(r)) post[i] /= r;
            }
    free(tmp);
    free(ratio);
    return good;
}


// Separable 3-tap smoothing [a, 1 − 2a, a] along x, y and z, in place. With a = 1/12 this is the
// mean blur of trilinear interpolation at a random sub-voxel position (variance 1/6 voxel² per
// axis): applied to the pre series it matches the sharpness of the resampled post series, so
// thin dark structures (sulci) do not light up in the subtraction.
static inline void UMMPDT1MatchInterpolationBlur(float *v, long nx, long ny, long nz)
{
    const float a = 1.0f / 12.0f, b = 1.0f - 2.0f * a;
    long n = nx * ny * nz;
    float *t = (float *)malloc(sizeof(float) * (size_t)n);
    if (!t) return;
    long strides[3] = {1, nx, nx * ny}, sizes[3] = {nx, ny, nz};
    for (int axis = 0; axis < 3; axis++) {
        if (sizes[axis] < 3) continue;
        long st = strides[axis], len = sizes[axis];
        memcpy(t, v, sizeof(float) * (size_t)n);
        for (long i = 0; i < n; i++) {
            long pos = (i / st) % len;
            float prev = t[i - (pos > 0 ? st : 0)], next = t[i + (pos < len - 1 ? st : 0)];
            v[i] = a * prev + b * t[i] + a * next;
        }
    }
    free(t);
}

typedef struct {
    UMMPDT1Rigid transform;     // post → pre (mm, radians)
    double correlation;         // after registration
    long shadingBlocks;         // blocks used for the shading correction (0: off)
    UMMPDT1Result normalisation;
} UMMPDT1Report;

// Full pipeline: register post onto pre (optional), correct shading (optional), then ΔT1 as in
// UMMPDT1Compute. pre/post: volumes nx·ny·nz (x fastest), voxel size in mm. dt1 receives the map.
static inline int UMMPDT1Pipeline(const float *pre, const float *post, long nx, long ny, long nz,
                                  double dx, double dy, double dz, int registerSeries, int correctShading,
                                  double maskFraction, float *dt1, UMMPDT1Report *report)
{
    long n = nx * ny * nz;
    UMMPDT1Report rep;
    memset(&rep, 0, sizeof(rep));
    double p99 = UMMPDT1Percentile(pre, n, 99.0);
    if (!(p99 > 0)) return 0;
    double maskLevel = maskFraction * p99;
    UMMPDT1Volume vPre = {pre, nx, ny, nz, dx, dy, dz, 0, 0, 0}, vPost = {post, nx, ny, nz, dx, dy, dz, 0, 0, 0};
    float *moved = (float *)malloc(sizeof(float) * (size_t)n);
    if (!moved) return 0;
    if (registerSeries && nz >= 4) {
        int evals = 0;
        rep.correlation = UMMPDT1Register(&vPre, &vPost, maskLevel, &rep.transform, &evals);
        UMMPDT1Resample(&vPre, &vPost, &rep.transform, moved);
    } else {
        memcpy(moved, post, sizeof(float) * (size_t)n);
    }
    if (correctShading) rep.shadingBlocks = UMMPDT1CorrectShading(&vPre, moved, maskLevel, 16.0);
    for (long i = 0; i < n; i++) if (!isfinite(moved[i])) moved[i] = 0.0f;
    const float *preUsed = pre;
    float *preBlurred = NULL;
    if (registerSeries && nz >= 4) {
        preBlurred = (float *)malloc(sizeof(float) * (size_t)n);
        if (preBlurred) {
            memcpy(preBlurred, pre, sizeof(float) * (size_t)n);
            UMMPDT1MatchInterpolationBlur(preBlurred, nx, ny, nz);
            preUsed = preBlurred;
        }
    }
    int ok = UMMPDT1Compute(preUsed, moved, dt1, n, maskFraction, &rep.normalisation);
    free(preBlurred);
    free(moved);
    if (report) *report = rep;
    return ok;
}

// ---- Sampling another series (e.g. the rCBV map) at points in scanner coordinates ----

// One slice of a stack: origin of pixel (0,0) and row/column directions (unit vectors, patient
// coordinates in mm), pixel size, half the slab thickness it represents, and its pixels.
typedef struct {
    double o[3], row[3], col[3], normal[3];
    double sx, sy, halfThickness;
    long w, h;
    const float *img;
} UMMPDT1Slice;

static inline void UMMPDT1SliceSetNormal(UMMPDT1Slice *s)
{
    s->normal[0] = s->row[1] * s->col[2] - s->row[2] * s->col[1];
    s->normal[1] = s->row[2] * s->col[0] - s->row[0] * s->col[2];
    s->normal[2] = s->row[0] * s->col[1] - s->row[1] * s->col[0];
    double l = sqrt(s->normal[0] * s->normal[0] + s->normal[1] * s->normal[1] + s->normal[2] * s->normal[2]);
    if (l > 0) for (int k = 0; k < 3; k++) s->normal[k] /= l;
}

// Value of the stack at point p (mm): the nearest slice along its normal, if p lies within its
// slab (|distance| ≤ halfThickness), then bilinear in-plane — or the nearest pixel when one of
// the four neighbours is not a computed value (≤ 0 or not finite; maps mark those −1).
// NAN when p is outside the stack, between slices with a gap, or on a pixel without a value.
static inline float UMMPDT1SampleStack(const UMMPDT1Slice *slices, int n, const double p[3])
{
    int best = -1;
    double bestDist = 1e30;
    for (int k = 0; k < n; k++) {
        const UMMPDT1Slice *s = slices + k;
        double d = (p[0] - s->o[0]) * s->normal[0] + (p[1] - s->o[1]) * s->normal[1] + (p[2] - s->o[2]) * s->normal[2];
        if (fabs(d) < bestDist) { bestDist = fabs(d); best = k; }
    }
    if (best < 0) return NAN;
    const UMMPDT1Slice *s = slices + best;
    if (bestDist > s->halfThickness) return NAN;
    double v[3] = {p[0] - s->o[0], p[1] - s->o[1], p[2] - s->o[2]};
    double x = (v[0] * s->row[0] + v[1] * s->row[1] + v[2] * s->row[2]) / s->sx;
    double y = (v[0] * s->col[0] + v[1] * s->col[1] + v[2] * s->col[2]) / s->sy;
    if (x < -0.5 || y < -0.5 || x > s->w - 0.5 || y > s->h - 0.5) return NAN;
    long x0 = (long)floor(x), y0 = (long)floor(y);
    double fx = x - x0, fy = y - y0;
    float q[4]; int good = 1;
    for (int k = 0; k < 4; k++) {
        long xx = x0 + (k & 1), yy = y0 + (k >> 1);
        if (xx < 0) xx = 0;
        if (yy < 0) yy = 0;
        if (xx > s->w - 1) xx = s->w - 1;
        if (yy > s->h - 1) yy = s->h - 1;
        q[k] = s->img[yy * s->w + xx];
        if (!(isfinite(q[k]) && q[k] > 0)) good = 0;
    }
    if (good)
        return (float)((q[0] * (1 - fx) + q[1] * fx) * (1 - fy) + (q[2] * (1 - fx) + q[3] * fx) * fy);
    long xn = lround(x), yn = lround(y);
    if (xn < 0) xn = 0;
    if (yn < 0) yn = 0;
    if (xn > s->w - 1) xn = s->w - 1;
    if (yn > s->h - 1) yn = s->h - 1;
    float nv = s->img[yn * s->w + xn];
    return (isfinite(nv) && nv > 0) ? nv : NAN;
}

// Fractional tumour burden classes of one value: 0 low (< low), 1 intermediate, 2 high (≥ high).
static inline int UMMPDT1BurdenClass(float v, double low, double high)
{
    return (v < low) ? 0 : (v >= high ? 2 : 1);
}

#endif
