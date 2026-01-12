#!/bin/bash

#!/bin/bash
# -E is critical: it ensures the trap is inherited by functions and subshells
set -eEuxo pipefail

dump_debug_info() {
  # Capture the exit code of the failed command
  EXIT_CODE=$?
  echo "!!! ERROR detected (Exit Code: $EXIT_CODE). Dumping debug info... !!!"

  echo ">>> [K8S] Pod Status (all namespaces)"
  kubectl get pods -A

  echo ">>> [K8S] Detailed Pod State in cattle-monitoring-system"
  # This shows specifically why pods are failing (e.g., Syscall errors, Volume mount errors)
  kubectl get pods -n cattle-monitoring-system -o wide
  kubectl describe pods -n cattle-monitoring-system

  echo ">>> [K8S] Cluster Events"
  kubectl get events -A --sort-by='.lastTimestamp' | tail -n 50

  echo ">>> [SELinux] Recent AVC Denials"
  # Sudo is required for audit logs
  sudo ausearch -m avc -ts recent 2>/dev/null || sudo grep "denied" /var/log/audit/audit.log | tail -n 100

  echo ">>> [SELinux] Suggested Fixes (audit2allow)"
  # This tells you exactly what rules to add to your rancher-selinux policy
  sudo grep "denied" /var/log/audit/audit.log | audit2allow -R

  echo ">>> [SELinux] Policy Status"
  sestatus
  semodule -l | grep rancher || echo "No rancher policy found"

  echo ">>> [System] Journal Logs (K3s/RKE2)"
  # Check both common service names
  sudo journalctl -u k3s -u rke2-server --no-pager -n 300
}

# Apply the trap
trap dump_debug_info ERR

function enforceSELinux(){
    free -m
    lscpu
    echo "> Check SELinux status"
    # Short circuit if SELinux is not being enforced.
    getenforce | grep -q Enforcing
    # Install container-selinux and selinux-policy latest versions
    sudo dnf install -y container-selinux selinux-policy --best --allowerasing
    sudo semodule -DB
    # Install rancher-selinux policy
    sudo dnf install -y /tmp/rancher-selinux.rpm
}

function installDependencies(){
    echo 'echo "export PATH=$PATH:/usr/local/bin"' >> ~/.bashrc
    echo 'echo "export TERM=xterm"' >> ~/.bashrc

    sudo dnf install -y jq git setools policycoreutils-python-utils

    echo "> Installing Helm 3"
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    helm version

    local KUBECTL_VERSION
    KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
    ARCH=$(uname -m)
    [[ "${ARCH}" == "aarch64" ]] && ARCH="arm64"
    [[ "${ARCH}" == "x86_64" ]] && ARCH="amd64"

    echo "> Installing kubectl ${KUBECTL_VERSION} for ${ARCH}"
    curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"
    curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl.sha256"
    echo "$(<kubectl.sha256)  kubectl" | sha256sum -c -
    install -o root -g root -m 0755 kubectl /usr/bin/kubectl
    kubectl version --client=true
}

function installRKE2(){
    echo "> Installing RKE2"
    curl -sfL https://get.rke2.io | sh -
    systemctl start rke2-server.service
    systemctl enable rke2-server.service

    export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
    echo "export KUBECONFIG=/etc/rancher/rke2/rke2.yaml" >> ~/.bashrc
    # Making the kubeconfig world-readable, as this is for tests purposes only.
    chmod +r /etc/rancher/rke2/rke2.yaml

    kubectl wait --for=create node/$(hostname) --timeout=240s
    kubectl wait "$(kubectl get node -o name | head -n1)" --for=condition=ready --timeout=240s
    kubectl wait --timeout=240s --for=condition=ready -n kube-system pod -l app.kubernetes.io/instance=rke2-coredns
    kubectl wait --timeout=240s --for=condition=ready -n kube-system pod -l app.kubernetes.io/component=controller
}

function installRancher(){
    echo "> Installing Cert Manager"
    helm repo add jetstack https://charts.jetstack.io
    helm install cert-manager jetstack/cert-manager \
        --namespace cert-manager --create-namespace \
        --set crds.enabled=true
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=300s

    echo "> Installing Rancher Manager"
    kubectl create namespace cattle-system
    helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
    helm install rancher rancher-latest/rancher \
        --namespace cattle-system \
        --set hostname=rancher.local \
        --set replicas=1 \
    	--wait

    # Background processes, such as Fleet deployment need to take place, which
    # may result in intermittent errors. Adding some extra verification,
    # such as rancher-webhook deployment creation.

    kubectl wait --for=condition=ready -n cattle-system pod -l app=rancher --timeout=600s
    kubectl wait --for=create -n cattle-system deployment/rancher-webhook --timeout=240s
    kubectl wait --for=condition=ready -n cattle-system pod -l app=rancher-webhook --timeout=240s
}

# Example: installRancherChart "rancher-monitoring" "cattle-monitoring-system" "rancher-monitoring-prometheus-node-exporter" "app.kubernetes.io/name=prometheus-node-exporter" "--set prometheus.prometheusSpec.maximumStartupDurationSeconds=60"
function installRancherChart() {
    local CHART_NAME="$1"
    local NAMESPACE="$2"
    local DAEMONSET_NAME="$3"
    local POD_LABEL_SELECTOR="$4"
    local EXTRA_HELM_ARGS="${@:5}" # Collect any additional arguments

    # Add Rancher charts repository
    helm repo add rancher-charts https://charts.rancher.io/

    echo "> Installing CRD chart ${CHART_NAME}-crd in namespace ${NAMESPACE}"
    helm upgrade --install=true \
        --labels=catalog.cattle.io/cluster-repo-name=rancher-charts \
        --namespace="${NAMESPACE}" --timeout=10m0s --wait=true \
        --create-namespace \
        "${CHART_NAME}-crd" "rancher-charts/${CHART_NAME}-crd"

    # Start watching events in the background so they appear in GH Actions logs LIVE
    kubectl get events -n "${NAMESPACE}" -w &
    WATCH_PID=$!

    echo "> Installing main chart ${CHART_NAME} with SELinux enabled"
    helm upgrade -v6 --install=true \
        --labels=catalog.cattle.io/cluster-repo-name=rancher-charts \
        --namespace="${NAMESPACE}" --timeout=10m0s --wait=true \
        --create-namespace \
        "${CHART_NAME}" "rancher-charts/${CHART_NAME}" \
        --set global.seLinux.enabled=true \
        ${EXTRA_HELM_ARGS}
        
    # Kill the watcher once helm finishes
    kill $WATCH_PID || true

    # Wait for DaemonSet creation and Pod readiness
    kubectl wait --for=create -n "${NAMESPACE}" daemonset/"${DAEMONSET_NAME}" --timeout=240s
    kubectl wait --for=condition=ready -n "${NAMESPACE}" pod -l "${POD_LABEL_SELECTOR}" --timeout=240s
}

function uninstallRancherChart() {
    local CHART_NAME="$1"
    local NAMESPACE="$2"

    echo "> Uninstalling main chart ${CHART_NAME} from namespace ${NAMESPACE}"
    helm uninstall "${CHART_NAME}" -n "${NAMESPACE}" --wait
    
    echo "> Uninstalling CRD chart ${CHART_NAME}-crd"
    helm uninstall "${CHART_NAME}-crd" -n "${NAMESPACE}" --wait
    echo "> Deleting namespace ${NAMESPACE}"
    kubectl delete ns "${NAMESPACE}" --timeout=120s

    # Force-reclaim caches to provide a clean memory slate for the next test
    sudo sync && echo 3 > /proc/sys/vm/drop_caches
}

# Example: e2eSELinuxVerification "fluentbit" "fluent-bit" "cattle-logging-system" "rke_logreader_t"
function e2eSELinuxVerification(){
    local CONTAINER_NAME="$1"
    local CONTAINER_RUNNING_NAME="$2"
    local POD_NAMESPACE="$3"
    local POD_NAME=$(kubectl get pods -n ${POD_NAMESPACE} -o custom-columns=NAME:.metadata.name | grep "${CONTAINER_NAME}")
    local CONTAINER_EXPECTED_SLTYPE="$4"
    local CONTAINER_RUNNING_SLTYPE=""

    echo "> Verify the presence of ${CONTAINER_EXPECTED_SLTYPE}"
    if [[ "$(seinfo -t ${CONTAINER_EXPECTED_SLTYPE} | grep -o ${CONTAINER_EXPECTED_SLTYPE})" == "${CONTAINER_EXPECTED_SLTYPE}" ]]; then
        echo "SELinux type is present: ${CONTAINER_EXPECTED_SLTYPE}"
    else
        echo "SELinux type is not present: ${CONTAINER_EXPECTED_SLTYPE}"
    fi

    echo "> Verify expected SELinux context type ${CONTAINER_EXPECTED_SLTYPE} for container ${CONTAINER_NAME}"
    CONTAINER_RUNNING_SLTYPE=$(kubectl get pod ${POD_NAME} -n ${POD_NAMESPACE} -o json | jq -r ".spec.containers[] | select(.name==\"${CONTAINER_RUNNING_NAME}\") | .securityContext.seLinuxOptions.type")
    if [[ "${CONTAINER_RUNNING_SLTYPE}" == "${CONTAINER_EXPECTED_SLTYPE}" ]]; then
        echo "SELinux type is correct: ${CONTAINER_RUNNING_SLTYPE}"
    else
        echo "SELinux type is incorrect or not set: ${CONTAINER_RUNNING_SLTYPE}"
        exit 1
    fi

    echo "> Look for any AVCs related to ${CONTAINER_RUNNING_SLTYPE}"
    if ausearch -m AVC,USER_AVC | grep "${CONTAINER_RUNNING_SLTYPE}" > /dev/null; then
        echo "AVCs found for ${CONTAINER_RUNNING_SLTYPE}"
        ausearch -m AVC,USER_AVC | grep "${CONTAINER_RUNNING_SLTYPE}"
        exit 1
    else
        echo "No AVCs found for ${CONTAINER_RUNNING_SLTYPE}"
    fi
}

function main(){
    enforceSELinux
    installDependencies
    installRKE2
    installRancher

    # Note: Append this list with new components to install and test the rancher-selinux policy
    # Value: A space-separated list of arguments:
    #   Namespace DaemonSet PodLabel ContainerName ContainerRunningName SELinuxType ExtraHelmArgs
    declare -A COMPONENTS=(
        [rancher-monitoring]="cattle-monitoring-system rancher-monitoring-prometheus-node-exporter app.kubernetes.io/name=prometheus-node-exporter node-exporter node-exporter prom_node_exporter_t --set prometheus.prometheusSpec.maximumStartupDurationSeconds=60"
        [rancher-logging]="cattle-logging-system rancher-logging-root-fluentbit app.kubernetes.io/name=fluentbit fluentbit fluent-bit rke_logreader_t"
    )

    for CHART_NAME in "${!COMPONENTS[@]}"; do
        # Read the space-separated values into individual variables
        read -r NAMESPACE DAEMONSET_NAME POD_LABEL CONTAINER_NAME CONTAINER_RUNNING_NAME SELINUX_TYPE EXTRA_HELM_ARGS <<< "${COMPONENTS[${CHART_NAME}]}"

        echo "> Installing and testing Chart: ${CHART_NAME} in Namespace: ${NAMESPACE} with SELinux type ${SELINUX_TYPE}"

        # 1. Install the chart (passing the collected variables)
        installRancherChart \
            "${CHART_NAME}" \
            "${NAMESPACE}" \
            "${DAEMONSET_NAME}" \
            "${POD_LABEL}" \
            "${EXTRA_HELM_ARGS}"

        # 2. Run E2E SELinux Verification
        e2eSELinuxVerification \
            "${CONTAINER_NAME}" \
            "${CONTAINER_RUNNING_NAME}" \
            "${NAMESPACE}" \
            "${SELINUX_TYPE}"

        # 3. Uninstall the chart (free some resources)
        uninstallRancherChart \
            "${CHART_NAME}" \
            "${NAMESPACE}"
    done
}

# This is needed as Rocky does not include it in the PATH,
# which is required for the Helm install.
export PATH=$PATH:/usr/local/bin

main

