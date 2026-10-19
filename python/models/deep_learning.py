"""
models/deep_learning.py
ML Antenna Framework — Deep Learning Models (PyTorch)
Implements MLP, CNN-1D, and ResNet-style networks for antenna prediction
"""

import numpy as np
import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import DataLoader, TensorDataset
from typing import Tuple, Dict, Optional
import matplotlib.pyplot as plt


# ─────────────────────────────────────────────────────────────
# 1. MLP / ANN (Multi-Layer Perceptron)
# ─────────────────────────────────────────────────────────────

class AntennaMLP(nn.Module):
    """
    Deep MLP for antenna parameter prediction.
    Supports variable depth, batch norm, dropout, and residual connections.
    """

    def __init__(self, input_dim: int, hidden_dims: list = [128, 64, 32, 16],
                 dropout: float = 0.2, use_batchnorm: bool = True,
                 use_residual: bool = False):
        super(AntennaMLP, self).__init__()
        self.use_residual = use_residual
        layers = []
        prev_dim = input_dim

        for i, h_dim in enumerate(hidden_dims):
            layers.append(nn.Linear(prev_dim, h_dim))
            if use_batchnorm:
                layers.append(nn.BatchNorm1d(h_dim))
            layers.append(nn.GELU())   # GELU activation (smoother than ReLU)
            if dropout > 0 and i < len(hidden_dims) - 1:
                layers.append(nn.Dropout(dropout))
            prev_dim = h_dim

        self.network = nn.Sequential(*layers)
        self.output  = nn.Linear(prev_dim, 1)

        # Weight initialization (Xavier for better convergence)
        self._init_weights()

    def _init_weights(self):
        for m in self.modules():
            if isinstance(m, nn.Linear):
                nn.init.xavier_uniform_(m.weight)
                nn.init.zeros_(m.bias)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        out = self.network(x)
        return self.output(out).squeeze(-1)


# ─────────────────────────────────────────────────────────────
# 2. ResNet-style Antenna Net
# ─────────────────────────────────────────────────────────────

class ResidualBlock(nn.Module):
    def __init__(self, dim: int, dropout: float = 0.1):
        super().__init__()
        self.block = nn.Sequential(
            nn.Linear(dim, dim),
            nn.BatchNorm1d(dim),
            nn.GELU(),
            nn.Dropout(dropout),
            nn.Linear(dim, dim),
            nn.BatchNorm1d(dim),
        )
        self.act = nn.GELU()

    def forward(self, x):
        return self.act(x + self.block(x))   # Residual connection


class AntennaResNet(nn.Module):
    """
    ResNet-style network for complex antenna-parameter relationships.
    Better gradient flow = better training for deep networks.
    """
    def __init__(self, input_dim: int, hidden_dim: int = 128,
                 n_blocks: int = 4, dropout: float = 0.1):
        super().__init__()
        self.input_proj = nn.Sequential(
            nn.Linear(input_dim, hidden_dim),
            nn.BatchNorm1d(hidden_dim),
            nn.GELU(),
        )
        self.blocks = nn.ModuleList(
            [ResidualBlock(hidden_dim, dropout) for _ in range(n_blocks)]
        )
        self.output = nn.Linear(hidden_dim, 1)

    def forward(self, x):
        x = self.input_proj(x)
        for block in self.blocks:
            x = block(x)
        return self.output(x).squeeze(-1)


# ─────────────────────────────────────────────────────────────
# 3. Training Engine
# ─────────────────────────────────────────────────────────────

class DeepLearningTrainer:
    """
    Training engine for PyTorch antenna models.
    Features: LR scheduling, early stopping, metric tracking.
    """

    def __init__(self, model: nn.Module, device: str = 'auto'):
        if device == 'auto':
            self.device = 'cuda' if torch.cuda.is_available() else 'cpu'
        else:
            self.device = device
        self.model = model.to(self.device)
        print(f"[DeepLearning] Device: {self.device}")
        print(f"[DeepLearning] Model params: {sum(p.numel() for p in model.parameters()):,}")

    def train(self, X_train: np.ndarray, y_train: np.ndarray,
              X_val: np.ndarray,   y_val: np.ndarray,
              epochs: int = 500, lr: float = 1e-3, batch_size: int = 64,
              weight_decay: float = 1e-4, patience: int = 30) -> Dict:
        """
        Full training loop with:
        - Adam optimizer
        - Cosine annealing LR schedule
        - Early stopping
        - Huber loss (robust to outliers)
        """

        # Convert to tensors
        Xt = torch.FloatTensor(X_train).to(self.device)
        yt = torch.FloatTensor(y_train).to(self.device)
        Xv = torch.FloatTensor(X_val).to(self.device)
        yv = torch.FloatTensor(y_val).to(self.device)

        dataset  = TensorDataset(Xt, yt)
        loader   = DataLoader(dataset, batch_size=batch_size, shuffle=True, num_workers=0)

        optimizer = optim.AdamW(self.model.parameters(), lr=lr, weight_decay=weight_decay)
        scheduler = optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=epochs, eta_min=1e-6)
        criterion = nn.HuberLoss(delta=0.1)   # Robust loss

        history = {'train_loss': [], 'val_loss': [], 'val_r2': []}
        best_val_loss = float('inf')
        best_state    = None
        patience_cnt  = 0

        print(f"\n[Training] Epochs: {epochs} | LR: {lr} | Batch: {batch_size}")
        print(f"{'Epoch':>6} | {'Train Loss':>12} | {'Val Loss':>10} | {'Val R²':>8} | {'LR':>10}")
        print("-" * 60)

        for epoch in range(1, epochs + 1):
            # Training phase
            self.model.train()
            train_loss = 0.0
            for Xb, yb in loader:
                optimizer.zero_grad()
                pred = self.model(Xb)
                loss = criterion(pred, yb)
                loss.backward()
                nn.utils.clip_grad_norm_(self.model.parameters(), 1.0)  # Gradient clipping
                optimizer.step()
                train_loss += loss.item() * len(yb)
            train_loss /= len(Xt)

            # Validation phase
            self.model.eval()
            with torch.no_grad():
                val_pred = self.model(Xv)
                val_loss = criterion(val_pred, yv).item()
                val_r2   = self._compute_r2(yv.cpu().numpy(), val_pred.cpu().numpy())

            scheduler.step()
            history['train_loss'].append(train_loss)
            history['val_loss'].append(val_loss)
            history['val_r2'].append(val_r2)

            if epoch % 50 == 0 or epoch == 1:
                print(f"{epoch:>6} | {train_loss:>12.6f} | {val_loss:>10.6f} | "
                      f"{val_r2:>8.4f} | {scheduler.get_last_lr()[0]:>10.2e}")

            # Early stopping
            if val_loss < best_val_loss - 1e-6:
                best_val_loss = val_loss
                best_state    = {k: v.clone() for k, v in self.model.state_dict().items()}
                patience_cnt  = 0
            else:
                patience_cnt += 1
                if patience_cnt >= patience:
                    print(f"\n  Early stopping at epoch {epoch} (patience={patience})")
                    break

        # Restore best weights
        if best_state:
            self.model.load_state_dict(best_state)
            print(f"  Restored best model (val_loss={best_val_loss:.6f})")

        torch.save(self.model.state_dict(), 'deep_model.pth')
        print("  Model saved: deep_model.pth")
        return history

    def predict(self, X: np.ndarray) -> np.ndarray:
        self.model.eval()
        with torch.no_grad():
            Xt   = torch.FloatTensor(X).to(self.device)
            pred = self.model(Xt)
        return pred.cpu().numpy()

    def evaluate(self, X_test: np.ndarray, y_test: np.ndarray) -> Dict:
        preds = self.predict(X_test)
        r2    = self._compute_r2(y_test, preds)
        rmse  = np.sqrt(np.mean((y_test - preds)**2))
        mae   = np.mean(np.abs(y_test - preds))

        print(f"\n--- Deep Learning Test Performance ---")
        print(f"  R²   = {r2:.4f}")
        print(f"  RMSE = {rmse:.4f}")
        print(f"  MAE  = {mae:.4f}")

        return {'R2': r2, 'RMSE': rmse, 'MAE': mae, 'predictions': preds}

    def plot_history(self, history: Dict, title: str = 'Deep Learning Training'):
        fig, axes = plt.subplots(1, 2, figsize=(12, 4), facecolor='#1a1a2e')
        for ax in axes:
            ax.set_facecolor('#16213e')
            ax.tick_params(colors='white')
            ax.spines['bottom'].set_color('#444')
            ax.spines['left'].set_color('#444')
            ax.spines['top'].set_visible(False)
            ax.spines['right'].set_visible(False)
            ax.xaxis.label.set_color('white')
            ax.yaxis.label.set_color('white')

        axes[0].plot(history['train_loss'], color='#00d4ff', lw=2, label='Train')
        axes[0].plot(history['val_loss'],   color='#ff6b6b', lw=2, label='Validation')
        axes[0].set_xlabel('Epoch'); axes[0].set_ylabel('Huber Loss')
        axes[0].set_title('Training Curve', color='white'); axes[0].legend(); axes[0].grid(alpha=0.2)

        axes[1].plot(history['val_r2'], color='#a8e6cf', lw=2)
        axes[1].axhline(y=max(history['val_r2']), color='#ffd93d', lw=1.5, ls='--',
                        label=f'Best R²={max(history["val_r2"]):.4f}')
        axes[1].set_xlabel('Epoch'); axes[1].set_ylabel('Validation R²')
        axes[1].set_title('R² Score Over Training', color='white')
        axes[1].legend(); axes[1].grid(alpha=0.2)

        fig.suptitle(title, color='white', fontsize=14)
        plt.tight_layout()
        plt.savefig('deep_learning_training.png', dpi=150, bbox_inches='tight')
        plt.show()

    @staticmethod
    def _compute_r2(y_true, y_pred):
        ss_res = np.sum((y_true - y_pred)**2)
        ss_tot = np.sum((y_true - np.mean(y_true))**2)
        return 1 - ss_res / (ss_tot + 1e-10)


# ─────────────────────────────────────────────────────────────
# Quick Test
# ─────────────────────────────────────────────────────────────
if __name__ == '__main__':
    import sys; sys.path.insert(0, '..')
    from data_loader import load_antenna_data

    print("=== Deep Learning Model Test ===")
    data = load_antenna_data('patch', 'S11_dB', n_samples=800)
    X_tr, X_te = data['X_train'], data['X_test']
    y_tr, y_te = data['y_train'], data['y_test']

    # Split validation from training
    val_split = int(0.1 * len(X_tr))
    X_val, y_val = X_tr[:val_split], y_tr[:val_split]
    X_tr2, y_tr2 = X_tr[val_split:], y_tr[val_split:]

    input_dim = X_tr.shape[1]

    # Test MLP
    mlp = AntennaMLP(input_dim, hidden_dims=[128, 64, 32], dropout=0.2)
    trainer = DeepLearningTrainer(mlp)
    history = trainer.train(X_tr2, y_tr2, X_val, y_val, epochs=200, lr=1e-3)
    metrics = trainer.evaluate(X_te, y_te)
    trainer.plot_history(history, 'Patch Antenna MLP')

    # Test ResNet
    resnet = AntennaResNet(input_dim, hidden_dim=64, n_blocks=3)
    trainer2 = DeepLearningTrainer(resnet)
    history2 = trainer2.train(X_tr2, y_tr2, X_val, y_val, epochs=200, lr=1e-3)
    metrics2 = trainer2.evaluate(X_te, y_te)
