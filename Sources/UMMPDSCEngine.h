//
//  UMMPDSCEngine.h — DSC-MRI extensions added in the IsiX port of UMMPerfusion.
//
//  Used by Fast Deconvolution when the tracer is "T2*-DSC":
//   - brain mask        pixels whose baseline signal is below a fraction of the bright end of the
//                       volume are not computed (-1 on the maps)
//   - leakage           Boxerman-Weisskoff correction: each pixel's ΔR2*(t) is fitted as
//                       K1·R(t) − K2·∫R, R = whole-brain mean ΔR2*; K2·∫R is added back.
//                       Boxerman JL et al., AJNR 2006;27:859-867. K2 is returned as a map.
//   - oSVD              block-circulant SVD with a per-pixel truncation chosen by the oscillation
//                       index (Wu O et al., MRM 2003;50:164-174): insensitive to bolus delay.
//   - first pass        blood volume as the ratio of tissue and arterial integrals over the first
//                       pass of the bolus (window from the whole-brain curve), excluding recirculation.
//
//  Settings live in the plugin's defaults domain (com.osirix.UMMPerfusion) and are edited in the
//  DSC Tools window.
//

#import <Foundation/Foundation.h>

typedef struct {
    BOOL   mask;            // brain mask on
    double maskFraction;    // threshold = maskFraction × 99th percentile of baseline signal
    BOOL   leakage;         // Boxerman-Weisskoff correction
    BOOL   oSVD;            // block-circulant SVD with oscillation-index truncation
    double oiThreshold;     // maximum oscillation index (Wu 2003: 0.095 at SNR 20, 0.085 at SNR 100)
    BOOL   firstPass;       // first-pass integration for the blood volume
    BOOL   clamp;           // clamp zero-signal frames instead of discarding the pixel
} UMMPDSCSettings;

UMMPDSCSettings UMMPDSCLoadSettings(void);
void UMMPDSCSaveSettings(UMMPDSCSettings settings);
NSString *UMMPDSCSettingsDescription(UMMPDSCSettings settings);

// Prepared on the main thread before the slices are computed in parallel; read-only meanwhile.
typedef struct {
    BOOL   active;          // DSC extensions in use for the current calculation
    UMMPDSCSettings settings;
    double maskThreshold;   // baseline signal below this is outside the mask
    int    n;               // number of frames of the calculation
    double *reference;      // whole-brain mean ΔR2*(t), n values, or NULL
    int    fpStart, fpEnd;  // first-pass window, frame indices (inclusive)
    long   referencePixels; // pixels averaged into the reference
} UMMPDSCContext;

extern UMMPDSCContext UMMPDSCCurrent;

// srcPix: one NSArray of DCMPix per time frame of the viewer (all frames).
// Frames start .. start+n-1 are used, the first bl of them as baseline; slices sliceFrom..sliceTo (0-based, inclusive).
void UMMPDSCPrepare(NSArray *srcPix, int start, int n, int bl, int sliceFrom, int sliceTo, UMMPDSCSettings settings);
void UMMPDSCFinish(void);

// ΔR2*·TE from signal and baseline; NAN where undefined (see UMMPFastDeconvolution.m).
double UMMPDSCConcentrationValue(double signal, double baseline, BOOL clamp);

// Leakage correction in place on p (imageSize pixels × n frames, pixel-major as in fd), using
// UMMPDSCCurrent.reference and the calculation's time vector. k2 (may be NULL) receives K2 per pixel.
void UMMPDSCCorrectLeakage(double *p, int n, int imageSize, const double *time, float *k2);

// First-pass blood volume fraction per pixel: ∫C / ∫AIF over the first-pass window.
void UMMPDSCFirstPassVolume(const double *p, int n, int imageSize, const float *aif, const double *time, double *vdOut);

// Block-circulant SVD deconvolution with per-pixel oscillation-index truncation.
// p: imageSize × n (uniform sampling dt), aif: n values. Outputs flow (max of the residue, per s)
// and volume fraction (∫ residue) per pixel.
void UMMPDSCoSVD(const double *p, int n, int imageSize, const float *aif, double dt, double oiMax,
                 double *flowOut, double *volumeOut);
