# network-renderer-openconfig

`network-renderer-openconfig` is the peer renderer that projects explicit
`network-control-plane-model` (CPM) semantics into OpenConfig RFC 7951 /
JSON_IETF instance documents.

Current status: construction scaffold, intentionally fail-closed. The project
does not yet emit an OpenConfig instance document. It proves the current
CPM-to-OpenConfig contract gap without filling it from NixOS, Containerlab,
renderer-local defaults, or platform conventions.

## Semantic boundary

```text
                              ┌─> network-renderer-nixos
NFM -> CPM (single authority) ├─> network-renderer-containerlab-linux-backend
                              └─> network-renderer-openconfig
```

All three renderers consume CPM directly. OpenConfig output is not an input to
the NixOS or Containerlab/Linux renderers, and those peer projections are not
inputs to this renderer. Target-specific syntax and mechanics may differ, but
no renderer may add network semantics absent from CPM.

Governing construction traces:

- `FS-162-HDS-010-SDS-010-SMS-010`: instance document emission
- `FS-162-HDS-010-SDS-020-SMS-010`: pinned YANG validation
- `FS-162-HDS-010-SDS-030-SMS-010`: fail-closed CPM parsing
- `FS-162-HDS-010-SDS-040-SMS-010`: comparable FS-230 posture projection

## Pinned OpenConfig tooling

The flake pins `nixpkgs`, `openconfig/public`, CPM, and the construction input
in `flake.lock`. `libyang` provides `yanglint`; the app names the executable
explicitly because the package has no reliable default main program.

```bash
nix run .#yanglint -- --version
```

Validate a future RFC 7951 / JSON_IETF instance document with:

```bash
nix run .#validate-oc-instance -- ./result.json
```

The validator first checks the committed OpenConfig lock identity, required
module files, and JSON instance syntax. It then loads the pinned model paths
and explicitly implements
`openconfig/public/third_party/ietf/iana-if-type.yang`. A search path alone
is not sufficient for JSON identity-ref values such as
`iana-if-type:ethernetCsmacd`. Results include the model revision, flake-lock
SHA-256, `yanglint` version, validation time, and a structured diagnostic
code.

## Current CPM parsing result

Run the parser against a CPM JSON artifact and an exact runtime target:

```bash
nix run .#render-openconfig -- \
  ./output-control-plane-model.json \
  --runtime-target esp0xdeadbeef-site-a-s-router-core-wan
```

The current CPM provides `runtimeIfName`, `sourceKind`, and `adapterClass`, but
does not provide an explicit IANA interface-type identity. In the pinned
`openconfig-interfaces` schema, `config.type` is mandatory. Treating
`sourceKind` or `adapterClass` as `iana-if-type:ethernetCsmacd` would invent
meaning, so the parser:

1. records traceable mappings such as `runtimeIfName` to `name` and
   `config.name`;
2. records `OC_CPM_PARSE_GAP_TYPE` for `config.type` plus any other missing
   deterministic fields;
3. records current CPM fields outside the selected
   `openconfig-interfaces` surface as
   `OC_CPM_PARSE_UNSUPPORTED_FIELD`;
4. rejects any peer-renderer input with `OC_CPM_PARSE_PEER_CONSUMED`;
5. writes the structured gap record to stderr;
6. emits no instance document and exits with status 2.

This is concrete construction work for the next change in the owning CPM and
renderer layers, not a successful renderer result.

## Portable FS-230 posture

The `FS-162-HDS-010-SDS-040-SMS-010` construction check compiles the same
canonical isolated FS-230 intent independently with the NixOS, CLAB, and
OpenConfig inventories. Each path uses the same pinned compiler and CPM
revisions. The check compares this normalized posture:

- IPv6 UDP port 4242 ingress;
- no NAT66 or source translation;
- preserved source identity and stateful return;
- the selected access node, endpoint, and service;
- no inherited public egress.

The OpenConfig verifier reads CPM directly and rejects peer-renderer input.
The check reports `cpmPortable=true` because CPM contains the complete portable
posture. It separately reports `openConfigModelComplete=false` because the
currently selected OpenConfig model set cannot express every policy field as
an instance document. This limitation does not weaken the CPM portability
claim and does not authorize renderer-local defaults.

## Construction checks

```bash
nix flake check --print-build-logs
bash tests/test.sh
```

The checks compile the pinned `openconfig-interfaces` schema, generate a real
CPM from the pinned `single-wan-uplink-static-egress` input, and compile all
three FS-230 realization inventories. The focused tests exercise the YANG
validation negatives, the real-CPM parser negatives, the portable posture
comparison, altered-posture rejection, CPM-identity rejection, and peer-input
rejection. A green check means the current instance-document gap is detected
deterministically and the portable FS-230 posture is present in direct CPM
input. It does not claim complete OpenConfig instance emission or resolve the
missing CPM IANA interface-type authority.
