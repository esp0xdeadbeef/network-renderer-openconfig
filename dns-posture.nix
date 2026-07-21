{
  lib,
  network-realization-model,
}:
let
  traceId = "FS-540-HDS-010-SDS-010-SMS-050";
  ruleIdentity = "openconfig-dns-posture/v1";

  reject = code: detail: context: {
    accepted = false;
    exit = 2;
    diagnostic = {
      inherit
        code
        context
        detail
        traceId
        ;
    };
    posture = null;
  };

  only = values: if builtins.length values == 1 then builtins.head values else null;
  sortedUnique = values: lib.sort builtins.lessThan (lib.unique values);

  requiredProvenance = {
    requesterService = "dns.recursive.bindings[0].advertisedResolver.name";
    providerService = "dns.recursive.bindings[0].upstreamResolver.name";
    providerNode = "dns.recursive.bindings[0].upstreamResolver.node";
    recursionMode = "dns.recursive.services[0].recursionMode";
    listenerScope = "runtimeTargets.<provider>.services.dns.serviceEndpointBindings";
    selectedEgress = "dns.recursive.bindings[0].egressSurface.uplinks";
    addressFamilies = "dns.recursive.bindings[0].allowedAddressFamilies";
    transports = "communicationContract.trafficTypes[name=dns].match";
    publicFallback = "dns.recursive.bindings[0].directPublicFallback";
    localOnly = "dns.localSharing";
  };

  validateProjection =
    {
      projection,
      peerPostures ? [ ],
    }:
    if !(projection.accepted or false) then
      projection
    else
      let
        provenanceFields = map (record: record.field or null) (projection.fieldProvenance or [ ]);
        missingProvenance = builtins.filter (field: !(builtins.elem field provenanceFields)) (
          builtins.attrNames requiredProvenance
        );
        limitations = projection.limitations or [ ];
        limitationComplete = builtins.any (
          limitation:
          (limitation.canonicalPath or null) == projection.dnsCanonicalPath
          && (limitation.ruleIdentity or null) == ruleIdentity
        ) limitations;
        divergentPeers = builtins.filter (posture: posture != projection.posture) peerPostures;
      in
      if missingProvenance != [ ] then
        reject "OC_DNS_OUTPUT_WITHOUT_PROVENANCE" "normalized DNS posture lacks canonical provenance" {
          inherit missingProvenance;
        }
      else if !limitationComplete then
        reject "OC_DNS_MODEL_LIMITATION_SILENCED"
          "unsupported canonical DNS posture lacks a pinned-model limitation"
          {
            canonicalPath = projection.dnsCanonicalPath;
          }
      else if divergentPeers != [ ] then
        reject "OC_DNS_PEER_POSTURE_DIVERGENCE"
          "peer renderer posture differs from the shared canonical posture"
          {
            divergentPeerCount = builtins.length divergentPeers;
          }
      else
        projection;

  project =
    {
      bundle,
      enterprise,
      site,
      platformBinding ? null,
      peerRendererInput ? null,
    }:
    if peerRendererInput != null then
      reject "OC_DNS_PEER_RENDERER_CONSUMED" "peer renderer output cannot supply OpenConfig DNS posture" {
        sourceRenderer =
          if builtins.isAttrs peerRendererInput then
            peerRendererInput.renderer or "<unknown>"
          else
            peerRendererInput;
        destinationRenderer = "openconfig";
      }
    else if (bundle.kind or null) != "network-realization-bundle" then
      reject "OC_DNS_RAW_CPM_INPUT" "expected one validated canonical realization bundle" { }
    else
      let
        validatedAttempt = builtins.tryEval (
          builtins.deepSeq (network-realization-model.lib.validateRendererInput {
            inherit bundle platformBinding;
            expectedTarget = "openconfig";
          }) true
        );
      in
      if !validatedAttempt.success then
        reject "OC_DNS_RAW_CPM_INPUT" "canonical bundle validation failed before DNS projection" { }
      else
        let
          validated = network-realization-model.lib.validateRendererInput {
            inherit bundle platformBinding;
            expectedTarget = "openconfig";
          };
          enterpriseData = validated.semanticModel.data.${enterprise} or { };
          siteData = enterpriseData.${site} or { };
          dns = siteData.dns or { };
          recursive = dns.recursive or { };
          binding = only (recursive.bindings or [ ]);
          upstream = if binding == null then { } else binding.upstreamResolver or { };
          services = builtins.filter (service: (service.name or null) == (upstream.name or null)) (
            recursive.services or [ ]
          );
          service = only services;
          uplinks = if binding == null then [ ] else binding.egressSurface.uplinks or [ ];
          families = if binding == null then [ ] else sortedUnique (binding.allowedAddressFamilies or [ ]);
          trafficTypes = builtins.filter (trafficType: (trafficType.name or null) == "dns") (
            (siteData.communicationContract or { }).trafficTypes or [ ]
          );
          dnsTraffic = only trafficTypes;
          matches = if dnsTraffic == null then [ ] else dnsTraffic.match or [ ];
          transports = sortedUnique (
            map (match: match.proto or "<missing>") (
              builtins.filter (match: builtins.elem 53 (match.dports or [ ])) matches
            )
          );
          requiredCoverage = builtins.concatLists (
            map
              (
                family:
                map (proto: { inherit family proto; }) [
                  "tcp"
                  "udp"
                ]
              )
              [
                "ipv4"
                "ipv6"
              ]
          );
          missingCoverage = builtins.filter (
            required:
            !(builtins.any (
              match:
              builtins.elem 53 (match.dports or [ ])
              && (match.proto or null) == required.proto
              && builtins.elem (match.family or null) [
                "any"
                required.family
              ]
            ) matches)
          ) requiredCoverage;
          providerTargets = builtins.filter (
            target: (target.logicalNode.name or null) == (upstream.node or null)
          ) (builtins.attrValues (siteData.runtimeTargets or { }));
          providerTarget = only providerTargets;
          providerDns = if providerTarget == null then { } else providerTarget.services.dns or { };
          endpointBindings = builtins.filter (
            endpoint:
            (endpoint.service or null) == (upstream.name or null)
            && (endpoint.providerNode or null) == (upstream.node or null)
          ) (providerDns.serviceEndpointBindings or [ ]);
          endpointBinding = only endpointBindings;
          localSharing = dns.localSharing or { };
          lateralPolicy = localSharing.lateralPolicy or { };
          localRequester = localSharing.requester or { };
          localOnlySafe =
            (localRequester.recursion or true) == false
            && (localRequester.publicFallback or true) == false
            && (lateralPolicy.recursion or true) == false
            && (lateralPolicy.transitiveEgress or true) == false
            && (lateralPolicy.localData or false) == true
            && (lateralPolicy.action or null) == "refuse_non_local";
          dnsCanonicalPath = "/network/data/data/${enterprise}/${site}/dns";
          posture = {
            requesterService = binding.advertisedResolver.name;
            providerService = upstream.name;
            providerNode = upstream.node;
            recursionMode = service.recursionMode;
            listenerScope = {
              relationId = endpointBinding.relationId;
              terminalAttachmentId = endpointBinding.terminalAttachmentId;
            };
            selectedEgress = builtins.head uplinks;
            addressFamilies = families;
            inherit transports;
            publicFallback = binding.directPublicFallback;
            localOnly = {
              action = lateralPolicy.action;
              localData = lateralPolicy.localData;
              publicFallback = localRequester.publicFallback;
              recursion = localRequester.recursion;
              transitiveEgress = lateralPolicy.transitiveEgress;
            };
          };
          projection = {
            accepted = true;
            exit = 0;
            diagnostic = null;
            inherit dnsCanonicalPath posture traceId;
            bundleIdentity = validated.bundleIdentity;
            canonicalPortable = true;
            networkAccess = false;
            openConfigModelComplete = false;
            fieldProvenance = lib.mapAttrsToList (field: suffix: {
              inherit field ruleIdentity;
              canonicalPath = "${dnsCanonicalPath}/${suffix}";
            }) requiredProvenance;
            limitations = [
              {
                code = "OC_DNS_MODEL_LIMITATION";
                canonicalPath = dnsCanonicalPath;
                openconfigPath = null;
                inherit ruleIdentity;
                reason = "the pinned OpenConfig module set does not express the complete recursive resolver and requester-policy posture";
              }
            ];
          };
        in
        if
          binding == null
          || (upstream.name or null) == null
          || (upstream.node or null) == null
          || service == null
        then
          reject "OC_DNS_CORE_BINDING_MISSING" "exactly one named core DNS binding and provider are required"
            {
              bindingCount = builtins.length (recursive.bindings or [ ]);
            }
        else if uplinks == [ ] then
          reject "OC_DNS_EGRESS_SELECTION_MISSING"
            "recursive DNS requires one explicit selected egress identity"
            { }
        else if builtins.length uplinks != 1 then
          reject "OC_DNS_EGRESS_SELECTION_AMBIGUOUS" "recursive DNS selected more than one egress identity" {
            candidates = map (candidate: builtins.hashString "sha256" candidate) (sortedUnique uplinks);
          }
        else if
          families != [
            "ipv4"
            "ipv6"
          ]
          || missingCoverage != [ ]
        then
          reject "OC_DNS_FAMILY_INCOMPLETE" "dual-stack UDP and TCP DNS coverage is incomplete" {
            addressFamilies = families;
            inherit missingCoverage transports;
          }
        else if !localOnlySafe then
          reject "OC_DNS_LOCAL_ONLY_LEAK" "local-only requester gained recursive or transitive authority" { }
        else if endpointBinding == null then
          reject "OC_DNS_CORE_BINDING_MISSING"
            "named core DNS provider lacks its relation-terminal endpoint binding"
            { }
        else
          validateProjection { inherit projection; };
in
{
  inherit project validateProjection;
}
