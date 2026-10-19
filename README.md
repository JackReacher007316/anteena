# ML-Based Antenna Design & Optimization Framework
### Integrating CST Studio Suite + MATLAB + Python ML

## Project Overview

This project implements a Machine Learning-based surrogate modeling framework for antenna design,
optimization, and parameter prediction. It replaces time-consuming full-wave EM simulations (CST)
with fast ML models, enabling rapid antenna design across multiple antenna types.

## Project Structure

```
anteena/
├── README.md
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
│   └── app.js
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

## Expected Performance

| Model     | R2 Score | RMSE (dB) | Training Time |
|-----------|----------|-----------|---------------|
| ANN       | ~0.97    | ~0.3      | ~30s          |
| SVR       | ~0.95    | ~0.5      | ~10s          |
| GPR       | ~0.96    | ~0.4      | ~45s          |
| RF        | ~0.94    | ~0.6      | ~15s          |
| Deep CNN  | ~0.98    | ~0.2      | ~2 min        |
