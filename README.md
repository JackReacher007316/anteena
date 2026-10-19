# ML-Based Antenna Design & Optimization Framework
### Integrating CST Studio Suite + MATLAB + Python ML

**Live website:** https://jackreacher007316.github.io/anteena/ - the dashboard, hosted on GitHub
Pages and online 24/7 (it does not depend on your PC).

**Connect it to MATLAB on your Windows PC - one command, once:** press `Win`+`R`, paste this line
and press Enter. It installs everything (Python too, if missing), checks MATLAB, and opens the
website; click **Allow** if the browser asks. Details: [Live link](#5-live-link-web-dashboard---matlab-verification).
```
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex ((New-Object Net.WebClient).DownloadString('https://jackreacher007316.github.io/anteena/install.ps1'))"
```

## Project Overview

This project implements a Machine Learning-based surrogate modeling framework for antenna design,
optimization, and parameter prediction. It replaces time-consuming full-wave EM simulations (CST)
with fast ML models, enabling rapid antenna design across multiple antenna types.

## Project Structure

```
anteena/
├── README.md
├── index.html                   # Public website entry (GitHub Pages) -> dashboard/
├── install.ps1                  # One-command Windows setup (Win+R one-liner above)
├── .nojekyll                    # GitHub Pages: serve the files as they are
├── data/
│   ├── raw/                     # Raw CST parameter sweep exports
│   ├── processed/               # Cleaned, normalized datasets
│   └── samples/                 # Pre-built sample datasets
├── cst_scripts/                 # CST VBA macros for automation
│   ├── patch_antenna_sweep.bas
│   ├── mimo_antenna_sweep.bas
│   ├── uwb_antenna_sweep.bas
│   └── export_results.bas
├── matlab/                      # MATLAB ML implementation
│   ├── data_preprocessing.m
│   ├── train_ann.m
│   ├── train_svm.m
│   ├── train_gpr.m
│   ├── train_random_forest.m
│   ├── surrogate_optimizer.m
│   ├── inverse_design.m
│   └── plot_results.m
├── python/                      # Python ML pipeline
│   ├── requirements.txt
│   ├── data_loader.py
│   ├── feature_engineering.py
│   ├── models/
│   │   ├── ann_model.py
│   │   ├── svm_model.py
│   │   ├── rf_model.py
│   │   ├── deep_learning.py
│   │   └── gpr_model.py
│   ├── train_pipeline.py
│   ├── optimizer.py
│   └── evaluate.py
├── dashboard/
│   ├── index.html
│   ├── style.css
│   ├── app.js
│   ├── bridge_server.py         # Serves the dashboard + live link to MATLAB
│   ├── live_link_setup.py       # install / start / stop / status / uninstall of the link
│   └── live_link_bootstrap.py   # download + install in one go (used by install.ps1)
├── matlab/  (live link)
│   ├── live_verify.m            # Live window: dashboard inputs -> MATLAB verification
│   ├── antenna_model.m          # MATLAB implementation of all 30 dashboard EM engines
│   ├── antenna_s11_curve.m      # S11 trace (same model as the dashboard chart)
│   ├── verify_web_input.m       # Dashboard vs MATLAB comparison (PASS / FAIL report)
│   ├── live_link_check.m        # One-shot health check (run by the installer)
│   └── test_antenna_model.m     # Self-test: MATLAB == dashboard for all 30 antennas
├── tests/
│   ├── test_bridge_server.py    # python -m unittest discover -s tests
│   ├── test_live_link_setup.py
│   ├── test_live_link_bootstrap.py
│   ├── gen_engine_reference.js  # node tests/gen_engine_reference.js
│   └── fixtures/engine_reference.json
├── install_live_link.bat        # ONE-TIME: keeps MATLAB connected to the website
├── uninstall_live_link.bat      # undo install_live_link.bat
├── start_live_verification.bat  # 1 double-click: bridge + website + MATLAB live_verify
└── docs/
    └── project_report.md
```

## Supported Antenna Types

| Antenna           | Parameters Optimized                      |
|-------------------|-------------------------------------------|
| Patch/Microstrip  | Length, Width, Substrate er, height       |
| MIMO              | Element spacing, isolation, ECC           |
| UWB / Wideband    | Slot dimensions, ground plane cutout      |
| 5G / mmWave       | Array spacing, element pattern            |
| Fractal           | Iteration level, scale factor             |

## ML Models Implemented

| Model             | Library                        | Use Case                    |
|-------------------|--------------------------------|-----------------------------|
| ANN (MLP)         | MATLAB nntool / PyTorch        | General surrogate modeling  |
| SVR               | MATLAB fitrsvm / scikit-learn  | Small dataset regression    |
| Gaussian Process  | MATLAB fitrgp / scikit-learn   | Uncertainty quantification  |
| Random Forest     | MATLAB TreeBagger / scikit-learn | Feature importance         |
| Deep Learning CNN | PyTorch / TensorFlow           | Complex pattern learning    |

## Workflow

```
CST Parameter Sweep -> Export S-params / Gain Data
        |
   Data Preprocessing (MATLAB/Python)
        |
   ML Model Training (ANN / SVM / GPR / RF)
        |
   Surrogate Model Validation (R2, RMSE, MAE)
        |
   Optimization (GA + ML Surrogate / Bayesian Opt)
        |
   Inverse Design -> Predict Geometry from Specs
        |
   Verify Best Design in CST (Full-wave)
```

## Quick Start

### 1. Generate Data from CST
Run the VBA macro: cst_scripts/patch_antenna_sweep.bas

### 2. Train ML Models in MATLAB
```matlab
cd matlab/
data = data_preprocessing('../data/processed/patch_data.csv');
model = train_ann(data);
```

### 3. Train ML Models in Python
```bash
cd python/
pip install -r requirements.txt
python train_pipeline.py --antenna patch --model all
```

### 4. Run Optimization
```matlab
surrogate_optimizer('patch', model, -15, 7)
```

### 5. Live link: Web dashboard -> MATLAB verification
Whatever you set in the dashboard (antenna type, ML model, every slider) shows up in
MATLAB immediately. MATLAB re-computes the design on its own and checks every number
the dashboard displays, then sends its verdict back to the dashboard.

**Windows - one command, then it stays connected.** Press `Win`+`R`, paste the line from the
top of this README (also on the website: MATLAB panel, F4, **COPY INSTALL COMMAND**) and press
Enter. `install.ps1` finds Python 3 (or installs it with winget), downloads the PC connector to
`%USERPROFILE%\anteena-live` (your own checkout is not touched), stops an old bridge on port 8000
and runs the setup below. Running it again updates everything.

**Same setup from a checkout of this repository:** double-click `install_live_link.bat`
(needs Python 3). It:
1. starts the bridge now and at every Windows log-in, in the background - no window,
   no admin rights (registry `HKCU\...\Run`, value `AnteenaMatlabBridge`);
2. runs a one-time check inside MATLAB (`live_link_check`: MATLAB reproduces all 30
   engines, MATLAB reaches the bridge) and adds a small marked block to MATLAB's
   `startup.m`, so every MATLAB session opens the live link by itself;
3. opens the website, which finds the bridge and starts MATLAB with the live window.

After that you only open the website. When it finds the bridge and MATLAB is not linked,
it starts MATLAB once (switch this off with the checkbox in the MATLAB panel, F4).
Closing the MATLAB window only hides it: the link keeps running, and **CONNECT MATLAB**
(or `live_verify` in MATLAB) brings the window back. `live_verify stop` ends the link.
Undo everything: `uninstall_live_link.bat`. Check what runs:
`python dashboard/live_link_setup.py status`.

**Without the setup:** `start_live_verification.bat` starts the bridge (if it is not
running yet), opens the website and asks the bridge to start MATLAB with `live_verify`.

**Manual start:**
```bash
python dashboard/bridge_server.py        # then open http://localhost:8000
```
```matlab
cd matlab
live_verify                              % MATLAB window follows the dashboard live
```
You can also click **CONNECT MATLAB (LIVE)** in the dashboard, which asks the bridge to
start MATLAB for you. If MATLAB is not in a standard location, set the `MATLAB_EXE`
environment variable first.

**From the public website** (https://jackreacher007316.github.io/anteena/): MATLAB still
runs on your PC, so the hosted page talks to the bridge on your own machine.
1. The bridge must run on your PC: `install_live_link.bat` (once), or
   `start_live_verification.bat`, or `python dashboard/bridge_server.py`.
   No copy of the repository on that PC? The MATLAB panel (F4) has a **download ZIP**
   link for the PC connector.
2. Open the website and click **CONNECT MATLAB (LIVE)**. If the browser asks to allow
   access to devices on your local network, click **Allow**. Blocked it by mistake? Click
   the icon left of the address bar > Site settings > allow local network access.
3. The page finds the bridge at `http://127.0.0.1:8000`, asks it to start MATLAB, and
   then works exactly like the local dashboard. It remembers the bridge, so the next
   visit connects without a click. An old bridge (from before the live link) is flagged
   as `OLD BRIDGE ON THIS PC - UPDATE IT`.

Other port: open the site with `?bridge=8080` (or `?bridge=http://127.0.0.1:8080`).
Forget the remembered bridge: `?bridge=off`. Only your own PC or local network is
accepted as a bridge address. The bridge answers browser requests only from the public
website and from `http://localhost:<port>` pages. To allow another site, run
`--allow-origin https://example.org` or set `BRIDGE_ALLOW_ORIGINS`.

**What you get in MATLAB**
- **A window** called "Web Dashboard -> MATLAB Live Verification". It shows:
  - the received inputs;
  - MATLAB's S11 trace next to the dashboard's ML prediction;
  - RF figures (VSWR, |Gamma|, return/mismatch loss, the -10 dB band);
  - a check table: dashboard value | MATLAB value | error | tolerance | PASS/FAIL.
- **Workspace variables** `web_input` (the raw dashboard input) and `web_verification`
  (MATLAB's report). Both refresh on every change.
- **The verdict back in the dashboard.** The status strip shows the real link state, for
  example `MATLAB (R2026b): LIVE ✓ #12 PASS 10/10`. The MATLAB modal (F4) lists every check.

**How the checks work**
| Check | Compares | Tolerance |
|-------|----------|-----------|
| Engine | Every number from the dashboard EM engine vs `antenna_model.m` | max(1e-9, 1e-6 x value), i.e. exact |
| ML surrogate | The ML prediction displayed (S11, Gain, Fr, BW) vs MATLAB | 1 dB, 0.5 dB, 1 % (>= 10 MHz), 5 % (>= 20 MHz) |

**Useful commands**
- `live_verify('http://127.0.0.1:8080')`: use a bridge on another port.
- `live_verify stop`: stop the link and close the window.
- `test_antenna_model`: proves MATLAB reproduces all 30 dashboard engines.

If the bridge is not running, `live_verify` watches `data/user_input.json` instead.

Bridge API (used by the dashboard and MATLAB; POST bodies must be `application/json`):
- `POST /api/matlab/input`: the dashboard pushes an input.
- `GET /api/matlab/input?since=<seq>&client=matlab`: MATLAB polls for new input.
- `POST /api/matlab/result`: MATLAB posts its verification.
- `GET /api/status`: the real link state.
- `POST /api/matlab/launch`: starts MATLAB with `live_verify` - once: while MATLAB is
  starting it answers `starting`, and when MATLAB is already linked it answers
  `already_connected` and asks `live_verify` to bring its window back.
- One bridge per port: a second copy notices the running one and exits. Without a console
  (pythonw) the bridge logs to `data/bridge.log`.

Tests: `python -m unittest discover -s tests`. After changing an engine formula, re-run
`node tests/gen_engine_reference.js` and `test_antenna_model` in MATLAB.

## Expected Performance

| Model     | R2 Score | RMSE (dB) | Training Time |
|-----------|----------|-----------|---------------|
| ANN       | ~0.97    | ~0.3      | ~30s          |
| SVR       | ~0.95    | ~0.5      | ~10s          |
| GPR       | ~0.96    | ~0.4      | ~45s          |
| RF        | ~0.94    | ~0.6      | ~15s          |
| Deep CNN  | ~0.98    | ~0.2      | ~2 min        |
