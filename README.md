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

## Construction checks

```bash
nix flake check --print-build-logs
bash tests/test.sh
```

The check compiles the pinned `openconfig-interfaces` schema and generates a
real CPM from the pinned `single-wan-uplink-static-egress` input. The focused
tests exercise the YANG validation negatives and the real-CPM parser negatives
named by FS-162-HDS-010-SDS-020-SMS-010 and
FS-162-HDS-010-SDS-030-SMS-010. A green check means the current gap is detected
deterministically; it does not claim instance emission or resolve the missing
CPM IANA interface-type authority.
