# Resolved regressions

## FS-162-HDS-010-SDS-040-SMS-010: FS-230 posture was not exercised

State: solved

The renderer previously compiled only the `single-wan-uplink-static-egress`
example and inspected interface records. It had no package or focused test that
compiled the pinned isolated `FS-230-HDS-010-SDS-010-SMS-040` source, verified
the IPv6 UDP/4242 no-NAT66 stateful-return posture in CPM, or proved that the
OpenConfig path consumed the same source identity as the NixOS and CLAB
construction paths.

The first missing boundary was `network-renderer-openconfig`: the canonical
FS-230 source and current CPM implementation already fed the peer NixOS and
CLAB construction checks, but this renderer did not select or inspect the
corresponding direct CPM input.

The focused check now compiles NixOS, CLAB, and OpenConfig CPM inputs from the
same canonical source and pinned compiler/CPM revisions. It proves equal
normalized posture, rejects altered posture, rejects an unexpected CPM
identity, and rejects peer-renderer input. The result reports CPM portability
separately from the incomplete OpenConfig instance-model coverage. Production
networks, runtime devices, and secrets remain outside this construction test.

Proof:

```bash
bash tests/FS-162-HDS-010-SDS-040-SMS-010-s-router-prod-comparable-projection.sh
nix flake check --all-systems
```
