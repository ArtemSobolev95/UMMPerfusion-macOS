UMMPerfusion for Horos — version @VERSION@
=========================================

DSC/DCE MRI perfusion plugin. A port of UMMPerfusion (Universitätsmedizin Mannheim, BSD
licence) to IsiX DICOM Viewer and Horos on current macOS, with DSC additions: leakage correction with a
K2 map, delay-insensitive oSVD deconvolution, brain mask, rCBV/rCBF normalisation, ROI
statistics with CSV export, AIF check and AIF search.

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

Options (DSC Tools): brain mask, leakage correction and oSVD are on by default; first-pass
blood volume and clamping of zero-signal frames are off.

Details of all changes: CHANGES.md.
Updates and source code: https://github.com/ArtemSobolev95/UMMPerfusion-macOS
