#!/usr/bin/env python3
"""
Synthetic DSC-MRI phantom for testing UMMPerfusion (IsiX port).

Writes four DICOM series (MR, Explicit VR Little Endian), each 3 slices x 60
time points, plus an answer key (CSV) with the true values of every block.

  1 clean      - noise-free, no delay, no leakage   (tests the maths)
  2 noise      - Gaussian noise, baseline SNR ~ 60  (tests robustness)
  3 delay      - tissue bolus arrives 3 s after the AIF (sSVD vs oSVD)
  4 leakage    - Boxerman-Weisskoff type leakage in the tissue blocks

Layout of every slice (128 x 128, 1.8 mm pixels):
  - a round "brain" of normal-appearing white matter (NAWM)
  - an 8 x 8 "artery" block (the AIF) at the top left
  - a 5 x 3 grid of 10 x 10 tissue blocks:
        columns: true CBV (plugin "Volume of distribution") 1, 2, 4, 6, 8 ml/100 ml
        rows:    true MTT 3, 4.5, 6 s
    CBF (plugin "Plasma flow") = CBV / MTT * 60 ml/100 ml/min.

Signal model: S(t) = S0 * exp(-dR2*TE(t)), with the same linear relation between
concentration and dR2* in artery and tissue (the assumption the plugin makes).
Tissue: C_t = (CBF/6000) * [C_a / (1 - Hct)] (*) exp(-t/MTT), Hct = 0.45, which is
exactly the convention of UMMPerfusion (the plugin divides the AIF by 1 - Hct),
so the answer key is in the plugin's own units.

Only numpy is needed. Usage:  python3 make_dsc_phantom.py [output_folder]
"""
import csv
import os
import struct
import sys
import time as _time

import numpy as np

# ---------------------------------------------------------------- parameters
N = 128            # matrix
PIX = 1.8          # mm
NT = 60            # time points
TR = 1.5           # s
TE = 30.0          # ms (header only)
NSL = 3            # slices per series
S0 = 1000.0        # baseline signal, tissue and artery
HCT = 0.45
AIF_PEAK = 2.0     # peak dR2*.TE of the AIF (signal falls to 13.5 % of baseline)
T0 = 15.0          # bolus arrival in the artery, s (10 baseline frames)
NAWM = dict(cbv=2.0, mtt=5.0)               # -> CBF 24 ml/100 ml/min
CBVS = [1.0, 2.0, 4.0, 6.0, 8.0]            # ml/100 ml (columns)
MTTS = [3.0, 4.5, 6.0]                      # s (rows)
NOISE_SIGMA = 15.0                          # series 2: baseline SNR ~ 67
DELAY = 3.0                                 # series 3
# series 4: leakage constant K2 per row (1/s); >0 = T1 leakage (CBV under-
# estimated without correction), <0 = T2* leakage (over-estimated)
LEAK_K2 = [0.004, 0.008, -0.004]

FINE = 0.01        # s, fine grid for the convolution
t_fine = np.arange(0, NT * TR + 20, FINE)
t_acq = np.arange(NT) * TR


def gamma_variate(t, t0, alpha, beta):
    x = np.clip(t - t0, 0, None)
    return x ** alpha * np.exp(-x / beta)


def aif_curve(t):
    """Arterial dR2*.TE: first pass + recirculation + small steady state."""
    first = gamma_variate(t, T0, 3.0, 1.5)
    first /= first.max()
    recirc = 0.12 * gamma_variate(t, T0 + 9.0, 3.0, 3.0) / gamma_variate(
        np.array([T0 + 9.0 + 9.0]), T0 + 9.0, 3.0, 3.0)[0]
    steady = 0.04 / (1 + np.exp(-(t - (T0 + 14.0)) / 3.0))
    return AIF_PEAK * (first + recirc + steady)


CA_FINE = aif_curve(t_fine)


def tissue_curve(cbv, mtt, delay=0.0):
    """Tissue dR2*.TE on the fine grid (plugin convention, see docstring)."""
    cbf = cbv / mtt * 60.0                      # ml/100 ml/min
    f = cbf / 6000.0                            # 1/s, as the plugin's internal flow
    residue = np.exp(-t_fine / mtt)
    cp = CA_FINE / (1.0 - HCT)
    ct = f * np.convolve(cp, residue)[: len(t_fine)] * FINE
    if delay:
        shift = int(round(delay / FINE))
        ct = np.concatenate([np.zeros(shift), ct[:-shift]])
    return ct


def sample(curve_fine, delay=0.0):
    idx = np.round(t_acq / FINE).astype(int)
    return curve_fine[idx]


def cumint(y, dt):
    return np.concatenate([[0.0], np.cumsum(0.5 * (y[1:] + y[:-1]) * dt)])


# ---------------------------------------------------------------- geometry
def layout():
    """Return list of (name, mask, params) and the brain mask."""
    yy, xx = np.mgrid[0:N, 0:N]
    brain = (xx - N / 2 + 0.5) ** 2 + (yy - N / 2 + 0.5) ** 2 <= 58 ** 2
    blocks = []
    aif = np.zeros((N, N), bool)
    aif[30:38, 30:38] = True
    blocks.append(("AIF", aif, None))
    x0, y0, step, size = 27, 46, 15, 10
    for r, mtt in enumerate(MTTS):
        for c, cbv in enumerate(CBVS):
            m = np.zeros((N, N), bool)
            ys, xs = y0 + r * step + 12, x0 + c * step
            m[ys:ys + size, xs:xs + size] = True
            blocks.append((f"R{r+1}C{c+1}", m, dict(cbv=cbv, mtt=mtt, row=r)))
    return brain, blocks


# ---------------------------------------------------------------- DICOM writer
def _el(group, elem, vr, value):
    if isinstance(value, str):
        b = value.encode("ascii")
        if len(b) % 2:
            b += b"\0" if vr == "UI" else b" "
    else:
        b = value
        if len(b) % 2:
            b += b"\0"
    tag = struct.pack("<HH", group, elem)
    if vr in ("OB", "OW", "SQ", "UN", "UT"):
        return tag + vr.encode() + b"\0\0" + struct.pack("<I", len(b)) + b
    return tag + vr.encode() + struct.pack("<H", len(b)) + b


def _us(v):
    return struct.pack("<H", v)


def uid(*parts):
    return "2.25." + str(int.from_bytes(os.urandom(15), "big")) if not parts else \
        "1.2.826.0.1.3680043.10.1347." + ".".join(str(p) for p in parts)


def write_dicom(path, img, meta):
    sop_class = "1.2.840.10008.5.1.4.1.1.4"
    els = [
        (0x0008, 0x0008, "CS", "ORIGINAL\\PRIMARY\\M\\ND"),
        (0x0008, 0x0016, "UI", sop_class),
        (0x0008, 0x0018, "UI", meta["sop"]),
        (0x0008, 0x0020, "DA", meta["date"]),
        (0x0008, 0x0021, "DA", meta["date"]),
        (0x0008, 0x0022, "DA", meta["date"]),
        (0x0008, 0x0023, "DA", meta["date"]),
        (0x0008, 0x0030, "TM", "120000"),
        (0x0008, 0x0031, "TM", "120000"),
        (0x0008, 0x0032, "TM", meta["acq_time"]),
        (0x0008, 0x0033, "TM", meta["acq_time"]),
        (0x0008, 0x0060, "CS", "MR"),
        (0x0008, 0x0070, "LO", "SIEMENS"),
        (0x0008, 0x1030, "LO", "Synthetic DSC phantom"),
        (0x0008, 0x103E, "LO", meta["series_desc"]),
        (0x0010, 0x0010, "PN", "PHANTOM^DSC"),
        (0x0010, 0x0020, "LO", "DSCPHANTOM01"),
        (0x0010, 0x0030, "DA", "20000101"),
        (0x0010, 0x0040, "CS", "O"),
        (0x0018, 0x0020, "CS", "EP"),
        (0x0018, 0x0050, "DS", "5"),
        (0x0018, 0x0080, "DS", f"{TR*1000:.0f}"),
        (0x0018, 0x0081, "DS", f"{TE:.0f}"),
        (0x0018, 0x0088, "DS", "6"),
        (0x0018, 0x1060, "DS", f"{meta['trigger_ms']:.1f}"),
        (0x0018, 0x1314, "DS", "90"),
        (0x0020, 0x000D, "UI", meta["study_uid"]),
        (0x0020, 0x000E, "UI", meta["series_uid"]),
        (0x0020, 0x0010, "SH", "1"),
        (0x0020, 0x0011, "IS", str(meta["series_no"])),
        (0x0020, 0x0012, "IS", str(meta["tp"] + 1)),
        (0x0020, 0x0013, "IS", str(meta["instance"])),
        (0x0020, 0x0032, "DS", meta["position"]),
        (0x0020, 0x0037, "DS", "1\\0\\0\\0\\1\\0"),
        (0x0020, 0x0052, "UI", meta["for_uid"]),
        (0x0020, 0x0100, "IS", str(meta["tp"] + 1)),
        (0x0020, 0x0105, "IS", str(NT)),
        (0x0020, 0x1041, "DS", meta["slice_loc"]),
        (0x0028, 0x0002, "US", _us(1)),
        (0x0028, 0x0004, "CS", "MONOCHROME2"),
        (0x0028, 0x0010, "US", _us(N)),
        (0x0028, 0x0011, "US", _us(N)),
        (0x0028, 0x0030, "DS", f"{PIX}\\{PIX}"),
        (0x0028, 0x0100, "US", _us(16)),
        (0x0028, 0x0101, "US", _us(12)),
        (0x0028, 0x0102, "US", _us(11)),
        (0x0028, 0x0103, "US", _us(0)),
        (0x0028, 0x1050, "DS", "600"),
        (0x0028, 0x1051, "DS", "1200"),
        (0x7FE0, 0x0010, "OW", img.astype("<u2").tobytes()),
    ]
    body = b"".join(_el(*e) for e in els)
    ts = "1.2.840.10008.1.2.1"
    meta_els = (_el(0x0002, 0x0001, "OB", b"\0\1") + _el(0x0002, 0x0002, "UI", sop_class)
                + _el(0x0002, 0x0003, "UI", meta["sop"]) + _el(0x0002, 0x0010, "UI", ts)
                + _el(0x0002, 0x0012, "UI", "1.2.826.0.1.3680043.10.1347.1")
                + _el(0x0002, 0x0013, "SH", "UMMP_PHANTOM"))
    header = _el(0x0002, 0x0000, "UL", struct.pack("<I", len(meta_els))) + meta_els
    with open(path, "wb") as fh:
        fh.write(b"\0" * 128 + b"DICM" + header + body)


# ---------------------------------------------------------------- build
def build(out):
    rng = np.random.default_rng(20261116)
    brain, blocks = layout()
    os.makedirs(out, exist_ok=True)
    stamp = _time.strftime("%Y%m%d")
    base = int(_time.time())
    study_uid = uid(base, 1)
    for_uid = uid(base, 2)

    nawm_fine = tissue_curve(NAWM["cbv"], NAWM["mtt"])
    aif_s = sample(CA_FINE)

    series = [
        ("clean", "DSC phantom 1 - clean", dict()),
        ("noise", "DSC phantom 2 - noise SNR 67", dict(noise=NOISE_SIGMA)),
        ("delay", f"DSC phantom 3 - tissue delay {DELAY:g} s", dict(delay=DELAY)),
        ("leakage", "DSC phantom 4 - leakage", dict(leak=True)),
    ]
    key_rows = []
    for s_idx, (tag, desc, opt) in enumerate(series, start=1):
        delay = opt.get("delay", 0.0)
        # dR2*.TE maps over time: (NT, N, N)
        R = np.zeros((NT, N, N))
        nawm = sample(tissue_curve(NAWM["cbv"], NAWM["mtt"], delay))
        R[:, brain] = nawm[:, None]
        nawm_int = cumint(sample(tissue_curve(NAWM["cbv"], NAWM["mtt"], delay)), TR)
        for name, m, p in blocks:
            if p is None:
                curve = aif_s
                leak = 0.0
            else:
                curve = sample(tissue_curve(p["cbv"], p["mtt"], delay))
                leak = LEAK_K2[p["row"]] if opt.get("leak") else 0.0
                if leak:
                    curve = curve - leak * nawm_int
            R[:, m] = curve[:, None]
            if s_idx == 1 or (p is not None):
                pass
            if p is not None:
                cbf = p["cbv"] / p["mtt"] * 60.0
                key_rows.append(dict(
                    series=s_idx, series_name=desc, block=name,
                    cbv_ml_100ml=p["cbv"], cbf_ml_100ml_min=round(cbf, 2),
                    mtt_s=p["mtt"], rcbv_vs_nawm=round(p["cbv"] / NAWM["cbv"], 3),
                    rcbf_vs_nawm=round(cbf / (NAWM["cbv"] / NAWM["mtt"] * 60.0), 3),
                    delay_s=delay, leakage_k2_per_s=leak,
                    noise_sigma=opt.get("noise", 0.0)))
        sig = S0 * np.exp(-R)
        sig[:, ~brain] = 0.0
        aif_mask = blocks[0][1]
        sig[:, aif_mask] = S0 * np.exp(-aif_s)[:, None]
        sigma = opt.get("noise", 0.0)

        series_uid = uid(base, 10 + s_idx)
        folder = os.path.join(out, f"{s_idx}_{tag}")
        os.makedirs(folder, exist_ok=True)
        inst = 0
        for tp in range(NT):
            acq = 12 * 3600 + 5 * 60 + tp * TR
            hh, rem = divmod(acq, 3600)
            mm, ss = divmod(rem, 60)
            acq_str = f"{int(hh):02d}{int(mm):02d}{ss:09.6f}"
            for sl in range(NSL):
                img = sig[tp].copy()
                if sigma:
                    # magnitude of complex Gaussian noise (Rician), as on a scanner
                    img = np.hypot(img + rng.normal(0, sigma, img.shape),
                                   rng.normal(0, sigma, img.shape))
                img = np.clip(np.round(img), 0, 4095)
                inst += 1
                z = -6.0 * sl + 0.0  # avoid "-0.0"
                write_dicom(os.path.join(folder, f"IM_{inst:04d}.dcm"), img, dict(
                    sop=uid(base, 10 + s_idx, inst), date=stamp, acq_time=acq_str,
                    series_desc=desc, trigger_ms=tp * TR * 1000, study_uid=study_uid,
                    series_uid=series_uid, series_no=s_idx, tp=tp, instance=inst,
                    position=f"{-N*PIX/2:.1f}\\{-N*PIX/2:.1f}\\{z:.1f}",
                    for_uid=for_uid, slice_loc=f"{z:.1f}"))
        print(f"series {s_idx}: {inst} images -> {folder}")

    key_rows.insert(0, dict(series="all", series_name="background", block="NAWM",
                            cbv_ml_100ml=NAWM["cbv"],
                            cbf_ml_100ml_min=NAWM["cbv"] / NAWM["mtt"] * 60.0,
                            mtt_s=NAWM["mtt"], rcbv_vs_nawm=1.0, rcbf_vs_nawm=1.0,
                            delay_s="", leakage_k2_per_s=0, noise_sigma=""))
    with open(os.path.join(out, "answer_key.csv"), "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(key_rows[1].keys()))
        w.writeheader()
        w.writerows(key_rows)
    return key_rows


if __name__ == "__main__":
    build(sys.argv[1] if len(sys.argv) > 1 else "DSC_Phantom")
