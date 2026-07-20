{
  description = "CPM to OpenConfig semantic projection";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    openconfig = {
      url = "github:openconfig/public";
      flake = false;
    };

    network-control-plane-model.url = "github:esp0xdeadbeef/network-control-plane-model";
    network-control-plane-model.inputs.nixpkgs.follows = "nixpkgs";

    network-realization-model.url = "github:esp0xdeadbeef/network-realization-model/12bc6490b18099b5642e1551403ad0ee02a9f5c9";
    network-realization-model.inputs.nixpkgs.follows = "nixpkgs";
    network-realization-schema.url = "github:esp0xdeadbeef/network-realization-schema/8b80339aa1344e1ad178045635bac45fbf36191d";
    network-realization-schema.inputs.nixpkgs.follows = "nixpkgs";

    network-labs.url = "github:esp0xdeadbeef/network-labs";
  };

  outputs =
    {
      self,
      nixpkgs,
      openconfig,
      network-control-plane-model,
      network-realization-model,
      network-realization-schema,
      network-labs,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      flakeLock = builtins.fromJSON (builtins.readFile ./flake.lock);
      openconfigRevision =
        flakeLock.nodes.openconfig.locked.rev or (throw "flake.lock lacks nodes.openconfig.locked.rev");
      cpmNodeName = flakeLock.nodes.root.inputs.network-control-plane-model;
      cpmNode = flakeLock.nodes.${cpmNodeName};
      cpmRevision = cpmNode.locked.rev or (throw "flake.lock lacks the CPM revision");
      forwardingNodeName = cpmNode.inputs.network-forwarding-model;
      compilerNodeName = flakeLock.nodes.${forwardingNodeName}.inputs.network-compiler;
      compilerRevision =
        flakeLock.nodes.${compilerNodeName}.locked.rev or (throw "flake.lock lacks the compiler revision");
      networkLabsNodeName = flakeLock.nodes.root.inputs.network-labs;
      networkLabsRevision =
        flakeLock.nodes.${networkLabsNodeName}.locked.rev
          or (throw "flake.lock lacks the network-labs revision");
      fs230TraceId = "FS-230-HDS-010-SDS-010-SMS-040";
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          currentCpm = network-control-plane-model.libBySystem.${system}.compileAndBuildFromPaths {
            inputPath = "${network-labs}/examples/single-wan-uplink-static-egress/intent.nix";
            inventoryPath = "${network-labs}/examples/single-wan-uplink-static-egress/inventory-nixos.nix";
          };
          currentCpmJson = pkgs.writeText "current-control-plane-model.json" (builtins.toJSON currentCpm);
          fs230Intent = "${network-labs}/GAMP/SMT/${fs230TraceId}/intent.nix";
          mkFs230Cpm =
            inventoryName:
            network-control-plane-model.libBySystem.${system}.compileAndBuildFromPaths {
              inputPath = fs230Intent;
              inventoryPath = "${network-labs}/GAMP/SMT/${fs230TraceId}/${inventoryName}";
            };
          fs230CpmNixos = mkFs230Cpm "inventory-nixos.nix";
          fs230CpmClab = mkFs230Cpm "inventory-clab.nix";
          fs230CpmOpenConfig = mkFs230Cpm "inventory-openconfig.nix";
          fs230RealizationInput = {
            kind = "network-control-plane-artifact";
            artifactIdentity = builtins.hashString "sha256" (
              builtins.toJSON fs230CpmOpenConfig.control_plane_model
            );
            control_plane_model = fs230CpmOpenConfig.control_plane_model;
          };
          fs230IngressTarget = "mini-smt-${fs230TraceId}-core-lab-wan";
          fs230Site = fs230CpmOpenConfig.control_plane_model.data."mini-smt".${fs230TraceId};
          fs230Target = fs230Site.runtimeTargets.${fs230IngressTarget};
          fs230Ingress = builtins.head fs230Target.natIntent.publicIngress;
          fs230Tuple = builtins.head fs230Ingress.tupleRecords;
          fs230WrongControlPlaneModel = fs230CpmOpenConfig.control_plane_model // {
            data = fs230CpmOpenConfig.control_plane_model.data // {
              "mini-smt" = fs230CpmOpenConfig.control_plane_model.data."mini-smt" // {
                ${fs230TraceId} = fs230Site // {
                  runtimeTargets = fs230Site.runtimeTargets // {
                    ${fs230IngressTarget} = fs230Target // {
                      natIntent = fs230Target.natIntent // {
                        publicIngress = [
                          (
                            fs230Ingress
                            // {
                              tupleRecords = [ (fs230Tuple // { protocol = "tcp"; }) ];
                            }
                          )
                        ];
                      };
                    };
                  };
                };
              };
            };
          };
          fs230WrongRealizationInput = {
            kind = "network-control-plane-artifact";
            artifactIdentity = builtins.hashString "sha256" (builtins.toJSON fs230WrongControlPlaneModel);
            control_plane_model = fs230WrongControlPlaneModel;
          };
          fs230CanonicalBundle = network-realization-model.lib.realize {
            input = fs230RealizationInput;
            requestScope = {
              kind = "complete-artifact";
              identity = fs230TraceId;
            };
            rootLockIdentity = "network-renderer-openconfig-flake-lock";
            producerRevision = "network-realization-model-12bc6490";
          };
          fs230WrongCanonicalBundle = network-realization-model.lib.realize {
            input = fs230WrongRealizationInput;
            requestScope = {
              kind = "complete-artifact";
              identity = fs230TraceId;
            };
            rootLockIdentity = "network-renderer-openconfig-flake-lock";
            producerRevision = "network-realization-model-12bc6490";
          };
          realizationArgs = {
            requestScope = {
              kind = "complete-artifact";
              identity = "openconfig-interface-construction-fixture";
            };
            rootLockIdentity = "network-renderer-openconfig-flake-lock";
            producerRevision = "network-renderer-openconfig-construction";
          };
          realizationInput = import "${network-realization-model}/examples/cpm-result.nix";
          canonicalBundle = network-realization-model.lib.realize {
            input = realizationInput;
            requestScope = {
              kind = "complete-artifact";
              identity = "fixture-complete-artifact";
            };
            rootLockIdentity = "fixture-root-lock";
            producerRevision = "fixture-realization-model";
          };
          canonicalInterface = builtins.head realizationInput.control_plane_model.canonicalInterfaces;
          inputWithInterface =
            interface:
            let
              controlPlaneModel = realizationInput.control_plane_model // {
                canonicalInterfaces = [ interface ];
              };
            in
            realizationInput
            // {
              control_plane_model = controlPlaneModel;
              artifactIdentity = builtins.hashString "sha256" (builtins.toJSON controlPlaneModel);
            };
          bundleWithInterface =
            interface:
            network-realization-model.lib.realize (
              realizationArgs // { input = inputWithInterface interface; }
            );
          writeBundle =
            name: interface: pkgs.writeText name (builtins.toJSON (bundleWithInterface interface));
          mappingRules = builtins.fromJSON (builtins.readFile ./openconfig-interface-mapping-v1.json);
          semanticBindingBase = {
            kind = network-realization-schema.lib.schema.platformBinding.kind;
            schemaRevision = network-realization-schema.lib.schema.platformBinding.revision;
            bundleIdentity = canonicalBundle.bundleIdentity;
            target = "openconfig";
            requestScope = canonicalBundle.requestScope;
            categories.interfaceIdentity = [
              {
                canonicalPath = "/network/data/canonicalInterfaces/0";
                routes = [ "renderer-must-not-authorize-this-route" ];
              }
            ];
            provenance = {
              producer = "network-renderer-openconfig-construction";
              producerRevision = "fixture";
            };
          };
          semanticBindingWithIdentity = semanticBindingBase // {
            bindingIdentity = network-realization-schema.lib.computeBindingIdentity semanticBindingBase;
          };
          semanticBinding = semanticBindingWithIdentity // {
            validation = network-realization-schema.lib.validatePlatformBinding semanticBindingWithIdentity;
          };
        in
        {
          render-openconfig = pkgs.writeShellApplication {
            name = "render-openconfig";
            runtimeInputs = [ pkgs.python3 ];
            text = ''
              exec python3 ${./render-openconfig.py} \
                --mapping-rules ${./openconfig-interface-mapping-v1.json} \
                --validator ${self.packages.${system}.validate-oc-instance}/bin/validate-oc-instance \
                "$@"
            '';
          };

          validate-oc-instance = pkgs.writeShellApplication {
            name = "validate-oc-instance";
            runtimeInputs = [
              pkgs.libyang
              pkgs.python3
            ];
            text = ''
              exec python3 ${./validate-openconfig.py} \
                --model-root ${openconfig} \
                --flake-lock ${./flake.lock} \
                --expected-model-rev ${openconfigRevision} \
                "$@"
            '';
          };

          fs230-posture = pkgs.writeShellApplication {
            name = "fs230-posture";
            runtimeInputs = [ pkgs.python3 ];
            text = ''
              exec python3 ${./fs230-posture.py} "$@"
            '';
          };

          current-cpm-json = currentCpmJson;
          canonical-bundle-json = pkgs.writeText "network-realization-bundle.json" (
            builtins.toJSON canonicalBundle
          );
          semantic-platform-binding-json = pkgs.writeText "openconfig-semantic-platform-binding.json" (
            builtins.toJSON semanticBinding
          );
          canonical-bundle-missing-name-json = writeBundle "canonical-bundle-missing-name.json" (
            canonicalInterface
            // {
              identity = builtins.removeAttrs canonicalInterface.identity [ "name" ];
            }
          );
          canonical-bundle-unmapped-path-json = writeBundle "canonical-bundle-unmapped-path.json" (
            canonicalInterface // { ethernet.experimentalFlag = true; }
          );
          canonical-bundle-missing-type-json = writeBundle "canonical-bundle-missing-type.json" (
            builtins.removeAttrs canonicalInterface [ "type" ] // { sourceKind = "bridge"; }
          );
          canonical-bundle-missing-enabled-json = writeBundle "canonical-bundle-missing-enabled.json" (
            builtins.removeAttrs canonicalInterface [ "enabled" ]
          );
          canonical-bundle-invalid-yang-json = writeBundle "canonical-bundle-invalid-yang.json" (
            canonicalInterface
            // {
              type = canonicalInterface.type // {
                ianaIdentity = "iana-if-type:notARealIdentity";
              };
            }
          );
          mapping-rules-default-json = pkgs.writeText "openconfig-interface-mapping-default.json" (
            builtins.toJSON (
              mappingRules
              // {
                fields = mappingRules.fields // {
                  "/enabled" = mappingRules.fields."/enabled" // {
                    default = true;
                  };
                };
              }
            )
          );
          mapping-rules-missing-provenance-json =
            pkgs.writeText "openconfig-interface-mapping-missing-provenance.json"
              (
                builtins.toJSON (
                  mappingRules
                  // {
                    fields = mappingRules.fields // {
                      "/mtu" = builtins.removeAttrs mappingRules.fields."/mtu" [
                        "ruleIdentity"
                      ];
                    };
                  }
                )
              );
          mapping-rules-invalid-yang-json = pkgs.writeText "openconfig-interface-mapping-invalid-yang.json" (
            builtins.toJSON (
              mappingRules
              // {
                fields = mappingRules.fields // {
                  "/identity/name" = mappingRules.fields."/identity/name" // {
                    openconfigPaths = [ "name" ];
                  };
                };
              }
            )
          );
          fs230-cpm-nixos-json = pkgs.writeText "fs230-cpm-nixos.json" (builtins.toJSON fs230CpmNixos);
          fs230-cpm-clab-json = pkgs.writeText "fs230-cpm-clab.json" (builtins.toJSON fs230CpmClab);
          fs230-cpm-openconfig-json = pkgs.writeText "fs230-cpm-openconfig.json" (
            builtins.toJSON fs230CpmOpenConfig
          );
          fs230-canonical-bundle-json = pkgs.writeText "fs230-canonical-bundle.json" (
            builtins.toJSON fs230CanonicalBundle
          );
          fs230-wrong-canonical-bundle-json = pkgs.writeText "fs230-wrong-canonical-bundle.json" (
            builtins.toJSON fs230WrongCanonicalBundle
          );

          default = self.packages.${system}.render-openconfig;
        }
      );

      apps = forAllSystems (system: {
        yanglint = {
          type = "app";
          program = "${nixpkgs.legacyPackages.${system}.libyang}/bin/yanglint";
        };

        render-openconfig = {
          type = "app";
          program = "${self.packages.${system}.render-openconfig}/bin/render-openconfig";
        };

        validate-oc-instance = {
          type = "app";
          program = "${self.packages.${system}.validate-oc-instance}/bin/validate-oc-instance";
        };

        fs230-posture = {
          type = "app";
          program = "${self.packages.${system}.fs230-posture}/bin/fs230-posture";
        };

        default = self.apps.${system}.render-openconfig;
      });

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          currentCpmJson = self.packages.${system}.current-cpm-json;
        in
        {
          openconfig-schema =
            pkgs.runCommand "openconfig-interface-schema-validation"
              {
                nativeBuildInputs = [ pkgs.libyang ];
              }
              ''
                yanglint \
                  -p ${openconfig}/release/models/interfaces \
                  -p ${openconfig}/release/models/types \
                  -p ${openconfig}/release/models \
                  -p ${openconfig}/third_party/ietf \
                  ${openconfig}/release/models/interfaces/openconfig-interfaces.yang \
                  ${openconfig}/third_party/ietf/iana-if-type.yang

                touch "$out"
              '';

          yang-validation-contract =
            pkgs.runCommand "openconfig-yang-validation-contract"
              {
                nativeBuildInputs = [
                  self.packages.${system}.validate-oc-instance
                  pkgs.jq
                ];
              }
              ''
                cat >conformant.json <<'JSON'
                {
                  "openconfig-interfaces:interfaces": {
                    "interface": [
                      {
                        "name": "fixture0",
                        "config": {
                          "name": "fixture0",
                          "type": "iana-if-type:ethernetCsmacd",
                          "description": "synthetic construction fixture",
                          "enabled": true,
                          "mtu": 1500
                        }
                      }
                    ]
                  }
                }
                JSON

                candidate_sha() {
                  sha256sum "$1" | cut -d ' ' -f 1
                }

                validate_bound() {
                  instance="$1"
                  shift
                  validate-oc-instance "$instance" \
                    --expected-instance-sha256 "$(candidate_sha "$instance")" \
                    --bundle-identity fixture-bundle-identity \
                    --renderer-identity network-renderer-openconfig:fixture \
                    "$@"
                }

                assert_recovery() {
                  label="$1"
                  validate_bound conformant.json >"$label-recovery.json"
                  jq -e '
                    .code == "OC_YANG_VALIDATION_PASS"
                    and .status == "OK"
                    and .bundleIdentity == "fixture-bundle-identity"
                    and .rendererIdentity == "network-renderer-openconfig:fixture"
                    and (.candidateInstanceSha256 | test("^[0-9a-f]{64}$"))
                  ' "$label-recovery.json" >/dev/null
                }

                expect_failure() {
                  label="$1"
                  expected_exit="$2"
                  expected_code="$3"
                  shift 3
                  if "$@" >"$label-stdout.json" 2>"$label-stderr.json"; then
                    echo "FAIL: $label unexpectedly succeeded" >&2
                    exit 1
                  else
                    observed_exit="$?"
                  fi
                  test "$observed_exit" -eq "$expected_exit"
                  test ! -s "$label-stdout.json"
                  jq -e --arg code "$expected_code" '
                    .code == $code and .status == "NOT_OK"
                  ' "$label-stderr.json" >/dev/null
                  assert_recovery "$label"
                }

                validate_bound conformant.json >pass.json
                jq -e '
                  .code == "OC_YANG_VALIDATION_PASS"
                  and .status == "OK"
                  and .modelRevision == "${openconfigRevision}"
                  and .networkAccess == false
                  and .bundleIdentity == "fixture-bundle-identity"
                  and .rendererIdentity == "network-renderer-openconfig:fixture"
                  and (.candidateInstanceSha256 | test("^[0-9a-f]{64}$"))
                  and (.flakeLockSha256 | test("^[0-9a-f]{64}$"))
                  and (.yanglintVersion | contains("yanglint"))
                  and (.validatedAt | test("Z$|[+]00:00$"))
                ' pass.json >/dev/null

                jq 'del(
                  ."openconfig-interfaces:interfaces".interface[0].config.name
                )' conformant.json >invalid.json
                expect_failure OC-YANG-N1 3 OC_YANG_VALIDATION_FAILED \
                  validate_bound invalid.json
                jq -e '
                  (.yanglintStderr | contains("config/name"))
                  and .bundleIdentity == "fixture-bundle-identity"
                ' OC-YANG-N1-stderr.json >/dev/null

                expect_failure OC-YANG-N2 2 OC_YANG_MODELS_UNLOCKED \
                  validate_bound conformant.json \
                  --flake-lock missing-flake.lock
                jq -e '.flakeLock == "missing-flake.lock"' \
                  OC-YANG-N2-stderr.json >/dev/null

                jq '.nodes.openconfig.locked.rev = "stale-fixture-revision"' \
                  ${./flake.lock} >stale-flake.lock
                expect_failure OC-YANG-N2-stale 2 OC_YANG_MODELS_UNLOCKED \
                  validate_bound conformant.json \
                  --flake-lock stale-flake.lock
                jq -e '
                  .code == "OC_YANG_MODELS_UNLOCKED"
                  and .actualRevision == "stale-fixture-revision"
                  and .expectedRevision == "${openconfigRevision}"
                ' OC-YANG-N2-stale-stderr.json >/dev/null

                mkdir empty-model-root
                expect_failure OC-YANG-N3 2 OC_YANG_MODULE_MISSING \
                  validate_bound conformant.json \
                  --model-root empty-model-root
                jq -e '
                  .code == "OC_YANG_MODULE_MISSING"
                  and (.missingModules | length == 2)
                ' OC-YANG-N3-stderr.json >/dev/null

                expect_failure OC-YANG-N4 2 OC_YANG_NETWORK_ACCESS_DETECTED \
                  validate_bound conformant.json \
                  --model-catalog https://mutable.example.invalid/yang/catalog.json
                jq -e '
                  .networkRequestSent == false
                  and (.modelCatalog | startswith("https://"))
                ' OC-YANG-N4-stderr.json >/dev/null

                expect_failure OC-YANG-N5 2 OC_INSTANCE_DOCUMENT_INVALID \
                  validate_bound conformant.json \
                  --expected-instance-sha256 0000000000000000000000000000000000000000000000000000000000000000
                jq -e '
                  .expectedInstanceSha256 == "0000000000000000000000000000000000000000000000000000000000000000"
                  and (.actualInstanceSha256 | test("^[0-9a-f]{64}$"))
                ' OC-YANG-N5-stderr.json >/dev/null

                expect_failure OC-YANG-N6 2 OC_YANG_IDENTITY_UNBOUND \
                  validate-oc-instance conformant.json \
                  --expected-instance-sha256 "$(candidate_sha conformant.json)" \
                  --renderer-identity network-renderer-openconfig:fixture
                jq -e '
                  .missingIdentities == ["bundleIdentity"]
                ' OC-YANG-N6-stderr.json >/dev/null

                printf '{broken-json\n' >malformed.json
                expect_failure malformed-instance 2 OC_INSTANCE_DOCUMENT_INVALID \
                  validate_bound malformed.json
                jq -e '.code == "OC_INSTANCE_DOCUMENT_INVALID"' \
                  malformed-instance-stderr.json >/dev/null

                touch "$out"
              '';

          canonical-interface-emission =
            pkgs.runCommand "openconfig-canonical-interface-emission"
              {
                nativeBuildInputs = [
                  self.packages.${system}.render-openconfig
                  pkgs.jq
                ];
              }
              ''
                canonical_bundle=${self.packages.${system}.canonical-bundle-json}

                if render-openconfig \
                  ${currentCpmJson} \
                  --runtime-target esp0xdeadbeef-site-a-s-router-core-wan \
                  >rendered.json 2>diagnostic.json
                then
                  echo "FAIL: raw CPM unexpectedly produced OpenConfig output" >&2
                  exit 1
                else
                  rc="$?"
                fi

                if [ "$rc" -ne 2 ]; then
                  echo "FAIL: expected fail-closed exit 2, got $rc" >&2
                  cat diagnostic.json >&2
                  exit 1
                fi

                if [ -s rendered.json ]; then
                  echo "FAIL: fail-closed parser emitted an instance document" >&2
                  exit 1
                fi

                jq -e '
                  .code == "OC_RAW_CPM_INPUT"
                  and .status == "NOT_OK"
                ' diagnostic.json >/dev/null

                render-openconfig "$canonical_bundle" >accepted.json
                jq -e '
                  .code == "OC_INSTANCE_ACCEPTED"
                  and .status == "OK"
                  and .instance."openconfig-interfaces:interfaces".interface[0].name == "lan0"
                  and .instance."openconfig-interfaces:interfaces".interface[0].config == {
                    description: "explicit fixture tenant interface",
                    enabled: true,
                    mtu: 1500,
                    name: "lan0",
                    type: "iana-if-type:ethernetCsmacd"
                  }
                  and ([.fieldProvenance[].openconfigPath]
                    | index("/openconfig-interfaces:interfaces/interface/0/config/type") != null)
                  and ([.consumptionCoverage[].classification]
                    | all(. == "consumed" or . == "not-applicable"))
                  and (.outputCoverage | length) == (.fieldProvenance | length)
                  and .yangValidation.code == "OC_YANG_VALIDATION_PASS"
                ' accepted.json >/dev/null

                touch "$out"
              '';

          canonical-interface-negatives =
            pkgs.runCommand "openconfig-canonical-interface-negatives"
              {
                nativeBuildInputs = [
                  self.packages.${system}.render-openconfig
                  pkgs.jq
                ];
              }
              ''
                  export OC_VALID_BUNDLE=${self.packages.${system}.canonical-bundle-json}
                  export OC_RAW_CPM=${currentCpmJson}
                  export OC_MISSING_NAME=${self.packages.${system}.canonical-bundle-missing-name-json}
                  export OC_UNMAPPED_PATH=${self.packages.${system}.canonical-bundle-unmapped-path-json}
                  export OC_MISSING_TYPE=${self.packages.${system}.canonical-bundle-missing-type-json}
                  export OC_MISSING_ENABLED=${self.packages.${system}.canonical-bundle-missing-enabled-json}
                  export OC_DEFAULT_RULES=${self.packages.${system}.mapping-rules-default-json}
                  export OC_MISSING_PROVENANCE_RULES=${
                    self.packages.${system}.mapping-rules-missing-provenance-json
                  }
                  export OC_INVALID_YANG_RULES=${self.packages.${system}.mapping-rules-invalid-yang-json}
                  export OC_SEMANTIC_BINDING=${self.packages.${system}.semantic-platform-binding-json}
                  export OC_RENDERER=${self.packages.${system}.render-openconfig}/bin/render-openconfig
                  export OC_JQ=${pkgs.jq}/bin/jq

                ${pkgs.bash}/bin/bash ${./tests/FS-162-HDS-010-SDS-010-SMS-010-instance-document-emission.sh}
                  touch "$out"
              '';

          fs230-posture-contract =
            pkgs.runCommand "openconfig-fs230-posture-contract"
              {
                nativeBuildInputs = [
                  self.packages.${system}.fs230-posture
                  self.packages.${system}.render-openconfig
                  pkgs.coreutils
                  pkgs.diffutils
                  pkgs.jq
                ];
              }
              ''
                intent=${network-labs}/GAMP/SMT/${fs230TraceId}/intent.nix
                bundle=${self.packages.${system}.fs230-canonical-bundle-json}
                wrong_bundle=${self.packages.${system}.fs230-wrong-canonical-bundle-json}

                check_posture() {
                  realization="$1"
                  fs230-posture "$bundle" \
                    --realization "$realization" \
                    --canonical-intent "$intent" \
                      --compiler-revision ${compilerRevision} \
                      --cpm-revision ${cpmRevision} \
                      --network-labs-revision ${networkLabsRevision} \
                      >"$realization-record.json"
                  jq -e '
                    .code == "OC_FS230_POSTURE_PASS"
                    and .status == "OK"
                    and .canonicalPortable == true
                    and .openConfigModelComplete == false
                      and .networkAccess == false
                      and .posture.addressFamily == "ipv6"
                      and .posture.protocol == "udp"
                      and .posture.port == 4242
                      and .posture.translationMode == "none"
                      and .posture.sourcePreservation == "preserve-source"
                      and .posture.returnBehavior == "stateful-return"
                      and .posture.inheritedPublicEgress == false
                      and (.limitations | length == 1)
                    ' "$realization-record.json" >/dev/null
                }

                check_posture nixos
                check_posture clab
                check_posture openconfig

                  jq -S .posture nixos-record.json >nixos-posture.json
                  jq -S .posture clab-record.json >clab-posture.json
                  jq -S .posture openconfig-record.json >openconfig-posture.json
                  diff -u nixos-posture.json clab-posture.json
                  diff -u nixos-posture.json openconfig-posture.json

                  jq -S .sourceIdentity nixos-record.json >nixos-source.json
                  jq -S .sourceIdentity clab-record.json >clab-source.json
                  jq -S .sourceIdentity openconfig-record.json >openconfig-source.json
                  diff -u nixos-source.json clab-source.json
                  diff -u nixos-source.json openconfig-source.json

                bundle_identity="$(jq -r .bundleIdentity "$bundle")"
                fs230-posture "$bundle" \
                  --realization openconfig \
                    --canonical-intent "$intent" \
                    --compiler-revision ${compilerRevision} \
                    --cpm-revision ${cpmRevision} \
                    --network-labs-revision ${networkLabsRevision} \
                  --expected-bundle-identity "$bundle_identity" \
                  >/dev/null

                if fs230-posture "$bundle" \
                  --realization openconfig \
                    --canonical-intent "$intent" \
                    --compiler-revision ${compilerRevision} \
                    --cpm-revision ${cpmRevision} \
                    --network-labs-revision ${networkLabsRevision} \
                  --expected-bundle-identity 0000000000000000000000000000000000000000000000000000000000000000 \
                  2>identity-mismatch.json
                then
                  echo "FAIL: mismatched canonical bundle identity was accepted" >&2
                  exit 1
                fi
                jq -e '.code == "OC_FS230_BUNDLE_IDENTITY_MISMATCH"' \
                  identity-mismatch.json >/dev/null

                if fs230-posture "$wrong_bundle" \
                  --realization openconfig \
                    --canonical-intent "$intent" \
                    --compiler-revision ${compilerRevision} \
                    --cpm-revision ${cpmRevision} \
                    --network-labs-revision ${networkLabsRevision} \
                    2>posture-mismatch.json
                  then
                    echo "FAIL: altered FS-230 posture was accepted" >&2
                    exit 1
                  fi
                  jq -e '
                    .code == "OC_FS230_POSTURE_MISMATCH"
                    and ([.mismatches[].field] | index("tupleRecords") != null)
                  ' posture-mismatch.json >/dev/null

                if fs230-posture "$bundle" \
                    --realization openconfig \
                    --canonical-intent "$intent" \
                    --compiler-revision ${compilerRevision} \
                    --cpm-revision ${cpmRevision} \
                    --network-labs-revision ${networkLabsRevision} \
                    --peer-renderer-input forbidden-nixos-output.json \
                    2>peer-rejected.json
                  then
                    echo "FAIL: peer renderer input was accepted" >&2
                    exit 1
                  fi
                  jq -e '.code == "OC_PEER_RENDERER_CONSUMED"' \
                    peer-rejected.json >/dev/null

                if render-openconfig ${self.packages.${system}.fs230-cpm-openconfig-json} \
                    --runtime-target mini-smt-${fs230TraceId}-core-lab-wan \
                    >unexpected-instance.json 2>model-gap.json
                  then
                    echo "FAIL: raw CPM crossed the canonical renderer boundary" >&2
                    exit 1
                  fi
                  jq -e '.code == "OC_RAW_CPM_INPUT"' model-gap.json >/dev/null
                  test ! -s unexpected-instance.json

                  touch "$out"
              '';
        }
      );
    };
}
