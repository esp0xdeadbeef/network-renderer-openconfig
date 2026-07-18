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

          current-cpm-json = currentCpmJson;

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
        }
      );
    };
}
