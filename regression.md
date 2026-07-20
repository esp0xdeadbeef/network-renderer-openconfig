# Resolved regressions

## FS-162-HDS-010-SDS-040-SMS-010: FS-230 posture bypassed realization

State: solved

The previous mini-POC compiled separate NixOS, Containerlab, and OpenConfig
CPM inputs and read each CPM artifact directly. Equal normalized output did not
prove equal canonical input identity, and the path bypassed the realization
model and canonical schema gate.

The migrated controlled construction flow now uses one replacement CPM
artifact, `network-realization-model`, schema validation, and one canonical
bundle for all three peer labels. The check proves equal bundle identity and
equal FS-230 posture, rejects altered canonical posture, rejects a mismatched
bundle identity, and rejects peer-renderer input. The old direct-CPM fixture is
retained as the `OC_RAW_CPM_INPUT` negative.

The selected OpenConfig model set still does not express the complete ingress
policy posture. That limitation is explicit and does not authorize local
defaults or values from NixOS or Containerlab output.

Proof:

```bash
bash tests/FS-162-HDS-010-SDS-040-SMS-010.sh
nix flake check --all-systems
```
