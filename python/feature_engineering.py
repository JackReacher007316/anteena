"""
feature_engineering.py
ML Antenna Framework — Feature Engineering & Preprocessing Pipeline
"""

import numpy as np
import pandas as pd
from sklearn.preprocessing import MinMaxScaler, StandardScaler, RobustScaler
from sklearn.model_selection import train_test_split
from sklearn.decomposition import PCA
from sklearn.feature_selection import SelectKBest, f_regression, mutual_info_regression
from typing import Tuple, Dict, Optional
import warnings
warnings.filterwarnings('ignore')


class AntennaFeatureEngineer:
    """
    Feature engineering pipeline for antenna ML models.
    Handles normalization, feature creation, selection, and splitting.
    """

    def __init__(self, antenna_type: str, scaler_type: str = 'minmax',
                 test_size: float = 0.2, random_state: int = 42):
        self.antenna_type   = antenna_type.lower()
        self.scaler_type    = scaler_type
        self.test_size      = test_size
        self.random_state   = random_state
        self.scaler_X       = self._get_scaler(scaler_type)
        self.scaler_y       = self._get_scaler(scaler_type)
        self.is_fitted      = False

    def _get_scaler(self, scaler_type: str):
        return {
            'minmax':   MinMaxScaler(feature_range=(0, 1)),
            'standard': StandardScaler(),
            'robust':   RobustScaler(),
        }.get(scaler_type, MinMaxScaler())

    # ─────────────────────────────────────────────────────
    def add_physics_features(self, X: np.ndarray, feature_names: list) -> Tuple[np.ndarray, list]:
        """
        Add physics-derived features to the feature matrix.
        These improve ML model accuracy by embedding domain knowledge.
        """
        X_new = X.copy()
        new_names = list(feature_names)

        if self.antenna_type == 'patch':
            # Feature indices
            try:
                L_idx  = feature_names.index('Length_mm')
                W_idx  = feature_names.index('Width_mm')
                h_idx  = feature_names.index('Height_mm')
                er_idx = feature_names.index('Permittivity')

                L  = X[:, L_idx]
                W  = X[:, W_idx]
                h  = X[:, h_idx]
                er = X[:, er_idx]

                # Physics features
                aspect_ratio = L / (W + 1e-8)                # L/W ratio
                er_eff = (er + 1)/2 + (er - 1)/2 * (1 + 12*h/(W+1e-8))**(-0.5)
                fr_approx = 3e8 / (2 * L*1e-3 * np.sqrt(er_eff + 1e-8)) / 1e9
                vol_substrate = L * W * h  # Volume proxy

                X_new = np.column_stack([X_new, aspect_ratio, er_eff, fr_approx, vol_substrate])
                new_names += ['AspectRatio', 'EffPermittivity', 'FreqApprox_GHz', 'SubstrateVolume']
            except ValueError:
                pass  # Feature not found, skip

        elif self.antenna_type == 'mimo':
            try:
                sp_idx = feature_names.index('Spacing_lambda')
                spacing = X[:, sp_idx]
                # Mutual coupling approximation (exponential decay)
                mutual_coupling = np.exp(-3 * spacing)
                X_new = np.column_stack([X_new, mutual_coupling])
                new_names += ['MutualCoupling_approx']
            except ValueError:
                pass

        elif self.antenna_type == 'uwb':
            try:
                sw_idx = feature_names.index('SlotWidth_mm')
                sl_idx = feature_names.index('SlotLength_mm')
                slot_area = X[:, sw_idx] * X[:, sl_idx]
                aspect = X[:, sw_idx] / (X[:, sl_idx] + 1e-8)
                X_new = np.column_stack([X_new, slot_area, aspect])
                new_names += ['SlotArea_mm2', 'SlotAspectRatio']
            except ValueError:
                pass

        print(f"  Added {len(new_names) - len(feature_names)} physics features")
        return X_new, new_names

    # ─────────────────────────────────────────────────────
    def select_features(self, X_train: np.ndarray, y_train: np.ndarray,
                        n_features: int = None, method: str = 'mutual_info') -> np.ndarray:
        """Select top-k features using statistical methods."""
        if n_features is None or n_features >= X_train.shape[1]:
            return np.arange(X_train.shape[1])

        if method == 'mutual_info':
            selector = SelectKBest(mutual_info_regression, k=n_features)
        else:
            selector = SelectKBest(f_regression, k=n_features)

        selector.fit(X_train, y_train)
        scores = selector.scores_
        selected = np.argsort(scores)[-n_features:][::-1]

        print(f"  Selected top-{n_features} features (indices): {selected}")
        return selected

    # ─────────────────────────────────────────────────────
    def fit_transform(self, X: np.ndarray, y: np.ndarray,
                      feature_names: Optional[list] = None,
                      add_physics: bool = True,
                      remove_outliers: bool = True) -> Tuple:
        """
        Full preprocessing pipeline:
        1. Add physics features
        2. Remove outliers
        3. Normalize
        4. Split
        """
        print(f"\n[FeatureEngineer] Preprocessing {self.antenna_type} antenna data")
        print(f"  Input shape: {X.shape}")

        # 1. Add physics features
        if add_physics and feature_names is not None:
            X, feature_names = self.add_physics_features(X, feature_names)

        # 2. Remove outliers (IQR 3x)
        if remove_outliers:
            Q1, Q3 = np.percentile(y, [25, 75])
            IQR = Q3 - Q1
            mask = (y >= Q1 - 3*IQR) & (y <= Q3 + 3*IQR)
            X = X[mask]; y = y[mask]
            print(f"  Removed {(~mask).sum()} outliers -> {len(y)} samples remaining")

        # 3. Train/Test Split
        X_train, X_test, y_train, y_test = train_test_split(
            X, y, test_size=self.test_size,
            random_state=self.random_state)

        # 4. Fit scalers on training data only (prevent leakage)
        X_train_n = self.scaler_X.fit_transform(X_train)
        X_test_n  = self.scaler_X.transform(X_test)
        y_train_n = self.scaler_y.fit_transform(y_train.reshape(-1, 1)).ravel()
        y_test_n  = self.scaler_y.transform(y_test.reshape(-1, 1)).ravel()

        self.is_fitted = True
        self.feature_names = feature_names

        print(f"  Train: {X_train_n.shape} | Test: {X_test_n.shape}")
        print(f"  Scaler: {self.scaler_type}")

        scaler = {'X': self.scaler_X, 'y': self.scaler_y,
                  'feature_names': feature_names}
        return X_train_n, X_test_n, y_train_n, y_test_n, scaler

    # ─────────────────────────────────────────────────────
    def inverse_transform_y(self, y_pred_norm: np.ndarray) -> np.ndarray:
        """Convert normalized predictions back to physical units."""
        return self.scaler_y.inverse_transform(y_pred_norm.reshape(-1, 1)).ravel()

    def transform_X(self, X_new: np.ndarray) -> np.ndarray:
        """Normalize new input for inference."""
        assert self.is_fitted, "Must call fit_transform first."
        return self.scaler_X.transform(X_new)


if __name__ == '__main__':
    import sys
    sys.path.insert(0, '.')
    from data_loader import AntennaDataLoader

    print("=== Feature Engineering Test ===")
    for ant in ['patch', 'uwb']:
        loader  = AntennaDataLoader(ant)
        df      = loader.generate_synthetic_dataset(500)
        feats   = loader.config['features']
        X = df[feats].values
        y = df[loader.config['targets'][0]].values

        eng = AntennaFeatureEngineer(ant, scaler_type='minmax')
        X_tr, X_te, y_tr, y_te, scl = eng.fit_transform(X, y, feats, add_physics=True)
        print(f"  [{ant}] Train X: {X_tr.shape}, Test X: {X_te.shape}\n")
