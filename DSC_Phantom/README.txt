SYNTHETIC DSC PHANTOM FOR UMMPerfusion (IsiX)
=============================================

Artificial DSC-MRI data with known perfusion values. They let you check the
plugin's calculation against the truth. It is a test object, not patient data.

FOLDERS
  1_clean     no noise, no delay, no leakage        -> tests the maths
  2_noise     Rician noise, baseline SNR about 67   -> tests robustness
  3_delay     tissue bolus 3 s later than the AIF   -> delay sensitivity
  4_leakage   contrast leakage in the tissue blocks -> leakage correction
Each folder is one series: 3 identical slices x 60 time points
(TR 1.5 s, 90 s in total; the bolus arrives at frame 11).

  answer_key.csv                true values of every block
  expected_plugin_results.csv   what a correct implementation of the plugin's
                                maths (oSVD) should give, with leakage
                                correction on and off (noise-free series)
  make_dsc_phantom.py           the generator (needs only Python 3 + numpy)

IMAGE LAYOUT (the same in every slice)

        AIF (8x8 square, top left)

        C1     C2     C3     C4     C5      <- CBV 1, 2, 4, 6, 8 ml/100 ml
   R1   []     []     []     []     []      MTT 3 s
   R2   []     []     []     []     []      MTT 4.5 s
   R3   []     []     []     []     []      MTT 6 s

   Background "brain" = normal-appearing white matter (NAWM):
   CBV 2 ml/100 ml, MTT 5 s, CBF 24 ml/100 ml/min.
   True CBF of a block = CBV / MTT x 60. True rCBV = CBV / 2.
   The units are the plugin's own ("Volume of distribution", "Plasma flow").
   The plugin's haematocrit correction (0.45) is already built in.

HOW TO TEST
 1. Import the four folders into IsiX (drag them into the database window).
    Each series should open as a 4D viewer with 60 time points.
 2. Open "DSC phantom 1 - clean". Start UMMPerfusion > Fast Deconvolution.
    - Baseline: frames 1-9 (the bolus starts at frame 11)
    - AIF: a small ROI inside the bright top-left square (it darkens strongly
      during the bolus)
    - Tissue: the whole slice (or a rectangle covering all blocks)
 3. In the CBV / CBF maps, draw ROIs inside the blocks (stay 1-2 pixels away
    from the edges). Use "Measure" or "Export CSV" in DSC Tools.
 4. Compare with expected_plugin_results.csv (same settings) and with
    answer_key.csv (the truth).
 5. Repeat for series 2, 3 and 4.

WHAT A CORRECT RESULT LOOKS LIKE
 - CBV (Volume of distribution), leakage correction OFF:
   within about 3 % of the truth in series 1 and 3.
 - CBV, leakage correction ON, series 1: up to about +8 % (MTT 3 s blocks) and
   -12 % (MTT 6 s blocks). This is a known limitation of the Boxerman-Weisskoff
   model. It reads a transit time that differs from the brain average as
   "leakage". It is NOT a bug.
 - CBF (Plasma flow) is underestimated by every SVD method: with oSVD it comes
   out at about 70-80 % of the truth, with standard SVD 50-65 %. That is why
   absolute CBF is not used clinically and relative values are preferred.
 - Series 3 (delay): oSVD values should barely change compared with series 1.
 - Series 4 (leakage): without correction the CBV of rows 1-2 is far too low,
   and the CBV of row 3 is too high. With correction they come back to within
   about 15 %.
 - Series 2 (noise): the block means should stay close to series 1. The
   individual pixels scatter.
 - Auto rCBV map (NAWM normalisation): the blocks should read about
   0.5 / 1 / 2 / 3 / 4 (columns 1-5). Leakage correction ON shifts them as
   described above.

If results deviate much more than this, something in the pipeline is wrong:
timing, baseline, AIF, conversion or scaling.

LIMITATIONS
The phantom tests the calculation only. It does not reproduce scanner
differences, partial volume in a real artery, AIF saturation, motion, the
non-linear blood relaxivity, or where a person places the AIF and NAWM ROIs.
Validation on real patient data against reference software is still needed.
