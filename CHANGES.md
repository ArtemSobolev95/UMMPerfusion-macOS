# UMMPerfusion for IsiX and Horos — changes in this port

Based on UMMPerfusion 1.5.3.2 (Computer-Assisted-Clinical-Medicine/UMMPerfusion, BSD-3-Clause,
© Universitätsmedizin Mannheim and the original authors). Ported for IsiX DICOM Viewer 6.0 on Apple
silicon. Changes in the source are marked `IsiX port`.

Not validated: compare against reference software or a digital phantom before relying on values.
Not for diagnostic use.

## Build and install

    ./build.sh            # → build/UMMPerfusion.osirixplugin
    ./build.sh install    # → ~/Library/Application Support/IsiX/Plugins

Needs Xcode and the plugin headers of IsiX (`SDKHeaders/`, taken from the App Store build, which
ships them; the GitHub build of IsiX, which loads plugins, does not). The App Store build of IsiX
loads no plugins.

## Porting

- Native arm64 build (`build.sh`) against the IsiX plugin headers, loaded by IsiX's loader for
  Horos/OsiriX plugins; ad-hoc signed.
- GraphKit (closed source, ppc/i386/x86_64 only) replaced by `GraphKitShim`, a source
  implementation of the parts the plugin uses; charts follow light/dark mode.
- Calls into IsiX from background threads moved to the main thread (crash after map generation).
- Removed: "Unsupported OsiriX version", "new plugin version" and "Final warning" popups; the
  logo/disclaimer start page (the panel opens on Fast Deconvolution); OsiriX-era images (system
  symbols in the Preferences toolbar).

## Bugs of the original fixed

- **Timing.** For Siemens, single-frame Philips and OsiriX-written data the frame times used by
  Fast Deconvolution and the "all ROIs / all algorithms / all maps" methods were never filled:
  they ran with Δt = 1 s and no interpolation. For GE data the ROI-based fits got no times. Both
  tables are now filled on every path; times without fractions no longer crash, midnight is
  handled, an out-of-range read is gone. Fast Deconvolution's time axis now starts at the first
  frame used (the start slider was compensated only in the first interval).
- Settings and presets were never read back (every start looked like a first install).
- The SVD helper shared scratch variables between the threads computing slices in parallel.
- Opening the panel twice returned an invalid object (crash).
- A chart redraw request inside drawing (endless redrawing).
- Preferences window clipped (assumed a 78-point toolbar).

## DSC additions (Fast Deconvolution, tracer T2*-DSC)

Options in **Plugins › UMMPerfusion DSC Tools**, stored in the defaults domain
`com.osirix.UMMPerfusion.DSC`. Defaults in brackets.

- Pixels without usable signal (zero baseline, a zero-signal frame) are −1 ("not computed")
  instead of producing NaN (black boxes); counts per slice in Console (filter `UMMP`).
- Brain mask [on, 10 % of the 99th percentile of the baseline signal].
- Boxerman–Weisskoff leakage correction with a K2 map [on] (Boxerman et al., AJNR 2006).
- oSVD: block-circulant SVD, per-pixel truncation by oscillation index [on, OI ≤ 0.095]
  (Wu et al., MRM 2003). Replaces the fixed SVD threshold; insensitive to bolus delay.
- First-pass blood volume [off]: ∫tissue / ∫AIF up to the first minimum of the whole-brain
  curve after its peak. Excludes recirculation; truncates the tail of slow tissue.
- Clamp zero-signal frames to 1 % of baseline [off].

Synthetic check (Δt 1.5 s, CBF 60 ml/100 ml/min, CBV 4 ml/100 ml, exponential residue, MTT 4 s):
volume 4.03–4.04 for delays −2 to +4 s with oSVD; flow 41–47 with oSVD vs 33–35 with the
previous SVD at 20 % (53 with an AIF arriving after the tissue). The flow underestimate is that of
SVD deconvolution with this sampling, not of the port. Leakage: K2 recovered exactly, corrected
curve error 0.0 % (uncorrected 33 %).

## Map appearance and rCBV

- New maps (DSC and DCE) get a colour table [Rainbow2; choice in DSC Tools] and a window fitted
  to their values.
- After Fast Deconvolution (DSC) an rCBV map is created [on]: blood volume ÷ the mean of the ROIs
  named "NAWM" or "ref" drawn on the DSC series (any time frame) before Generate, or ÷ the whole-brain median when there
  is none (the map's name says which); window 0–4.

## DSC Tools window

- Calculation options above.
- ROI statistics on the frame shown, −1 pixels excluded; mean ÷ reference ROI; "Create
  Normalized Map" (e.g. VD ÷ NAWM → rCBV); CSV export.
- AIF check: peak, arrival, width, saturated pixels, warnings.
- AIF search on the current slice: strong, early, narrow, unsaturated first-pass voxels marked
  as brush ROI "Auto AIF".

## DCE pixel maps

- Fixed: all slices wrote their time vectors into one array shared by the threads fitting in
  parallel (and past its end when the end slider was moved in): pixels could be fitted against
  another slice's times — scattered outlier values. Each slice now has its own time vector,
  relative to the first frame used.
- Fixed: fit outputs a model does not set were uninitialised memory (now NaN → −1).
- Fixed: the Modified Tofts fit had no upper limits (default preset: volume parameters limited
  only from below, Ktrans not at all), so noisy pixels ran off to negative plasma volumes and
  Ktrans of ~1e8 (checkerboard of extreme values). The fit now always keeps vp+ve and
  ve/(vp+ve) in [0, 1] and Ktrans in [0, 0.05 /s] (3 /min); pixels whose fit fails or ends on the
  Ktrans or total-volume ceiling are −1 (not computed). New presets get these limits too.
- Interstitial MTT (ve/Ktrans) is −1 where Ktrans is below 1e-4 /s (no leakage: undefined).
- New map viewers get a window from the 2nd–98th percentile of their values (−1 left out;
  upper end from the non-zero pixels) instead of the source series' window.
- Options (DSC Tools): fit the whole slice within the brain mask instead of the tissue rectangle
  [off]; 3×3 smoothing of the signal before fitting [off].

## Time Curves window

**Plugins › UMMPerfusion Time Curves** (or "Time Curves…" in DSC Tools): time curves of every ROI
of a 4D series on its own slice, overlaid; signal, relative enhancement (%), S − S0 or ΔR2*·TE;
peak, time to peak, wash-in, wash-out, area and shape (persistent / plateau / wash-out);
per-curve show/hide; CSV export; follows ROI changes. Floats above the viewers.

## Not done

- Validation (digital reference object, comparison case).
- DCE models, report, DICOM export, external AIF import, GE/Philips multiframe timing: compiled,
  not run since the port (see TESTING.md).
- Code clean-up of the original (dead shuttle-mode and 32-bit code, manual memory management).

## 1.5.3.2-port.3

- Fixed: **Export** and **Autosave Result** crashed IsiX and Horos. After exporting, the report
  view was destroyed with `dealloc` while AppKit still referenced it; it is now released
  normally. Two similar `dealloc` calls (ROI-based controllers) and a double release when the
  panel closes were fixed as well; the report chart no longer leaks.

## 1.5.3.2-port.2

First public release (IsiX and Horos).

- Automatic rCBV: an ROI named "NAWM"/"ref" drawn on the DSC series is now found (all time frames
  are searched). Previously only the new map was searched, so the whole-brain median was used.
- Horos build: `TARGET=horos ./build.sh install` or "Build Horos version.command". Compiled against the
  Horos 4.0.1 headers (third_party/Horos-headers), macOS 11+, Apple silicon + Intel, installs into
  ~/Library/Application Support/Horos/Plugins. Package: dist/UMMPerfusion-Horos-<version>.zip.
