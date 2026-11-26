UMMPerfusion for Horos — version @VERSION@
=========================================

DSC/DCE MRI perfusion plugin. A port of UMMPerfusion (Universitätsmedizin Mannheim, BSD
licence) to IsiX DICOM Viewer and Horos on current macOS, with DSC additions: leakage correction with a
K2 map, delay-insensitive oSVD deconvolution, brain mask, rCBV/rCBF normalisation, ROI
statistics with CSV export, AIF check and AIF search; for DCE, conversion of the signal to
contrast-agent concentration with a fixed T1 or a T1 map.

RESEARCH USE ONLY. Not a medical device, not validated for diagnosis. Check values against
the software you normally use before relying on them.


REQUIREMENTS
------------
- macOS 11 (Big Sur) or later, Apple silicon or Intel.
- Horos 4.0.1 (https://horosproject.org). Use the Apple silicon download on an M-series Mac
  and the Intel download on an Intel Mac; the plugin works in both.


INSTALL
-------
1. Quit Horos.
2. Double-click "Install UMMPerfusion.command".
   If macOS says it cannot be opened because the developer cannot be verified:
   System Settings > Privacy & Security, scroll down, "Open Anyway" next to the message,
   then double-click it again.
   Or, in Terminal (adjust the path to where you unzipped it):
       xattr -dr com.apple.quarantine ~/Downloads/UMMPerfusion-Horos-@VERSION@
       ~/Downloads/UMMPerfusion-Horos-@VERSION@/"Install UMMPerfusion.command"
3. Open Horos. Plugins > Plugins Manager should list UMMPerfusion as loaded.

To remove it: delete ~/Library/Application Support/Horos/Plugins/UMMPerfusion.osirixplugin


QUICK START (DSC, brain tumour)
-------------------------------
1. Open the 4D DSC series.
2. Plugins > Image Filters > UMMPerfusion DSC Tools: draw a small ROI on an MCA branch (or use
   "Find AIF Voxels on Current Slice" on a slice through the MCAs), then "Check AIF".
3. Plugins > Image Filters > UMMPerfusion: Fast Deconvolution, tracer T2*-DSC, choose the arterial ROI,
   set the baseline (red line in the chart) to end just before the signal drops, Generate.
   Maps: Plasma Flow (CBF), Volume of Distribution (CBV), Mean Transit Time, Leakage K2.
   Pixels that could not be computed (no signal, outside the brain mask) are -1.
4. On the CBV map: draw a reference ROI in contralateral normal-appearing white matter.
   In DSC Tools choose it as the reference, Measure, "Create Normalized Map" (rCBV), draw
   lesion ROIs, Measure again, "Export CSV".

Checks: Δt in the panel's chart matches the temporal resolution; grey matter about 2-3x
white matter on the CBV map. Console.app, filter "UMMP", shows timing, mask and warnings.


QUICK START (DCE, modified Tofts)
--------------------------------
1. Open the 4D T1-weighted DCE series (spoiled gradient echo: VIBE, THRIVE, LAVA, FLASH).
2. DSC Tools > Calculation options > "Fit input": "Concentration, fixed pre-contrast T1"
   (or "T1 map" with a T1 map open in another viewer). The line below shows TR, flip angle
   and field strength from the header; empty fields use the defaults shown.
3. Image filters > UMMPerfusion: Modified Tofts pixel map, arterial ROI in a large artery
   (central pixels only), tissue ROI around the region. Maps: Ktrans (ml/100 ml/min = /min x
   100), ve and vp (ml/100 ml).
With a fixed T1, fat and fatty marrow come out with a falsely high Ktrans (their T1 is much
shorter); a T1 map avoids it. "Off" reproduces the original plugin (signal enhancement fitted
as if it were concentration: vp about doubled, ve too low).


QUICK START (ΔT1 and tumour burden)
-----------------------------------
1. Open the pre- and post-contrast 3D T1 (same sequence and slices) and, for step 4, the rCBV
   map (rCBV normalised to NAWM, from step 4 above).
2. Plugins > Image Filters > UMMPerfusion ΔT1 & Tumour Burden. Section 1: choose Pre and Post,
   "Create ΔT1 Map" (post is aligned onto pre and shading-corrected automatically).
3. Draw ROIs around the lesion / resection bed (ΔT1 map, pre or post series; Grow Region 3D
   works), section 2 "Measure Enhancing in ROIs" (enhancing = ΔT1 > 0.2 by default).
4. Section 3: choose the rCBV map, "Compute Tumour Burden" (low < 1.0, high >= 1.75).
5. Colour overlay on the post-contrast T1; "Save Current Measurement" for the follow-up table.
Thresholds are starting points from the literature, not validated for your protocol.

Options (DSC Tools): brain mask, leakage correction and oSVD are on by default; first-pass
blood volume and clamping of zero-signal frames are off.

Details of all changes: CHANGES.md.
Updates and source code: https://github.com/ArtemSobolev95/UMMPerfusion-macOS
