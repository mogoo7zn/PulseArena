# Incoming Model Drop

Place server-trained checkpoints and exported metrics here before importing them
into the local registry.

Example:

```bash
python training/import_trained_model.py \
  --checkpoint training/data/incoming_models/hybrid_tactical_v2_bc_s01.pt \
  --metrics-json training/data/incoming_models/hybrid_tactical_v2_bc_s01_metrics.json \
  --model-id hybrid_tactical_v2_bc_s01 \
  --run-id hybrid_tactical_v2_bc_s01 \
  --hidden 256 \
  --update-catalog
```
