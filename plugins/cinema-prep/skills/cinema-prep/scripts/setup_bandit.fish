#!/usr/bin/env fish
# One-time (idempotent) setup for Bandit v2 cinematic separation.
# Everything lands in ~/.cache/cinema-prep so film folders stay clean.

set -l root $HOME/.cache/cinema-prep
set -l msst $root/msst
mkdir -p $root

if not test -d $msst
    echo "[setup] cloning Music-Source-Separation-Training"
    git clone --depth 1 https://github.com/ZFTurbo/Music-Source-Separation-Training.git $msst
    or exit 1
end

if not test -d $msst/.venv
    echo "[setup] creating venv"
    uv venv --python 3.12 $msst/.venv; or exit 1
end

set -l py $msst/.venv/bin/python
echo "[setup] installing deps"
VIRTUAL_ENV=$msst/.venv uv pip install -q \
    torch torchaudio "numpy>=2" pandas scipy soundfile ml_collections tqdm timm \
    einops omegaconf beartype rotary_embedding_torch "librosa>=0.11" "numba>=0.60" \
    "transformers<5" torchmetrics asteroid-filterbanks matplotlib pytorch_lightning
or exit 1

if not test -f $root/bandit_multi_fixed.ckpt
    if not test -f $root/bandit_multi.ckpt
        echo "[setup] downloading Bandit v2 checkpoint-multi (447 MB, Zenodo 12701995)"
        curl -fL --progress-bar -o $root/bandit_multi.ckpt \
            "https://zenodo.org/records/12701995/files/checkpoint-multi.ckpt?download=1"
        or exit 1
    end
    # Zenodo ships a Lightning bundle; MSST wants a bare state_dict.
    echo "[setup] converting checkpoint"
    $py -c "
import torch
res = torch.load('$root/bandit_multi.ckpt', map_location='cpu', weights_only=False)['state_dict']
for k in list(res.keys()):
    if k.startswith('model.'):
        res[k[6:]] = res.pop(k)
    if k.startswith('loss_handler'):
        res.pop(k, None)
torch.save(res, '$root/bandit_multi_fixed.ckpt')
"
    or exit 1
    rm -f $root/bandit_multi.ckpt
end

# Bandit holds float64 buffers; MPS refuses them, so cast before .to(device).
if not grep -q "cinema-prep float32" $msst/inference.py
    echo "[setup] patching inference.py for MPS"
    $py -c "
from pathlib import Path
p = Path('$msst/inference.py'); s = p.read_text()
old = '    model = model.to(device)'
new = '''    import torch as _t  # cinema-prep float32: MPS rejects float64 buffers
    for _n, _b in list(model.named_buffers()):
        if _b.dtype == _t.float64:
            _m = model
            *_path, _leaf = _n.split('.')
            for _p in _path:
                _m = getattr(_m, _p)
            setattr(_m, _leaf, _b.float())
    model = model.float().to(device)'''
assert old in s, 'anchor not found in inference.py'
p.write_text(s.replace(old, new, 1))
"
    or exit 1
end

echo "[setup] ready: $root"
