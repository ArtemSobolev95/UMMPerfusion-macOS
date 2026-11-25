# UMMPerfusion for IsiX and Horos (macOS)

MRI perfusion analysis plugin for the **IsiX DICOM Viewer** and **Horos** on current macOS,
Apple silicon and Intel. It is a port of
[UMMPerfusion](https://github.com/Computer-Assisted-Clinical-Medicine/UMMPerfusion)
(Universitätsmedizin Mannheim), extended for DSC brain perfusion.

> **Research and teaching use only.** Not a medical device and not validated for diagnosis.
> Check results against the software you normally use before relying on them. The sRCBV and ΔT1
> scales are this plugin's own (not those of IB Neuro / IB Delta Suite); published thresholds
> are starting points, not validated cut-offs for your protocol.

## Download

Current version: **1.5.3.2-port.8**. Click the package for your viewer:

| Viewer | Download | macOS | Mac |
|---|---|---|---|
| IsiX DICOM Viewer 6.0.3+ (GitHub build) | [**UMMPerfusion-IsiX-1.5.3.2-port.8.zip**](https://github.com/ArtemSobolev95/UMMPerfusion-macOS/raw/main/downloads/UMMPerfusion-IsiX-1.5.3.2-port.8.zip) | 15 or later | Apple silicon and Intel |
| Horos 4.0.1 | [**UMMPerfusion-Horos-1.5.3.2-port.8.zip**](https://github.com/ArtemSobolev95/UMMPerfusion-macOS/raw/main/downloads/UMMPerfusion-Horos-1.5.3.2-port.8.zip) | 11 or later | Apple silicon and Intel |

Each package works on both kinds of Mac. The App Store version of IsiX loads no plugins; use the
[GitHub build of IsiX](https://github.com/ThalesMMS/IsiX-DICOM-Viewer-macOS/releases).

Optional test data: [DSC_Phantom_DICOM.zip](https://github.com/ArtemSobolev95/UMMPerfusion-macOS/raw/main/downloads/DSC_Phantom_DICOM.zip) (synthetic DSC series, see below).
All files are also in the [`downloads/`](downloads) folder.

### Install

1. Quit the viewer.
2. Unzip the package and double-click **Install UMMPerfusion.command**.
   If macOS says the developer cannot be verified: System Settings › Privacy & Security ›
   *Open Anyway*, then double-click it again.
3. Open the viewer. *Plugins › Plugins Manager* should list UMMPerfusion as loaded.

The plugin appears under the image filters menu as **UMMPerfusion**, **UMMPerfusion DSC Tools**,
**UMMPerfusion Time Curves** and **UMMPerfusion ΔT1 & Tumour Burden**. The README in the package
has a quick start.

Toolbar buttons: right-click the viewer toolbar › *Customize Toolbar…* and drag **UMMPerfusion**,
**UMMPerfusion DSC Tools** and **UMMPerfusion Time Curves** onto it.

## What it does

From the original plugin:

- **DSC**: Fast Deconvolution → plasma flow (CBF), volume of distribution (CBV), mean transit time
- **DCE**: compartment models (modified Tofts, 2CXM, 2C filtration, 2C uptake, two-inlet),
  ROI-based and pixel-by-pixel maps

Added in this port:

- Delay-insensitive **oSVD** deconvolution, **leakage correction** (Boxerman–Weisskoff) with a
  K2 map, automatic **brain mask**, optional first-pass integration
- **Automatic rCBV map** normalised to an ROI named `NAWM` (or the whole-brain median)
- **DSC Tools** window: ROI statistics, normalised maps, CSV export, AIF check and AIF search
- **Time Curves** window: compare signal / enhancement curves of several ROIs (DCE or DSC)
- **Standardised rCBV (sRCBV)**: histogram standardisation (Bedekar et al. 2010) with your own
  calibration cases, so maps share one scale without a reference ROI; calibration export/import
- **ΔT1 & Tumour Burden** window:
  - **ΔT1 map** from pre- and post-contrast 3D T1, with automatic rigid alignment (head movement
    between the scans) and coil-shading correction
  - **Enhancing volume** inside the ROIs you draw (lesion, resection bed)
  - **Fractional tumour burden**: the enhancing voxels classified by the rCBV/sRCBV map (low <
    1.0, high ≥ 1.75 by default, as in Iv et al. AJNR 2019), sampled in scanner coordinates
  - **Colour overlay** of ΔT1 or of the FTB classes on the post-contrast T1
  - **Follow-up** table per patient: change from baseline and nadir, modified-RANO volumetric
    ranges, CSV export
- DCE maps over the whole slice with masking and smoothing; robust failed-fit handling
- Correct timing (Δt) from DICOM acquisition times, multithreading fixes, dark mode, colour maps
  (Rainbow2 by default)

Full list: [CHANGES.md](CHANGES.md).

## Testing with the synthetic phantom

[`DSC_Phantom/`](DSC_Phantom) contains a generator for a synthetic DSC series with known CBV, CBF
and MTT (clean, noise, bolus delay, leakage), with the answer key and the expected plugin
results. The ready-made DICOM files are in [`downloads/DSC_Phantom_DICOM.zip`](downloads/DSC_Phantom_DICOM.zip).

```sh
python3 DSC_Phantom/make_dsc_phantom.py DSC_Phantom   # needs numpy
```

## Building from source

Needs Xcode. The plugin SDK headers are included in [`third_party/`](third_party).

```sh
./build.sh install                   # IsiX build, installs into IsiX
TARGET=horos ./build.sh install      # Horos build, installs into Horos
TARGET=isix ./package.sh; TARGET=horos ./package.sh   # release zips in dist/
```

Or double-click *Build IsiX version.command*, *Build Horos version.command* or
*Build release.command* (both zips, nothing installed).

## Citation

If you use the plugin, please cite the original UMMPerfusion papers:

- Zöllner F. et al. UMMPerfusion: an open source software tool for quantitative MRI perfusion
  analysis in clinical routine. *J Digit Imaging* 2013;26(2):344–352.
  doi:10.1007/s10278-012-9510-6
- Zöllner F. et al. An open source software for analysis of dynamic contrast enhanced magnetic
  resonance images: UMMPerfusion revisited. *BMC Med Imaging* 2016;16:7.
  doi:10.1186/s12880-016-0109-0

## Licence

BSD 3-Clause (see [LICENSE](LICENSE)), as the original. The SDK headers in `third_party/` are
GNU LGPL v3.
