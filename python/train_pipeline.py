"""
train_pipeline.py
ML Antenna Framework — Master Training Pipeline
Trains ALL models for a given antenna type and compares results
"""

import argparse
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.gridspec as gridspec
import seaborn as sns
from pathlib import Path
from sklearn.neural_network import MLPRegressor
from sklearn.svm import SVR
from sklearn.ensemble import RandomForestRegressor, GradientBoostingRegressor
from sklearn.gaussian_process import GaussianProcessRegressor
from sklearn.gaussian_process.kernels import RBF, Matern, WhiteKernel
from sklearn.model_selection import cross_val_score
from sklearn.metrics import r2_score, mean_squared_error, mean_absolute_error
import joblib
import warnings
import time
import sys, os
import io

# Ensure UTF-8 / safe stream on Windows terminal
if sys.platform == 'win32':
    try:
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
        sys.stderr.reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass

sys.path.insert(0, os.path.dirname(__file__))

try:
    from xgboost import XGBRegressor
    HAS_XGB = True
except ImportError:
    HAS_XGB = False

warnings.filterwarnings('ignore')


def get_models(input_dim: int) -> dict:
    """Return all configured ML models."""
    models_dict = {
        'ANN (MLP)': MLPRegressor(
            hidden_layer_sizes=(128, 64, 32, 16),
            activation='relu',
            solver='adam',
            learning_rate_init=0.001,
            max_iter=1000,
            early_stopping=True,
            validation_fraction=0.1,
            n_iter_no_change=20,
            random_state=42,
            verbose=False
        ),
        'SVR (RBF)': SVR(
            kernel='rbf',
            C=10.0,
            epsilon=0.05,
            gamma='scale',
        ),
        'SVR (Poly)': SVR(
            kernel='poly',
            degree=3,
            C=5.0,
            epsilon=0.05,
        ),
        'Random Forest': RandomForestRegressor(
            n_estimators=200,
            max_depth=None,
            min_samples_leaf=3,
            max_features='sqrt',
            random_state=42,
            n_jobs=-1,
        ),
        'Gradient Boost': GradientBoostingRegressor(
            n_estimators=200,
            learning_rate=0.05,
            max_depth=5,
            subsample=0.8,
            random_state=42,
        ),
        'GPR (Matern52)': GaussianProcessRegressor(
            kernel=Matern(length_scale=1.0, nu=2.5) + WhiteKernel(noise_level=0.01),
            n_restarts_optimizer=5,
            normalize_y=True,
            random_state=42,
        ),
        'GPR (RBF)': GaussianProcessRegressor(
            kernel=RBF(length_scale=1.0) + WhiteKernel(noise_level=0.01),
            n_restarts_optimizer=5,
            normalize_y=True,
            random_state=42,
        ),
    }
    if HAS_XGB:
        models_dict['XGBoost'] = XGBRegressor(
            n_estimators=150,
            learning_rate=0.08,
            max_depth=4,
            random_state=42,
            n_jobs=-1
        )
    return models_dict


def evaluate_model(model, X_test, y_test, model_name: str) -> dict:
    """Compute comprehensive regression metrics."""
    y_pred = model.predict(X_test)
    r2   = r2_score(y_test, y_pred)
    rmse = np.sqrt(mean_squared_error(y_test, y_pred))
    mae  = mean_absolute_error(y_test, y_pred)
    mape = np.mean(np.abs((y_test - y_pred) / (np.abs(y_test) + 1e-8))) * 100

    print(f"  {model_name:<20} | R2={r2:.4f} | RMSE={rmse:.5f} | MAE={mae:.5f} | MAPE={mape:.2f}%")
    return {'model': model_name, 'R2': r2, 'RMSE': rmse, 'MAE': mae, 'MAPE': mape,
            'predictions': y_pred}


def run_pipeline(antenna_type: str, target: str = 'S11_dB',
                 n_samples: int = 1000, output_dir: str = './results') -> pd.DataFrame:
    """
    Master pipeline: load -> preprocess -> train all models -> evaluate -> visualize
    """

    print("\n" + "="*65)
    print(f"  ML ANTENNA SURROGATE FRAMEWORK")
    print(f"  Antenna: {antenna_type.upper()}  |  Target: {target}  |  Samples: {n_samples}")
    print("="*65)

    Path(output_dir).mkdir(parents=True, exist_ok=True)

    # ── 1. Load and preprocess data ─────────────────────────
    from data_loader import AntennaDataLoader, load_antenna_data
    data = load_antenna_data(antenna_type, target, n_samples)

    X_train = data['X_train']
    X_test  = data['X_test']
    y_train = data['y_train']
    y_test  = data['y_test']
    scaler  = data['scaler']

    print(f"\nTrain: {X_train.shape} | Test: {X_test.shape}")
    print(f"Target range (normalized): [{y_train.min():.3f}, {y_train.max():.3f}]")

    # ── 2. Train all models ──────────────────────────────────
    models = get_models(X_train.shape[1])
    results = []

    print(f"\n{'Model':<22} | {'R2':>7} | {'RMSE':>8} | {'MAE':>8} | {'MAPE%':>7} | {'Time(s)':>8}")
    print("-" * 75)

    trained_models = {}
    for name, model in models.items():
        t0 = time.time()
        model.fit(X_train, y_train)
        elapsed = time.time() - t0

        result = evaluate_model(model, X_test, y_test, name)
        result['train_time'] = elapsed

        # 5-Fold Cross-Validation
        cv_scores = cross_val_score(model, X_train, y_train, cv=5,
                                    scoring='r2', n_jobs=-1)
        result['cv_r2_mean'] = cv_scores.mean()
        result['cv_r2_std']  = cv_scores.std()
        print(f"  {'':22}  5-Fold CV R2: {cv_scores.mean():.4f} +/- {cv_scores.std():.4f}  |  Time: {elapsed:.1f}s")

        results.append(result)
        trained_models[name] = model

        # Save model
        model_path = Path(output_dir) / f"{name.replace(' ', '_').replace('(','').replace(')','')}.pkl"
        joblib.dump(model, model_path)

    # ── 3. Try Deep Learning ─────────────────────────────────
    try:
        from models.deep_learning import AntennaMLP, AntennaResNet, DeepLearningTrainer

        for dl_name, dl_model in [('DL-MLP', AntennaMLP(X_train.shape[1], [128,64,32])),
                                   ('DL-ResNet', AntennaResNet(X_train.shape[1], 64, 3))]:
            t0 = time.time()
            val_sz = int(0.1 * len(X_train))
            Xv, yv   = X_train[:val_sz], y_train[:val_sz]
            Xt2, yt2 = X_train[val_sz:], y_train[val_sz:]

            trainer = DeepLearningTrainer(dl_model)
            trainer.train(Xt2, yt2, Xv, yv, epochs=300, patience=30)
            metrics = trainer.evaluate(X_test, y_test)
            elapsed = time.time() - t0

            result = {'model': dl_name, 'R2': metrics['R2'],
                      'RMSE': metrics['RMSE'], 'MAE': metrics['MAE'],
                      'MAPE': 0.0, 'train_time': elapsed,
                      'cv_r2_mean': metrics['R2'], 'cv_r2_std': 0.0,
                      'predictions': metrics['predictions']}
            print(f"  {dl_name:<20} | R2={metrics['R2']:.4f} | RMSE={metrics['RMSE']:.5f} | Time: {elapsed:.1f}s")
            results.append(result)
            trained_models[dl_name] = trainer
    except Exception as e:
        print(f"  [Deep Learning] Skipped: {e}")

    # ── 4. Results Summary Table ─────────────────────────────
    df_results = pd.DataFrame(results).drop('predictions', axis=1)
    df_results = df_results.sort_values('R2', ascending=False)

    print("\n" + "="*65)
    print("  FINAL MODEL COMPARISON")
    print("="*65)
    print(df_results[['model', 'R2', 'RMSE', 'MAE', 'cv_r2_mean', 'train_time']].to_string(index=False))

    best = df_results.iloc[0]
    print(f"\n  [*] BEST MODEL: {best['model']} (R2={best['R2']:.4f})")

    df_results.to_csv(Path(output_dir) / 'model_comparison.csv', index=False)

    # ── 5. Visualization ─────────────────────────────────────
    plot_comparison(results, y_test, antenna_type, target, output_dir)

    return df_results


def plot_comparison(results: list, y_test: np.ndarray,
                    antenna_type: str, target: str, output_dir: str):
    """Generate comprehensive comparison plots with premium dark theme."""

    n = len(results)
    model_names = [r['model'] for r in results]
    r2_vals     = [r['R2']   for r in results]
    rmse_vals   = [r['RMSE'] for r in results]
    predictions = [r['predictions'] for r in results]

    COLORS = ['#00d4ff', '#ff6b6b', '#a8e6cf', '#ffd93d', '#c44dff',
              '#ff8c42', '#6c5ce7', '#fd79a8', '#fdcb6e']

    fig = plt.figure(figsize=(20, 14), facecolor='#0d1117')
    gs  = gridspec.GridSpec(3, 3, figure=fig, hspace=0.4, wspace=0.35)

    # ── A: R² Bar Chart ─────────────────────────────────────
    ax1 = fig.add_subplot(gs[0, :2])
    ax1.set_facecolor('#161b22')
    bars = ax1.barh(model_names, r2_vals, color=COLORS[:n], edgecolor='none', height=0.6)
    ax1.axvline(x=1.0, color='white', ls='--', lw=1, alpha=0.5)
    for bar, val in zip(bars, r2_vals):
        ax1.text(bar.get_width() + 0.003, bar.get_y() + bar.get_height()/2,
                 f'{val:.4f}', va='center', color='white', fontsize=9)
    ax1.set_xlabel('R² Score', color='white'); ax1.set_xlim(0, 1.08)
    ax1.set_title(f'{antenna_type.upper()} Antenna — R² Score Comparison', color='white', fontsize=12)
    _style_ax(ax1)

    # ── B: RMSE Bar Chart ───────────────────────────────────
    ax2 = fig.add_subplot(gs[0, 2])
    ax2.set_facecolor('#161b22')
    bars2 = ax2.bar(range(n), rmse_vals, color=COLORS[:n], edgecolor='none')
    ax2.set_xticks(range(n))
    ax2.set_xticklabels([m.split(' ')[0] for m in model_names], rotation=45, ha='right', fontsize=8, color='white')
    ax2.set_title('RMSE Comparison', color='white')
    ax2.set_ylabel('RMSE (normalized)', color='white')
    _style_ax(ax2)

    # ── C-G: Predicted vs Actual per model ──────────────────
    cols = 3
    for i, (name, pred, clr) in enumerate(zip(model_names[:6], predictions[:6], COLORS)):
        row = 1 + i // cols
        col = i % cols
        ax = fig.add_subplot(gs[row, col])
        ax.set_facecolor('#161b22')
        ax.scatter(y_test, pred, s=15, alpha=0.5, color=clr, edgecolors='none')
        lims = [min(y_test.min(), pred.min()), max(y_test.max(), pred.max())]
        ax.plot(lims, lims, 'w--', lw=1.5, alpha=0.8)
        ax.set_title(f'{name}\nR²={r2_score(y_test, pred):.3f}', color='white', fontsize=9)
        ax.set_xlabel('Actual', color='white', fontsize=8)
        ax.set_ylabel('Predicted', color='white', fontsize=8)
        _style_ax(ax)

    fig.suptitle(f'ML Antenna Surrogate Framework\n'
                 f'{antenna_type.upper()} Antenna | Target: {target}',
                 color='white', fontsize=16, fontweight='bold')

    save_path = Path(output_dir) / f'{antenna_type}_{target}_comparison.png'
    plt.savefig(save_path, dpi=150, bbox_inches='tight', facecolor='#0d1117')
    print(f"\n  Plot saved: {save_path}")
    plt.close()


def _style_ax(ax):
    ax.tick_params(colors='white')
    ax.spines['bottom'].set_color('#30363d')
    ax.spines['left'].set_color('#30363d')
    ax.spines['top'].set_visible(False)
    ax.spines['right'].set_visible(False)
    ax.xaxis.label.set_color('white')
    ax.yaxis.label.set_color('white')
    ax.grid(color='#30363d', alpha=0.5)


# ─────────────────────────────────────────────────────────────
# CLI Entry Point
# ─────────────────────────────────────────────────────────────

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='ML Antenna Surrogate Training Pipeline')
    parser.add_argument('--antenna',  type=str, default='patch',
                        choices=['patch', 'mimo', 'uwb', '5g', 'fractal', 'horn', 'helical', 'dipole', 'yagi', 'dra', 'bowtie', 'all'],
                        help='Antenna type to train')
    parser.add_argument('--target',   type=str, default='S11_dB',
                        help='Output parameter to predict')
    parser.add_argument('--samples',  type=int, default=1000,
                        help='Number of samples to generate/use')
    parser.add_argument('--output',   type=str, default='./results',
                        help='Output directory for models and plots')
    args = parser.parse_args()

    if args.antenna == 'all':
        ant_targets = {
            'patch':   'S11_dB',
            'mimo':    'Isolation_dB',
            'uwb':     'S11min_dB',
            '5g':      'Gain_dBi',
            'fractal': 'S11_dB',
            'horn':    'Gain_dBi',
            'helical': 'Gain_dBi',
            'dipole':  'S11_dB',
            'yagi':    'Gain_dBi',
            'dra':     'S11_dB',
            'bowtie':  'S11_min_dB',
        }
        all_results = {}
        for ant, tgt in ant_targets.items():
            results_df = run_pipeline(ant, tgt, args.samples,
                                      f'{args.output}/{ant}')
            all_results[ant] = results_df
        print("\n\n=== ALL ANTENNA TYPES COMPLETE ===")
        for ant, df in all_results.items():
            best = df.iloc[0]
            print(f"  {ant:10s} -> Best: {best['model']:20s} R2={best['R2']:.4f}")
    else:
        run_pipeline(args.antenna, args.target, args.samples, args.output)
