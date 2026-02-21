#!/bin/bash

set -euo pipefail
#Tina
SUMMARY_FILE="kube-burner-podlatency-summary_14Feb_def_series2.log"
echo "# podLatency summary (selected kube-burner output)" >> "${SUMMARY_FILE}"
# End_Tina
TEMPLATE_FILE="kubelet-density-heavy.template-cam-plus.yml"
NAMESPACE="kubelet-density-heavy"
MAX_WAIT_TIMEOUT="${MAX_WAIT_TIMEOUT:-10m}"
KUBEBURNER_TIMEOUT="${KUBEBURNER_TIMEOUT:-11m}"
INTER_EXPERIMENT_SLEEP="${INTER_EXPERIMENT_SLEEP:-10}"

# Define the number of times to repeat the entire set of experiments
iterations=5

# ---------------------------------------------------------------------------
# Experiments configuration
# ---------------------------------------------------------------------------
 experiments=(

  "jobIterations=1 qps=1 burst=1 postgres_deploy_replicas=5 app_deploy_replicas=5 postgres_service_replicas=5"
  "jobIterations=1 qps=100 burst=100 postgres_deploy_replicas=5 app_deploy_replicas=5 postgres_service_replicas=5"
  "jobIterations=1 qps=500 burst=500 postgres_deploy_replicas=5 app_deploy_replicas=5 postgres_service_replicas=5"

 )



#Tina
# ---------------------------------------------------------------------------
# Function: Collect Logs
# ---------------------------------------------------------------------------
extract_podlatency_block() {
  local src_log="$1"
  local experiment_desc="$2"
  local run_id="$3"

  {
    echo "============================================================"
    echo "run=${run_id} experiment=${experiment_desc}"
    echo "log=${src_log}"
    echo "------------------------------------------------------------"

    # Print only the relevant block:
    # from first stop line (podLatency or serviceLatency) up to and including "👋 Exiting kube-burner"
    awk '
      /Stopping measurement: (podLatency|serviceLatency)/ && !p {p=1}
      p {print}
      /👋 Exiting kube-burner/ {p=0; exit}
    ' "${src_log}" | sed -E '/file="base_measurement.go:[0-9]+"/{
      s/50th: ([0-9]+)/50th: \1ms/g
      s/99th: ([0-9]+)/99th: \1ms/g
      s/max: ([0-9]+)/max: \1ms/g
      s/avg: ([0-9]+)/avg: \1ms/g
    }'

    echo
  } >> "${SUMMARY_FILE}"
}

#End_Tina






# ---------------------------------------------------------------------------
# Function: HIGH-ACCURACY deletion measurement (ms resolution, 3 decimals)
# ---------------------------------------------------------------------------
measure_delete_time() {
  local ns="${NAMESPACE}"
  local experiment_desc="$1"
  local run_id="$2"
  local run_log_file="${3:-}"

  echo "------"
  echo "Starting deletion of resources in namespace '${ns}' for run=${run_id}"
  echo "Experiment: ${experiment_desc}"

  # Start timestamp in milliseconds
  local start_ts_ms
  start_ts_ms=$(date +%s%3N)

  # Delete deployments, services, and CodecoApps created by the workload + CAM
  kubectl delete deployment,svc -n "${ns}" --all --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete codecoapp -n "${ns}" --all --ignore-not-found=true >/dev/null 2>&1 || true

  # Poll until all pods, deployments, services, and CodecoApps are gone
  while true; do
    local remaining
    remaining=$(kubectl get pods,deploy,svc,codecoapp -n "${ns}" --no-headers 2>/dev/null | wc -l || echo 0)

    if [ "${remaining}" -eq 0 ]; then
      break
    fi

    echo "Waiting for resources to be deleted... remaining objects: ${remaining}"
    sleep 0.2  # 200ms polling
  done

  # End timestamp in milliseconds
  local end_ts_ms
  end_ts_ms=$(date +%s%3N)

  # Duration in milliseconds
  local duration_ms=$((end_ts_ms - start_ts_ms))

  # Convert ms → seconds with 3 decimals (X.XXX)
  local sec=$((duration_ms / 1000))
  local ms_rem=$((duration_ms % 1000))
  local duration
  duration=$(printf "%d.%03d" "${sec}" "${ms_rem}")

  # Log accurate duration
  echo "DeleteDurationSeconds run=${run_id} ${experiment_desc} duration=${duration}s"
  echo "DeleteDurationSeconds run=${run_id} ${experiment_desc} duration=${duration}s" >> deletion_times.log

  # Insert deletion latency metric in the run log before "Finished execution with UUID"
  if [ -n "${run_log_file}" ]; then
    local ts
    local delete_metric_line
    ts=$(date +"%Y-%m-%d %H:%M:%S")
    delete_metric_line="time=\"${ts}\" level=info msg=\"${NAMESPACE}: DeleteDuration 99th: ${duration_ms}ms max: ${duration_ms}ms avg: ${duration_ms}ms\" file=\"run_new.sh:measure_delete_time\""
    if grep -q 'Finished execution with UUID:' "${run_log_file}"; then
      awk -v ins="${delete_metric_line}" '
        /Finished execution with UUID:/ && !done { print ins; done=1 }
        { print }
      ' "${run_log_file}" > "${run_log_file}.tmp" && mv "${run_log_file}.tmp" "${run_log_file}"
    else
      echo "${delete_metric_line}" >> "${run_log_file}"
    fi
  fi

  echo "Finished deletion timing for run=${run_id} (${duration}s)"
  echo "------"
}

# ---------------------------------------------------------------------------
# Determine the starting log counter
# ---------------------------------------------------------------------------
if ls kubelet-density-heavy_*.log 1> /dev/null 2>&1; then
  counter=$(ls kubelet-density-heavy_*.log | grep -o '[0-9]*\.log' | grep -o '[0-9]*' | sort -n | tail -1)
  counter=$((counter + 1))
else
  counter=1
fi

# ---------------------------------------------------------------------------
# Main experiment loop
# ---------------------------------------------------------------------------
for (( run=1; run<=iterations; run++ )); do
  echo "============================================================"
  echo "Starting run ${run} of ${iterations}"
  echo "Using template file: ${TEMPLATE_FILE}"
  echo "Namespace: ${NAMESPACE}"
  echo "============================================================"

  for experiment in "${experiments[@]}"; do
    echo "------------------------------------------------------------"
    echo "Running experiment: ${experiment}"
    echo "------------------------------------------------------------"

    # Namespace cleanup before each experiment
    if kubectl get namespace "${NAMESPACE}" &> /dev/null; then
      echo "Namespace ${NAMESPACE} exists. Deleting..."
      kubectl delete namespace "${NAMESPACE}"

      while kubectl get namespace "${NAMESPACE}" &> /dev/null; do
        echo "Waiting for namespace cleanup..."
        sleep 1
      done
    fi

    kubectl create namespace "${NAMESPACE}"

    # Parse experiment variables (jobIterations, qps, burst, replicas, etc)
    eval "${experiment}"

    export JOB_ITERATIONS="${jobIterations}"
    export QPS="${qps}"
    export BURST="${burst}"
    export POSTGRES_DEPLOY_REPLICAS="${postgres_deploy_replicas}"
    export APP_DEPLOY_REPLICAS="${app_deploy_replicas}"
    export POSTGRES_SERVICE_REPLICAS="${postgres_service_replicas}"

    # Generate kube-burner manifest from CAM+workload template
    envsubst < "${TEMPLATE_FILE}" > kubelet-density-heavy.yml
    # Enforce a bounded kube-burner wait timeout (avoid default 4h hang)
    if grep -q '^[[:space:]]*maxWaitTimeout:' kubelet-density-heavy.yml; then
      sed -i -E "s|^([[:space:]]*maxWaitTimeout:).*|\\1 ${MAX_WAIT_TIMEOUT}|" kubelet-density-heavy.yml
    else
      sed -i -E "/^[[:space:]]*waitWhenFinished:[[:space:]]*true/a\\    maxWaitTimeout: ${MAX_WAIT_TIMEOUT}" kubelet-density-heavy.yml
    fi

    # Run kube-burner with hard timeout so a slow run doesn't block the whole batch
    if command -v timeout >/dev/null 2>&1; then
      timeout "${KUBEBURNER_TIMEOUT}" kube-burner init -c kubelet-density-heavy.yml || true
    else
      kube-burner init -c kubelet-density-heavy.yml || true
    fi

    # Rename kube-burner log
    log_file=$(ls -t kube-burner-*.log | head -n 1)
    new_log_file="kubelet-density-heavy_CAM_jobIterations${jobIterations}_qps${qps}_burst${burst}_postgres-deploy${postgres_deploy_replicas}_app${app_deploy_replicas}_postgres-service${postgres_service_replicas}_${counter}.log"
    mv "${log_file}" "${new_log_file}"
    sed -i -E '/file="service_latency.go:[0-9]+"/ s/: Ready 99th:/: ServiceLatency 99th:/' "${new_log_file}"
    # Measure precise deletion timing (includes CodecoApps)
    measure_delete_time "${experiment}" "${run}" "${new_log_file}"
    # Tina
    extract_podlatency_block "${new_log_file}" "${experiment}" "${run}"
    # End_Tina

    counter=$((counter + 1))

    echo "Sleeping ${INTER_EXPERIMENT_SLEEP}s before next experiment..."
    sleep "${INTER_EXPERIMENT_SLEEP}"
  done
done

echo "All CAM-enabled experiments completed."
