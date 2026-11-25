// Registration and shading correction of the ΔT1 pipeline (Sources/UMMPDeltaT1.h). Plain C:
//   cc -O2 -o /tmp/test_reg Tests/test_deltat1_registration.c -lm && /tmp/test_reg
//
// Synthetic head on a 1.6 × 1.6 × 2.0 mm grid: scalp fat, skull, grey matter with sulci (CSF),
// white matter, ventricles and an enhancing lesion of 12 mm radius. The post series is the same
// head moved (3° and 4° rotations, 5/−4/3 mm shift), with another coil shading, contrast in the
// lesion and in the vessels/dura, and noise. Without correction the sulci and edges light up;
// with it they must not.

#include <stdio.h>
#include <time.h>
#include "../Sources/UMMPDeltaT1.h"

#define NX 140
#define NY 140
#define NZ 90
static const double DX = 1.6, DY = 1.6, DZ = 2.0;

static unsigned long long rs = 88172645463325252ULL;
static double urand(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return (rs >> 11) * (1.0 / 9007199254740992.0); }
static double nrand(void) { double u = urand(), v = urand(); if (u < 1e-12) u = 1e-12; return sqrt(-2 * log(u)) * cos(2 * M_PI * v); }

enum { BG, FAT, BONE, CSF, GM, WM, VENT, LES, DURA };
static const double C[3] = {0.5 * (NX - 1) * 1.6, 0.5 * (NY - 1) * 1.6, 0.5 * (NZ - 1) * 2.0};
static const double LES_C[3] = {0.5 * (NX - 1) * 1.6 + 25, 0.5 * (NY - 1) * 1.6 - 10, 0.5 * (NZ - 1) * 2.0 + 8};

// Tissue class at a point (mm).
static int tissue(double x, double y, double z)
{
    double ex = (x - C[0]) / 85, ey = (y - C[1]) / 100, ez = (z - C[2]) / 80;
    double r = sqrt(ex * ex + ey * ey + ez * ez);
    if (r > 1.0) return BG;
    if (r > 0.94) return FAT;
    if (r > 0.88) return BONE;
    if (r > 0.865) return DURA;
    double lx = x - LES_C[0], ly = y - LES_C[1], lz = z - LES_C[2];
    if (lx * lx + ly * ly + lz * lz < 12.0 * 12.0) return LES;
    double vx = (x - C[0]) / 12, vy = (y - C[1] + 5) / 30, vz = (z - C[2]) / 15;
    if (vx * vx + vy * vy + vz * vz < 1.0) return VENT;
    if (r > 0.70) {                                    // cortex with sulci
        double sul = sin(x * 0.45) * sin(y * 0.38) * sin(z * 0.31);
        return (sul > 0.55) ? CSF : GM;
    }
    return WM;
}

static double preSignal(int c)  { switch (c) { case FAT: return 1.7; case BONE: return 0.05; case DURA: return 0.6; case CSF: case VENT: return 0.25; case GM: return 0.75; case WM: return 1.0; case LES: return 0.7; default: return 0.0; } }
static double enhancement(int c) { switch (c) { case LES: return 0.7; case DURA: return 0.6; default: return 0.0; } }

int main(void)
{
    long n = (long)NX * NY * NZ;
    float *pre = malloc(sizeof(float) * n), *post = malloc(sizeof(float) * n), *dt1 = malloc(sizeof(float) * n);
    unsigned char *cls = malloc(n);
    UMMPDT1Rigid truth = {3.0 * M_PI / 180, -4.0 * M_PI / 180, 2.0 * M_PI / 180, 5.0, -4.0, 3.0};
    double R[9];
    UMMPDT1Matrix(&truth, R);
    for (long z = 0; z < NZ; z++)
        for (long y = 0; y < NY; y++)
            for (long x = 0; x < NX; x++) {
                long i = (z * NY + y) * NX + x;
                double px = x * DX, py = y * DY, pz = z * DZ;
                int c = tissue(px, py, pz);
                cls[i] = (unsigned char)c;
                double shade1 = 1.0 + 0.35 * (px - C[0]) / 110 - 0.15 * (pz - C[2]) / 90;
                pre[i] = (float)(820.0 * shade1 * preSignal(c) * (1 + 0.03 * nrand()) + 8 * fabs(nrand()));
                // post at q = p: the head moved, so look up the anatomy at T⁻¹(q) = Rᵀ(q − c − t) + c
                double ax = px - C[0] - truth.tx, ay = py - C[1] - truth.ty, az = pz - C[2] - truth.tz;
                double sx = R[0] * ax + R[3] * ay + R[6] * az + C[0];
                double sy = R[1] * ax + R[4] * ay + R[7] * az + C[1];
                double sz = R[2] * ax + R[5] * ay + R[8] * az + C[2];
                int c2 = tissue(sx, sy, sz);
                double shade2 = 1.0 - 0.25 * (px - C[0]) / 110 + 0.30 * (py - C[1]) / 110;
                post[i] = (float)(1350.0 * shade2 * (preSignal(c2) + enhancement(c2)) * (1 + 0.03 * nrand()) + 8 * fabs(nrand()));
            }

    int failures = 0;
    #define CHECK(ok, what) do { printf("%s  %s\n", (ok) ? "ok  " : "FAIL", what); if (!(ok)) failures++; } while (0)

    for (int mode = 0; mode < 2; mode++) {
        clock_t t0 = clock();
        UMMPDT1Report rep = {0};
        int ok = UMMPDT1Pipeline(pre, post, NX, NY, NZ, DX, DY, DZ, mode, mode, 0.10, dt1, &rep);
        double secs = (double)(clock() - t0) / CLOCKS_PER_SEC;
        double sum[9] = {0}; long cnt[9] = {0}, falsePos = 0, brain = 0, lesionHit = 0, lesion = 0;
        for (long i = 0; i < n; i++) {
            sum[cls[i]] += dt1[i]; cnt[cls[i]]++;
            if (cls[i] == GM || cls[i] == WM || cls[i] == CSF) { brain++; if (dt1[i] > 0.2) falsePos++; }
            // lesion core only (2 mm inside its edge): partial volume at the rim is expected
            if (cls[i] == LES) {
                long z = i / (NX * NY), y = (i / NX) % NY, x = i % NX;
                double lx = x * DX - LES_C[0], ly = y * DY - LES_C[1], lz = z * DZ - LES_C[2];
                if (lx * lx + ly * ly + lz * lz < 10.0 * 10.0) { lesion++; if (dt1[i] > 0.2) lesionHit++; }
            }
        }
        printf("\n%s (%.1f s)\n", mode ? "WITH registration + shading correction" : "WITHOUT correction", secs);
        if (mode)
            printf("     found: rotation %.2f %.2f %.2f°, shift %.2f %.2f %.2f mm (truth 3 −4 2°, 5 −4 3 mm); r = %.3f; shading blocks %ld\n",
                   rep.transform.rx * 180 / M_PI, rep.transform.ry * 180 / M_PI, rep.transform.rz * 180 / M_PI,
                   rep.transform.tx, rep.transform.ty, rep.transform.tz, rep.correlation, rep.shadingBlocks);
        printf("     mean ΔT1: WM %.3f  GM %.3f  sulcal CSF %.3f  ventricles %.3f  lesion %.3f  dura %.3f\n",
               sum[WM] / cnt[WM], sum[GM] / cnt[GM], sum[CSF] / cnt[CSF], sum[VENT] / cnt[VENT], sum[LES] / cnt[LES], sum[DURA] / cnt[DURA]);
        printf("     brain voxels (WM, GM, sulci) above 0.2: %.2f %%; lesion core above 0.2: %.1f %%\n",
               100.0 * falsePos / brain, 100.0 * lesionHit / lesion);
        if (mode) {
            CHECK(ok, "pipeline ran");
            CHECK(fabs(rep.transform.rx * 180 / M_PI - 3) < 0.5 && fabs(rep.transform.ry * 180 / M_PI + 4) < 0.5 &&
                  fabs(rep.transform.rz * 180 / M_PI - 2) < 0.5, "rotations within 0.5°");
            CHECK(fabs(rep.transform.tx - 5) < 0.8 && fabs(rep.transform.ty + 4) < 0.8 && fabs(rep.transform.tz - 3) < 0.8, "shifts within 0.8 mm");
            CHECK(100.0 * falsePos / brain < 2.0, "fewer than 2 % of brain voxels falsely above 0.2");
            CHECK(fabs(sum[CSF] / cnt[CSF]) < 0.08 && fabs(sum[WM] / cnt[WM]) < 0.08, "sulci and white matter ≈ 0");
            CHECK(100.0 * lesionHit / lesion > 95.0, "lesion core found");
            CHECK(secs < 60, "runs in under a minute here");
        }
    }
    printf("\n%s\n", failures ? "FAILED" : "all checks passed");
    return failures != 0;
}
