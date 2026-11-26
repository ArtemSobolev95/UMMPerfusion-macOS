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

## 1.5.3.2-port.9

DCE: signal to concentration before the fit (DSC Tools › Calculation options, "Fit input").

- The original plugin fits relative (or absolute) signal enhancement as if it were concentration.
  On spoiled gradient-echo DCE this biases the parameters (Tests/test_tofts.c, part B: ve −26…−44 %,
  vp +98…+159 %), because the arterial signal saturates far more than tissue.
- New: the SPGR signal equation is inverted per curve (Sources/UMMPConcentration.h):
  R1 from S/S0 with TR and flip angle from the DICOM header (editable), C = (R1 − R10)/r1.
  - **Fixed pre-contrast T1**: blood for the arterial and venous curves (1.55 s at 1.5 T, 1.93 s at
    3 T), one tissue value for every pixel (1.30 s / 1.60 s); all editable, r1 default 4.5 /mM/s.
  - **T1 map (per pixel)**: an open T1 map viewer (ms or s, detected) is sampled at every DCE pixel
    in scanner coordinates, so other slices or orientation are fine; implausible values and pixels
    outside the map use the fixed tissue T1. ROI fits use the mean T1 under the ROI.
- All DCE models (ROI-based, pixel maps, 2CXM/uptake, 2-inlet, AF tools) use it; T2*-DSC is unchanged.
  "Off" keeps the original behaviour.
- Tests/test_tofts.c parts C and D: with the conversion the Tofts fit recovers Ktrans, ve, vp within
  1 %; a tissue T1 off by ±20 % moves them by −21…+35 %.

## 1.5.3.2-port.8

- **Standardised rCBV (sRCBV)**: rCBV on one scale for all patients and visits without a reference
  ROI. Histogram standardisation of Nyúl & Udupa as applied to rCBV by Bedekar, Jensen & Schmainda
  (MRM 2010;64:907): 11 landmarks (1st percentile, deciles, 99.8th percentile) of the computed
  pixels of the whole map; piecewise linear mapping onto a standard scale 0–50 000 learnt from
  calibration maps; values above the 99.8th percentile set to the maximum (vessels). Displayed
  ÷ the mean standardised NAWM of the calibration cases that have an ROI named "NAWM"/"ref"
  (else ÷ the standard median), so 1 ≈ NAWM. Same result from a blood-volume map and from the
  same map ÷ NAWM.
- The calibration is the site's own (`Sources/UMMPStandardize.h`, `Sources/UMMPSRCBV.h`): the
  values are **not** on the IB Neuro scale (its calibration is not published) and published
  sRCBV thresholds do not transfer. Use one calibration per DSC protocol; ≥ 10 cases advised.
- DSC Tools: new section "Standardised rCBV" — Create sRCBV Map, Add Map to Calibration,
  Remove Last Case, Reset, Export / Import Calibration (a .plist to share with colleagues on the
  same protocol). Option: create an sRCBV map automatically after Fast Deconvolution when a
  calibration exists [on].
- `Tests/test_standardize.c`: checks of the maths on synthetic maps (plain C, runs anywhere).
- **ΔT1 map** (DSC Tools › "ΔT1 map"): choose the pre- and post-contrast T1 viewers; each series
  is divided by the median of its own pixels inside the head mask (pre signal > brain-mask % of
  its 99th percentile), then ΔT1 = post − pre, so non-enhancing tissue is ≈ 0 whatever the gain
  of each series; 0 outside the mask. Optional brush ROI "Enhancing (ΔT1 > t)" [t = 0.2] on every
  slice, with pixel count and volume in ml. Both series must share matrix, slices, position and
  orientation (checked to half a pixel; else refused: same 3D sequence, or resample post onto
  pre first). Per-pair normalisation, not the trained standardisation of IB Delta Suite.
  `Sources/UMMPDeltaT1.h`, `Tests/test_deltat1.c`.
- Fixed (ΔT1, tested in IsiX 6.0): the new viewer showed the pre-contrast T1 instead of ΔT1, and
  the result line never appeared. IsiX fills a viewer made by `duplicateViewer:` asynchronously
  with the source pixels (overwriting what the plugin wrote; its pixel list can still be empty when
  the call returns). The ΔT1 viewer is now built with `+[ViewerController newWindow:::]` from copies
  of the pre series' slices pointing into the plugin's own ΔT1 volume. The result line ends with a
  check that the viewer holds the computed values.
- **ΔT1 & Tumour Burden window** (own menu item; button in DSC Tools): ΔT1 map (moved out of DSC
  Tools), enhancing volume inside user ROIs, fractional tumour burden from an rCBV/sRCBV map
  sampled in scanner coordinates, per-patient follow-up (hashed patient ID) with change from
  baseline and nadir and the modified-RANO volumetric ranges, CSV export.
- **Colour overlay on the post-contrast T1** (ΔT1 & Tumour Burden window): the enhancing voxels
  graded by ΔT1 (threshold–2×, 2–3.5×, ≥ 3.5× the threshold: yellow, orange, red) or the FTB
  classes (green, yellow, red), semi-transparent brush ROIs named "ΔT1 overlay …" (ignored by the
  measurements); inside your ROIs or over the whole series; Remove button.
- Fixed: closing a viewer while the ΔT1 window was open crashed IsiX (a stored pointer to the
  closed viewer was messaged by -[NSArray containsObject:]). Viewers are now compared by address.
- ΔT1: **automatic rigid alignment** of the post series onto the pre series [on] and **shading
  correction** [on]. First test case: with the head moved between the scans, the sulci and the
  head edges lit up as "enhancing" (the slab geometry was identical, so the geometry check passed).
  Alignment: 6 parameters (3 rotations about the volume centre, 3 shifts), mean local correlation
  in 24 mm blocks (insensitive to coil shading), pattern search at ≈ 6, 3 and 1.5 mm; post
  resampled trilinearly onto the pre grid; the pre series gets the matching mean interpolation
  blur ([1/12, 5/6, 1/12] per axis) so thin sulci do not appear in the difference. Shading: the
  median post/pre ratio of the head voxels of 16 mm blocks, gaps filled from neighbours, smoothed
  3×3×3 blocks, interpolated, post divided by it (a compact lesion is a minority of its block).
  Runs in the background; the result line gives the rotation, shift and correlation found.
  Synthetic head (`Tests/test_deltat1_registration.c`: 3°/−4°/2° and 5/−4/3 mm motion, opposite
  shading): brain voxels falsely above 0.2 29 % → 1.8 %, sulci +0.51 → +0.08, lesion core 100 %,
  motion found within 0.06° and 0.01 mm.

## 1.5.3.2-port.7

- New UMMPerfusion toolbar icon: a DSC perfusion map with "DSC", rounded corners.

## 1.5.3.2-port.6

- Toolbar buttons: UMMPerfusion, UMMPerfusion DSC Tools and UMMPerfusion Time Curves can be added
  to the viewer toolbar (right-click the toolbar › Customize Toolbar…), each with its own icon.

## 1.5.3.2-port.5

- Fixed: "Unsupported Mac OS – This Plugin requires at least Mac OS 10.8.4" on current macOS when
  the Mac is set to a language other than English. The original check cut the version number out
  of a localised text; it is removed (the plugin cannot load on an unsupported macOS anyway).

## 1.5.3.2-port.4

- **Export / Autosave in IsiX** no longer hangs (endless "Saving results…", crash after Abort).
  Exported maps are added with the current database call (`-[DicomDatabase addFilesAtPaths:…]`)
  instead of the deprecated `+[BrowserController addFiles:…]` and `-checkIncoming:`, and the
  second, nested "Saving…" window is gone. Abort now stops the export cleanly (the report is
  not written after an abort). Progress is logged to Console.app ("UMMP export").
- **Much faster start**: opening the plugin on a 60 × 30 DSC series went from several seconds
  to 0.2 s. The acquisition time of every image is now read with a small header reader that
  stops at the needed tag (`UMMPFastDicom.h`), in parallel, instead of a full DCMObject parse of
  every file; unusual files still fall back to DCMObject. Results are identical.

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
