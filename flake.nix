{
  description = "CPM to OpenConfig semantic projection";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    openconfig = {
      url = "github:openconfig/public";
      flake = false;
    };

    network-control-plane-model.url =
      "github:esp0xdeadbeef/network-control-plane-model";
    network-control-plane-model.inputs.nixpkgs.follows = "nixpkgs";

    network-labs.url = "github:esp0xdeadbeef/network-labs";
  };

  outputs =
    { self
    , nixpkgs
    , openconfig
    , network-control-plane-model
    , network-labs
    , ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      flakeLock = builtins.fromJSON (builtins.readFile ./flake.lock);
      openconfigRevision =
        flakeLock.nodes.openconfig.locked.rev
          or (throw "flake.lock lacks nodes.openconfig.locked.rev");
      cpmNodeName = flakeLock.nodes.root.inputs.network-control-plane-model;
      cpmNode = flakeLock.nodes.${cpmNodeName};
      cpmRevision =
        cpmNode.locked.rev
          or (throw "flake.lock lacks the CPM revision");
      forwardingNodeName = cpmNode.inputs.network-forwarding-model;
      compilerNodeName =
        flakeLock.nodes.${forwardingNodeName}.inputs.network-compiler;
      compilerRevision =
        flakeLock.nodes.${compilerNodeName}.locked.rev
          or (throw "flake.lock lacks the compiler revision");
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
          currentCpm =
            network-control-plane-model.libBySystem.${system}.compileAndBuildFromPaths {
              inputPath =
                "${network-labs}/examples/single-wan-uplink-static-egress/intent.nix";
              inventoryPath =
                "${network-labs}/examples/single-wan-uplink-static-egress/inventory-nixos.nix";
            };
          currentCpmJson =
            pkgs.writeText "current-control-plane-model.json"
              (builtins.toJSON currentCpm);
          fs230Intent =
            "${network-labs}/GAMP/SMT/${fs230TraceId}/intent.nix";
          mkFs230Cpm = inventoryName:
            network-control-plane-model.libBySystem.${system}.compileAndBuildFromPaths {
              inputPath = fs230Intent;
              inventoryPath =
                "${network-labs}/GAMP/SMT/${fs230TraceId}/${inventoryName}";
            };
          fs230CpmNixos = mkFs230Cpm "inventory-nixos.nix";
          fs230CpmClab = mkFs230Cpm "inventory-clab.nix";
          fs230CpmOpenConfig = mkFs230Cpm "inventory-openconfig.nix";
        in
        {
          render-openconfig = pkgs.writeShellApplication {
            name = "render-openconfig";
            runtimeInputs = [ pkgs.python3 ];
            text = ''
              exec python3 ${./render-openconfig.py} "$@"
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
          fs230-cpm-nixos-json =
            pkgs.writeText "fs230-cpm-nixos.json" (builtins.toJSON fs230CpmNixos);
          fs230-cpm-clab-json =
            pkgs.writeText "fs230-cpm-clab.json" (builtins.toJSON fs230CpmClab);
          fs230-cpm-openconfig-json =
            pkgs.writeText "fs230-cpm-openconfig.json" (builtins.toJSON fs230CpmOpenConfig);

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
          program =
            "${self.packages.${system}.render-openconfig}/bin/render-openconfig";
        };

        validate-oc-instance = {
          type = "app";
          program =
            "${self.packages.${system}.validate-oc-instance}/bin/validate-oc-instance";
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
          openconfig-schema = pkgs.runCommand
            "openconfig-interface-schema-validation"
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

          yang-validation-contract = pkgs.runCommand
            "openconfig-yang-validation-contract"
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

              validate-oc-instance conformant.json >pass.json
              jq -e '
                .code == "OC_YANG_VALIDATION_PASS"
                and .status == "OK"
                and .modelRevision == "${openconfigRevision}"
                and .networkAccess == false
                and (.flakeLockSha256 | test("^[0-9a-f]{64}$"))
                and (.yanglintVersion | contains("yanglint"))
                and (.validatedAt | test("Z$|[+]00:00$"))
              ' pass.json >/dev/null

              jq 'del(
                ."openconfig-interfaces:interfaces".interface[0].config.type
              )' conformant.json >invalid.json
              if validate-oc-instance invalid.json 2>invalid-diagnostic.json; then
                echo "FAIL: schema-invalid instance was accepted" >&2
                exit 1
              fi
              jq -e '
                .code == "OC_YANG_VALIDATION_ERROR"
                and .status == "NOT_OK"
                and (.yanglintStderr | contains("Mandatory node"))
              ' invalid-diagnostic.json >/dev/null

              if validate-oc-instance \
                --flake-lock missing-flake.lock \
                conformant.json 2>missing-lock.json
              then
                echo "FAIL: missing flake lock was accepted" >&2
                exit 1
              fi
              jq -e '.code == "OC_YANG_MODELS_UNLOCKED"' \
                missing-lock.json >/dev/null

              jq '.nodes.openconfig.locked.rev = "stale-fixture-revision"' \
                ${./flake.lock} >stale-flake.lock
              if validate-oc-instance \
                --flake-lock stale-flake.lock \
                conformant.json 2>stale-lock.json
              then
                echo "FAIL: stale OpenConfig revision was accepted" >&2
                exit 1
              fi
              jq -e '
                .code == "OC_YANG_MODELS_UNLOCKED"
                and .actualRevision == "stale-fixture-revision"
                and .expectedRevision == "${openconfigRevision}"
              ' stale-lock.json >/dev/null

              mkdir empty-model-root
              if validate-oc-instance \
                --model-root empty-model-root \
                conformant.json 2>missing-module.json
              then
                echo "FAIL: missing YANG modules were accepted" >&2
                exit 1
              fi
              jq -e '
                .code == "OC_YANG_MODULE_MISSING"
                and (.missingModules | length == 2)
              ' missing-module.json >/dev/null

              printf '{broken-json\n' >malformed.json
              if validate-oc-instance malformed.json 2>malformed-diagnostic.json; then
                echo "FAIL: malformed JSON instance was accepted" >&2
                exit 1
              fi
              jq -e '.code == "OC_INSTANCE_DOCUMENT_INVALID"' \
                malformed-diagnostic.json >/dev/null

              touch "$out"
            '';

          cpm-parser-fail-closed = pkgs.runCommand
            "openconfig-cpm-parser-fail-closed"
            {
              nativeBuildInputs = [
                self.packages.${system}.render-openconfig
                pkgs.jq
              ];
            }
            ''
              if render-openconfig \
                ${currentCpmJson} \
                --runtime-target esp0xdeadbeef-site-a-s-router-core-wan \
                >rendered.json 2>diagnostic.json
              then
                echo "FAIL: current CPM unexpectedly produced OpenConfig output" >&2
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
                .code == "OC_CPM_PARSE_GAP_TYPE"
                and .status == "NOT_OK"
                and .runtimeTarget == "esp0xdeadbeef-site-a-s-router-core-wan"
                and ([.interfaces[].gaps[].openconfigPath]
                  | index("config.type") != null)
                and ([.interfaces[].mapped[].openconfigPath]
                  | index("name") != null)
                and .summary.unsupported > 0
                and ([.interfaces[].unsupported[].code]
                  | index("OC_CPM_PARSE_UNSUPPORTED_FIELD") != null)
              ' diagnostic.json >/dev/null

              touch "$out"
            '';

          fs230-posture-contract = pkgs.runCommand
            "openconfig-fs230-posture-contract"
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
              nixos_cpm=${self.packages.${system}.fs230-cpm-nixos-json}
              clab_cpm=${self.packages.${system}.fs230-cpm-clab-json}
              openconfig_cpm=${self.packages.${system}.fs230-cpm-openconfig-json}

              check_posture() {
                realization="$1"
                cpm="$2"
                fs230-posture "$cpm" \
                  --realization "$realization" \
                  --canonical-intent "$intent" \
                  --compiler-revision ${compilerRevision} \
                  --cpm-revision ${cpmRevision} \
                  --network-labs-revision ${networkLabsRevision} \
                  >"$realization-record.json"
                jq -e '
                  .code == "OC_FS230_POSTURE_PASS"
                  and .status == "OK"
                  and .cpmPortable == true
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

              check_posture nixos "$nixos_cpm"
              check_posture clab "$clab_cpm"
              check_posture openconfig "$openconfig_cpm"

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

              openconfig_hash="$(sha256sum "$openconfig_cpm" | cut -d ' ' -f 1)"
              fs230-posture "$openconfig_cpm" \
                --realization openconfig \
                --canonical-intent "$intent" \
                --compiler-revision ${compilerRevision} \
                --cpm-revision ${cpmRevision} \
                --network-labs-revision ${networkLabsRevision} \
                --expected-cpm-sha256 "$openconfig_hash" \
                >/dev/null

              if fs230-posture "$openconfig_cpm" \
                --realization openconfig \
                --canonical-intent "$intent" \
                --compiler-revision ${compilerRevision} \
                --cpm-revision ${cpmRevision} \
                --network-labs-revision ${networkLabsRevision} \
                --expected-cpm-sha256 0000000000000000000000000000000000000000000000000000000000000000 \
                2>identity-mismatch.json
              then
                echo "FAIL: mismatched CPM identity was accepted" >&2
                exit 1
              fi
              jq -e '.code == "OC_FS230_CPM_IDENTITY_MISMATCH"' \
                identity-mismatch.json >/dev/null

              jq '
                (.control_plane_model.data."mini-smt"."${fs230TraceId}"
                  .runtimeTargets[]
                  | select(.natIntent.publicIngress | length > 0)
                  .natIntent.publicIngress[0].tupleRecords[0].protocol) = "tcp"
              ' "$openconfig_cpm" >wrong-protocol.json
              if fs230-posture wrong-protocol.json \
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

              if fs230-posture "$openconfig_cpm" \
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

              if render-openconfig "$openconfig_cpm" \
                --runtime-target mini-smt-${fs230TraceId}-core-lab-wan \
                >unexpected-instance.json 2>model-gap.json
              then
                echo "FAIL: incomplete OpenConfig model coverage was reported complete" >&2
                exit 1
              fi
              jq -e '.code == "OC_CPM_PARSE_GAP_TYPE"' model-gap.json >/dev/null
              test ! -s unexpected-instance.json

              touch "$out"
            '';
        }
      );
    };
}
