"""Time models on CPU only: python -I cpu_run.py <song> <out dir> model1 model2 ..."""
import sys
import time
from pathlib import Path

import torch

# Hiding the GPU with CUDA_VISIBLE_DEVICES breaks the Roformer loader, so pretend CUDA is absent instead.
torch.cuda.is_available = lambda: False

from audio_separator.separator import Separator  # noqa: E402

song, out = sys.argv[1], Path(sys.argv[2])
models_dir = Path(__file__).resolve().parent.parent / "sep" / "models"
out.mkdir(parents=True, exist_ok=True)
torch.set_num_threads(torch.get_num_threads())
print("threads", torch.get_num_threads(), flush=True)
for model in sys.argv[3:]:
    sep = Separator(model_file_dir=str(models_dir), output_dir=str(out), output_format="FLAC", log_level=30)
    start = time.perf_counter()
    sep.load_model(model_filename=model)
    loaded = time.perf_counter()
    sep.separate(song)
    done = time.perf_counter()
    print(f"{model:60} load {loaded - start:6.1f} s  separate {done - loaded:7.1f} s  device={sep.torch_device}", flush=True)
