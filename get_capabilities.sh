#!/usr/bin/env bash
# Print known OCP capabilities (stable since 4.14).
# Verify against a specific version with:
#   openshift-install explain installconfig.capabilities.additionalEnabledCapabilities
set -eu

cat <<'EOF'
baremetal
Build
CloudCredential
Console
CSISnapshot
DeploymentConfig
ImageRegistry
Ingress
Insights
MachineAPI
marketplace
NodeTuning
openshift-samples
OperatorLifecycleManager
Storage
EOF
