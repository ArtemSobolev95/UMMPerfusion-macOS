# UMMPerfusion for IsiX — test checklist

Run once after each build. Keep Console.app open with the filter `UMMP`. If IsiX quits, the crash
report is in Console › Crash Reports (IsiX DICOM Viewer).

## A. Loading

- [ ] Plugins › Plugins Manager lists UMMPerfusion as loaded.
- [ ] Image filters menu shows "UMMPerfusion" and "UMMPerfusion DSC Tools".
- [ ] Starting UMMPerfusion on a non-4D series shows "Invalid Viewer" and nothing else.

## B. DSC (Fast Deconvolution)

- [ ] Panel opens on Fast Deconvolution; Δt in the chart matches the temporal resolution.
- [ ] Console shows: time points, Δt, "UMMP DSC: mask … reference from … pixels, first pass frames …".
- [ ] Maps: Plasma Flow, Volume of Distribution, Mean Transit Time, Leakage K2; background −1.
- [ ] VD ≈ PF × MTT / 60 in an ROI in normal grey matter (oSVD on).
- [ ] K2 near 0 in normal brain; non-zero in enhancing lesions.
- [ ] Repeat with each option off in DSC Tools (mask, leakage, oSVD), and first pass on.

## C. DSC Tools

- [ ] Maps: Refresh ROIs lists the ROIs; Measure fills the table; −1 pixels counted as excluded.
- [ ] Reference ROI (NAWM) → "Mean ÷ ref" column; Create Normalized Map opens a new viewer ≈ 1 in NAWM.
- [ ] Export CSV writes a file that opens in Numbers/Excel.
- [ ] 4D series: Check AIF on the arterial ROI gives plausible numbers and warnings.
- [ ] Find AIF Voxels on a slice through the MCA marks voxels in/next to arteries; "Auto AIF"
      appears in the panel's arterial ROI list.

## C2. sRCBV (DSC Tools › Standardised rCBV)

- [ ] `cc -O2 -o /tmp/t Tests/test_standardize.c -lm && /tmp/t` prints "all checks passed".
- [ ] Without calibration: "Create sRCBV Map" says there is no calibration; Fast Deconvolution makes no sRCBV map.
- [ ] Add Map to Calibration on a Volume of Distribution map with an ROI named NAWM: summary shows
      1 case, "1 = mean NAWM of 1 case"; adding the same map again is refused; on the 4D series it is refused.
- [ ] Create sRCBV Map on that map: new viewer "sRCBV (calibration 1 case, 1 = NAWM)", NAWM ROI mean ≈ 1, background −1.
- [ ] Same result on the rCBV (÷ NAWM) map of the same case.
- [ ] After Fast Deconvolution with a calibration: an sRCBV viewer appears next to the rCBV one.
- [ ] Export, Reset, Import (Replace and Add to Current); Remove Last Case.
- [ ] With ≥ 10 cases: NAWM sRCBV of new patients near 1 without drawing any ROI.

## C3. ΔT1 map (DSC Tools › ΔT1 map)

- [ ] `cc -O2 -o /tmp/t Tests/test_deltat1.c -lm && /tmp/t` prints "all checks passed".
- [ ] Pre and Post popups list the open single-frame viewers; Refresh after opening another series.
- [ ] Pre = Post, or series with other slices/matrix: refused with the reason.
- [ ] Same 3D T1 before and after contrast: new viewer "ΔT1 …"; white matter ≈ 0, enhancing lesion,
      vessels and choroid plexus positive; background 0; result line shows medians and mask size.
- [ ] ROI "Enhancing (ΔT1 > 0.2)" on every slice with enhancement; volume plausible against a manual
      measurement; unchecking the box makes no ROI.

## D. Untouched parts (compiled, not run since the port)

- [ ] DCE: one ROI-based fit (e.g. Modified Tofts) and one pixel-based map.
- [ ] "all ROIs", "all algorithms", "all maps".
- [ ] 2-compartment 2-inlet (ROI and pixel).
- [ ] Report window; Export (DICOM) of maps.
- [ ] Preferences: every toolbar page shows completely; presets survive a restart of IsiX.
- [ ] External AIF import (Preferences › AIF Import).
- [ ] A GE series and a Philips multiframe series, if available (timing paths).

## E. Validation (before using numbers)

- [ ] A digital reference object with known CBF/CBV/MTT.
- [ ] One clinical case against software in use (rCBV in lesion and NAWM).
