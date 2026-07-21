# network-renderer-openconfig

`network-renderer-openconfig` is a peer renderer for validated canonical
network-realization bundles. It emits RFC 7951 / JSON_IETF OpenConfig instance
documents and never consumes raw CPM, NixOS output, Containerlab output, or
another renderer artifact as network-semantic authority.

## Contract boundary

```text
CPM replacement or normal pipeline output
  -> network-realization-model
  -> network-realization-schema validation
  -> validated canonical bundle ─┬─> network-renderer-nixos
                                 ├─> network-renderer-containerlab-linux-backend
                                 └─> network-renderer-openconfig

validated platform-binding bundle (optional, target mechanics only)
  -> selected peer renderer
```

Every peer comparison uses the same canonical bundle identity. A renderer may
also receive one normalized and validated platform-binding bundle. That bundle
may contain interface-identity, deployment, secret-delivery, lifecycle, and
backend categories under one schema and identity. It may not add address,
route, DNS, NAT, firewall, exposure, egress, policy, or trust authority.

The controlled construction API is
`libBySystem.<system>.renderer.canonical.validateInput`. It accepts `bundle`
and optional `platformBinding`, requires target `openconfig` for a supplied
binding bundle, and rejects raw CPM or unvalidated canonical input before any
OpenConfig mapping runs.

## OpenConfig mapping

The renderer requires explicit canonical interface identity, including an IANA
interface-type identity. The versioned
`openconfig-interface-mapping-v1.json` file maps each selected canonical leaf
to OpenConfig paths and supplies a rule identity. Every emitted field records:

- canonical bundle identity;
- canonical path;
- upstream CPM source path and transformation rule;
- OpenConfig output path;
- OpenConfig mapping-rule identity.

Unmapped canonical paths are terminal unless a versioned mapping contract
records a deterministic limitation. Renderer-local defaults and type
inference from names, `sourceKind`, adapter class, or peer output are terminal.

## Pinned YANG validation

The flake pins `openconfig/public`, `nixpkgs`, the canonical schema/model, CPM,
and construction inputs. `validate-oc-instance` validates the candidate against
the pinned OpenConfig interfaces and IANA interface-type modules without
runtime network discovery. The renderer releases an accepted instance only
after that gate succeeds.

```bash
nix run .#render-openconfig -- ./validated-canonical-bundle.json
candidate_sha="$(sha256sum ./openconfig-instance.json | cut -d ' ' -f 1)"
canonical_bundle_identity="$(jq -r .bundleIdentity ./validated-canonical-bundle.json)"
nix run .#validate-oc-instance -- ./openconfig-instance.json \
  --expected-instance-sha256 "$candidate_sha" \
  --bundle-identity "$canonical_bundle_identity" \
  --renderer-identity network-renderer-openconfig:openconfig-interface-mapping/v1
nix run .#yanglint -- --version
```

## Controlled FS-230 construction

`FS-162-HDS-010-SDS-040-SMS-010` uses one replacement CPM artifact, one
realization-model pass, and one validated canonical bundle for the NixOS,
Containerlab, and OpenConfig peer comparison. The check proves equal bundle
identity and equal normalized posture for IPv6 UDP ingress, no NAT66, preserved
source identity, stateful return, selected endpoint binding, and no inherited
public egress. It separately records that the selected OpenConfig module set
does not express the complete ingress-policy posture.

Raw CPM input is constructed only inside the active `OC_RAW_CPM_INPUT` seeded
negative and is destroyed with that test's temporary workspace. No positive
direct-CPM runner, fixture, or historical compatibility path is retained.

## Construction checks

```bash
nix flake check --all-systems --print-build-logs
bash tests/test.sh
```

The trace-literal emission test exercises all eight seeded negatives from
`FS-162-HDS-010-SDS-010-SMS-010`. Each case asserts the exact diagnostic,
exit behavior, empty accepted stdout, deterministic rerun, and recovery with
the valid canonical fixture. The principal diagnostics are:

- `OC_RAW_CPM_INPUT`;
- `OC_REQUIRED_CANONICAL_FIELD_MISSING`;
- `OC_CANONICAL_PATH_UNMAPPED`;
- `OC_TYPE_IDENTITY_UNMAPPED`;
- `OC_PEER_RENDERER_CONSUMED`;
- `OC_RENDERER_DEFAULT_INVENTED`;
- `OC_OUTPUT_WITHOUT_PROVENANCE`;
- `OC_YANG_VALIDATION_FAILED`.

These checks are construction evidence only. They do not claim deployment to
an OpenConfig device.
