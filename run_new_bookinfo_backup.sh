#!/bin/bash
# Author: Tina Samizadeh
# Date: 3 March 2026
# Location: Fortiss gmbh, Munich
#
# This script runs Bookinfo CodecoApp experiments.  It accepts up to 4
# positional parameters:
#   1) scheduler mode (qos|def)
#   2) pods_number (default 10)
#   3) qps (default 10, burst will be set equal to qps)
#   4) case_no
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

BASE_NS="${BASE_NS:-kdh}"
SCHEDULER_NAME="${1:-qos}" # qos | def
ITERATIONS="${ITERATIONS:-1}"
INTER_EXPERIMENT_SLEEP="${INTER_EXPERIMENT_SLEEP:-1}"
MAX_WAIT_TIMEOUT="${MAX_WAIT_TIMEOUT:-5m}"
WAIT_CREATE_TIMEOUT="${WAIT_CREATE_TIMEOUT:-240}"
WAIT_POLL_SECONDS="${WAIT_POLL_SECONDS:-5}"

TEMPLATE_FILE="kubelet-density-heavy.bookinfo-deployments.template-cam.yml"
DATE_TAG="$(date +%d%b_%H%M)"


DELETE_LOG="deletion_times.log"
CREATION_LOG="creation_readiness.log"
RUN_STATUS_LOG="run_status.log"

SCHEDULER_MODE="${1:-qos}" # qos | def
if [[ "${SCHEDULER_MODE}" != "qos" && "${SCHEDULER_MODE}" != "def" ]]; then
  echo "Usage: $0 {qos|def} [pods_number] [qps]"
  exit 1
fi


if [[ "${SCHEDULER_MODE}" == "qos" ]]; then
  SCHEDULER_NAME="qos-scheduler"
else
  SCHEDULER_NAME="default-scheduler"
fi



PODS_NUMBER="${2:-10}"
if ! [[ "${PODS_NUMBER}" =~ ^[0-9]+$ ]] || [[ "${PODS_NUMBER}" -le 0 ]]; then
  echo "ERROR: pods_number must be a positive integer (got: ${PODS_NUMBER})"
  echo "Usage: $0 {qos|def} [pods_number] [qps]"
  exit 1
fi
export PODS_NUMBER="${PODS_NUMBER}"

# allow caller to override QPS; burst is kept equal
QPS="${3:-10}"
if ! [[ "${QPS}" =~ ^[0-9]+$ ]] || [[ "${QPS}" -le 0 ]]; then
  echo "ERROR: qps must be a positive integer (got: ${QPS})"
  echo "Usage: $0 {qos|def} [pods_number] [qps]"
  exit 1
fi
export QPS="${QPS}"


CASE_NO="${4:-1}"
export CASE_NO="${CASE_NO}"
echo "case_no    " ${CASE_NO}

SUMMARY_FILE="n_pod-summary_${DATE_TAG}_${SCHEDULER_NAME}_${PODS_NUMBER}.log"
OBJECT_FILE="bookinfo-microservices-${SCHEDULER_NAME}.yml"

# experiments are driven by the CLI or environment QPS; burst follows qps
experiments=(
  "jobIterations=1 qps=${QPS} burst=${QPS} bookinfo_replicas=1"
# previous values (uncomment to test multiple qps):
#  "jobIterations=1 qps=10 burst=10 bookinfo_replicas=1"
#  "jobIterations=1 qps=50 burst=50 bookinfo_replicas=1"
#  "jobIterations=1 qps=100 burst=100 bookinfo_replicas=1"
#  "jobIterations=1 qps=150 burst=150 bookinfo_replicas=1"

#  "jobIterations=1 qps=1 burst=1 bookinfo_replicas=10"
#  "jobIterations=1 qps=100 burst=100 bookinfo_replicas=10"
#  "jobIterations=1 qps=500 burst=500 bookinfo_replicas=10"
#  "jobIterations=1 qps=1000 burst=1000 bookinfo_replicas=10"

#  "jobIterations=1 qps=1 burst=1 bookinfo_replicas=40"
#  "jobIterations=1 qps=100 burst=100 bookinfo_replicas=40"
#  "jobIterations=1 qps=500 burst=500 bookinfo_replicas=40"
#  "jobIterations=1 qps=1000 burst=1000 bookinfo_replicas=40"
)

init_logs() {
  : > "${SUMMARY_FILE}"
  : > "${CREATION_LOG}"
  : > "${RUN_STATUS_LOG}"
  {
    echo "# podLatency summary"
    echo "# started: $(date --iso-8601=seconds)"
    echo "# scheduler: ${SCHEDULER_NAME}"
    echo "# qps: ${QPS} (burst same as qps)"
    echo "# resource usage: cpu/memory from metrics-server; network is best-effort via pod eth0 counters"
    echo
  } >> "${SUMMARY_FILE}"
  {
    echo "# creation/readiness summary"
    echo "# started: $(date --iso-8601=seconds)"
    echo "# scheduler: ${SCHEDULER_NAME}"
    echo "# wait_create_timeout_seconds: ${WAIT_CREATE_TIMEOUT}"
    echo "# wait_poll_seconds: ${WAIT_POLL_SECONDS}"
    echo
  } >> "${CREATION_LOG}"
  {
    echo "# run status"
    echo "# started: $(date --iso-8601=seconds)"
    echo "# scheduler: ${SCHEDULER_NAME}"
    echo "# max_wait_timeout: ${MAX_WAIT_TIMEOUT}"
    echo
  } >> "${RUN_STATUS_LOG}"
}

write_experiment_header() {
  local experiment_desc="$1"
  local run_id="$2"
  local log_file="$3"
  local uuid=""
  
  if [[ -n "${log_file}" && -f "${log_file}" ]]; then
    uuid="$(awk -F'UUID ' '/Starting kube-burner/{print $NF; exit}' "${log_file}" 2>/dev/null || true)"
  fi
  
  {
    echo "============================================================"
    echo "ts=$(date --iso-8601=seconds)"
    echo "run=${run_id}"
    echo "experiment=${experiment_desc}"
    echo "uuid=${uuid}"
    echo "log=${log_file}"
    echo "------------------------------------------------------------"
  } >> "${SUMMARY_FILE}"
}

calc_stats_from_file_ms() {
  local values_file="$1"
  if [[ ! -s "${values_file}" ]]; then
    echo "na na na na na na 0"
    return 0
  fi

  local count min_index q1_index median_index q3_index max_index
  local min q1 median q3 max avg
  count=$(wc -l < "${values_file}")
  min_index=1
  q1_index=$(( (25 * count + 99) / 100 ))
  median_index=$(( (50 * count + 99) / 100 ))
  q3_index=$(( (75 * count + 99) / 100 ))
  max_index=${count}
  read -r min q1 median q3 max < <(
    sort -n "${values_file}" | awk -v min_i="${min_index}" -v q1_i="${q1_index}" -v med_i="${median_index}" -v q3_i="${q3_index}" -v max_i="${max_index}" '
      NR==min_i { min=$1 }
      NR==q1_i { q1=$1 }
      NR==med_i { med=$1 }
      NR==q3_i { q3=$1 }
      NR==max_i { max=$1 }
      END { printf "%s %s %s %s %s\n", min, q1, med, q3, max }
    '
  )
  avg=$(awk '{s+=$1} END {if (NR>0) printf "%.0f", s/NR; else print "na"}' "${values_file}")
  echo "${min} ${q1} ${median} ${q3} ${max} ${avg} ${count}"
}

to_epoch_ms() {
  local ts="$1"
  if [[ -z "${ts}" || "${ts}" == "null" ]]; then
    echo ""
    return 0
  fi
  date -d "${ts}" +%s%3N 2>/dev/null || echo ""
}

append_metric_to_run_log() {
  local run_log_file="$1"
  local metric_msg="$2"
  local ts metric_line
  [[ -z "${run_log_file}" || ! -f "${run_log_file}" ]] && return 0

  ts=$(date +"%Y-%m-%d %H:%M:%S")
  metric_line="time=\"${ts}\" level=info msg=\"${metric_msg}\" file=\"run_new_bookinfo.sh:metrics\""

  if grep -q 'Finished execution with UUID:' "${run_log_file}"; then
    awk -v ins="${metric_line}" '
      /Finished execution with UUID:/ && !done { print ins; done=1 }
      { print }
    ' "${run_log_file}" > "${run_log_file}.tmp" && mv "${run_log_file}.tmp" "${run_log_file}"
  else
    echo "${metric_line}" >> "${run_log_file}"
  fi
}

log_pod_distribution_by_node() {
  local ns="$1"
  local experiment_desc="$2"
  local run_id="$3"

  local master_nodes_file worker_nodes_file pods_file
  master_nodes_file=$(mktemp)
  worker_nodes_file=$(mktemp)
  pods_file=$(mktemp)

  kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.labels.node-role\.kubernetes\.io/master}{"|"}{.metadata.labels.node-role\.kubernetes\.io/control-plane}{"\n"}{end}' \
    2>/dev/null | awk -F'|' '
      {
        name=$1
        is_master=($2 != "" || $3 != "")
        if (is_master) print name > "'"${master_nodes_file}"'"
        else print name > "'"${worker_nodes_file}"'"
      }
    ' || true

  kubectl get pods -n "${ns}" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' \
    > "${pods_file}" 2>/dev/null || true

  local ordered_nodes=()
  while IFS= read -r n; do
    [[ -n "${n}" ]] && ordered_nodes+=("${n}")
  done < <(sort -u "${master_nodes_file}" 2>/dev/null || true)
  while IFS= read -r n; do
    [[ -n "${n}" ]] && ordered_nodes+=("${n}")
  done < <(sort -u "${worker_nodes_file}" 2>/dev/null || true)

  if [[ ${#ordered_nodes[@]} -eq 0 ]]; then
    rm -f "${master_nodes_file}" "${worker_nodes_file}" "${pods_file}"
    return 0
  fi

  local node_labels="" node_counts="" sep=""
  local node count
  for node in "${ordered_nodes[@]}"; do
    count=$(awk -v node="${node}" '$0 == node { c++ } END { print c + 0 }' "${pods_file}")
    node_labels="${node_labels}${sep}${node}"
    node_counts="${node_counts}${sep}${count}"
    sep=","
  done

  echo "PodPlacement run=${run_id} ${experiment_desc} ns=${ns} nodes=(${node_labels}) counts=(${node_counts})" | tee -a "${SUMMARY_FILE}" >/dev/null

  rm -f "${master_nodes_file}" "${worker_nodes_file}" "${pods_file}"
}

log_worker_node_resource_usage() {
  local experiment_desc="$1"
  local run_id="$2"
  local run_log_file="$3"
  local nodes_top_file
  nodes_top_file=$(mktemp)

  if ! kubectl top nodes --no-headers > "${nodes_top_file}" 2>/dev/null; then
    echo "WorkerNodeResourceUsage run=${run_id} ${experiment_desc} status=metrics_unavailable" | tee -a "${SUMMARY_FILE}" >/dev/null
    append_metric_to_run_log "${run_log_file}" "${BASE_NS}: WorkerNodeResourceUsage status=metrics_unavailable"
    rm -f "${nodes_top_file}"
    return 0
  fi

  while read -r node cpu mem; do
    [[ -z "${node}" ]] && continue
    if kubectl get node "${node}" -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/master}{.metadata.labels.node-role\.kubernetes\.io/control-plane}' 2>/dev/null | grep -q .; then
      continue
    fi
    echo "WorkerNodeResourceUsage run=${run_id} ${experiment_desc} node=${node} cpu=${cpu} mem=${mem}" | tee -a "${SUMMARY_FILE}" >/dev/null
    append_metric_to_run_log "${run_log_file}" "${BASE_NS}: WorkerNodeResourceUsage node=${node} cpu=${cpu} mem=${mem}"
  done < "${nodes_top_file}"

  rm -f "${nodes_top_file}"
}

measure_delete_time() {
  local ns="${BASE_NS}"
  local experiment_desc="$1"
  local run_id="$2"

  local start_ts_ms end_ts_ms duration_ms sec ms_rem duration
  start_ts_ms=$(date +%s%3N)

  kubectl delete codecoapp -n "${ns}" --all --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete deploy,svc,pod,channels,assignmentplans -n "${ns}" --all --ignore-not-found=true >/dev/null 2>&1 || true

  while true; do
    local remaining
    remaining=$(kubectl get pods,deploy,svc,codecoapp,channels,assignmentplans -n "${ns}" --no-headers 2>/dev/null | wc -l || echo 0)
    [[ "${remaining}" -eq 0 ]] && break
    sleep 0.5
  done

  end_ts_ms=$(date +%s%3N)
  duration_ms=$((end_ts_ms - start_ts_ms))
  sec=$((duration_ms / 1000))
  ms_rem=$((duration_ms % 1000))
  duration=$(printf "%d.%03d" "${sec}" "${ms_rem}")

  echo "DeleteDurationSeconds run=${run_id} ${experiment_desc} duration=${duration}s" | tee -a "${SUMMARY_FILE}" >/dev/null

   kubectl delete namespace "${ns}" --ignore-not-found=true >/dev/null 2>&1 || true

  while kubectl get namespace "${ns}" >/dev/null 2>&1; do
    sleep 1
  done
}

# sample resource usage periodically for the entire namespace lifetime
measure_resource_usage_periodic() {
  local experiment_desc="$1"
  local run_id="$2"
  local run_log_file="$3"
  local ns="${BASE_NS}"
  local interval=${WAIT_POLL_SECONDS}

  local total_cpu=0 total_mem=0 total_net_rx=0 total_net_tx=0 samples=0
  local cpu_total_m mem_total_mi running_pods net_rx_total net_tx_total net_status net_ok_count

  snapshot_usage() {
    local ns="$1"
    local running_pods_file top_file top_line
    cpu_total_m=0 mem_total_mi=0 running_pods=0
    net_rx_total=0 net_tx_total=0 net_status="unavailable"
    net_ok_count=0

    running_pods_file=$(mktemp)
    top_file=$(mktemp)

    kubectl get pods -n "${ns}" --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
      > "${running_pods_file}" 2>/dev/null || true
    running_pods=$(wc -l < "${running_pods_file}" | tr -d ' ')

    if kubectl top pod -n "${ns}" --no-headers >/dev/null 2>&1; then
      kubectl top pod -n "${ns}" --no-headers > "${top_file}" 2>/dev/null || true
      top_line="$([
        awk '
          function cpu_to_m(v) {
            if (v ~ /m$/) { sub(/m$/, "", v); return v + 0 }
            return (v + 0) * 1000
          }
          function mem_to_mi(v) {
            if (v ~ /Ki$/) { sub(/Ki$/, "", v); return (v + 0) / 1024 }
            if (v ~ /Mi$/) { sub(/Mi$/, "", v); return v + 0 }
            if (v ~ /Gi$/) { sub(/Gi$/, "", v); return (v + 0) * 1024 }
            return v + 0
          }
          NR == FNR { running[$1]=1; next }
          ($1 in running) {
            cpu_sum += cpu_to_m($2)
            mem_sum += mem_to_mi($3)
            n++
          }
          END {
            if (n == 0) {
              print "0 0 0"
            } else {
              printf "%.0f %.0f %d\n", cpu_sum, mem_sum, n
            }
          }
        ' "${running_pods_file}" "${top_file}"
      )]"
      read -r cpu_total_m mem_total_mi _top_samples <<< "${top_line}"
    fi

    if [[ "${running_pods}" -gt 0 ]]; then
      local rx_sum=0 tx_sum=0 rx tx pod
      while read -r pod; do
        [[ -z "${pod}" ]] && continue
        rx=$(kubectl exec -n "${ns}" "${pod}" -- cat /sys/class/net/eth0/statistics/rx_bytes 2>/dev/null || true)
        tx=$(kubectl exec -n "${ns}" "${pod}" -- cat /sys/class/net/eth0/statistics/tx_bytes 2>/dev/null || true)
        if [[ "${rx}" =~ ^[0-9]+$ && "${tx}" =~ ^[0-9]+$ ]]; then
          rx_sum=$((rx_sum + rx))
          tx_sum=$((tx_sum + tx))
          net_ok_count=$((net_ok_count + 1))
        fi
      done < "${running_pods_file}"

      if [[ "${net_ok_count}" -gt 0 ]]; then
        net_rx_total="${rx_sum}"
        net_tx_total="${tx_sum}"
        net_status="ok"
      fi
    fi

    rm -f "${running_pods_file}" "${top_file}"
  }

  while kubectl get namespace "${ns}" >/dev/null 2>&1; do
    snapshot_usage "${ns}"
    total_cpu=$((total_cpu + cpu_total_m))
    total_mem=$((total_mem + mem_total_mi))
    total_net_rx=$((total_net_rx + net_rx_total))
    total_net_tx=$((total_net_tx + net_tx_total))
    samples=$((samples + 1))
    sleep "${interval}"
  done

  local avg_cpu=0 avg_mem=0
  if [[ ${samples} -gt 0 ]]; then
    avg_cpu=$((total_cpu / samples))
    avg_mem=$((total_mem / samples))
  fi

  echo "ResourceUsage run=${run_id} ${experiment_desc} samples=${samples} avg_cpu_total_m=${avg_cpu} avg_mem_total_mi=${avg_mem} net_rx_bytes_total=${total_net_rx} net_tx_bytes_total=${total_net_tx} net_status=${net_status} net_pods_sampled=${net_ok_count}" | tee -a "${SUMMARY_FILE}" >/dev/null
  append_metric_to_run_log "${run_log_file}" "${ns}: ResourceUsage samples=${samples} avg_cpu_total_m=${avg_cpu} avg_mem_total_mi=${avg_mem} net_rx_bytes_total=${total_net_rx} net_tx_bytes_total=${total_net_tx} net_status=${net_status} net_pods_sampled=${net_ok_count}"
}

measure_resource_usage() {
  local experiment_desc="$1"
  local run_id="$2"
  local run_log_file="$3"
  local creation_anchor_ts="${4:-}"
  local ns="${BASE_NS}"
  local running_pods_file top_file top_line
  # initialize to zero so that we always log numeric values rather than "na"
  local cpu_total_m=0 mem_total_mi=0 running_pods=0
  local net_rx_total=0 net_tx_total=0 net_status="unavailable"
  local net_ok_count=0
  local deployment_duration_s="na"

  if [[ -n "${creation_anchor_ts}" && "${creation_anchor_ts}" =~ ^[0-9]+$ ]]; then
    deployment_duration_s=$(( $(date +%s) - creation_anchor_ts ))
  fi

  running_pods_file=$(mktemp)
  top_file=$(mktemp)

  kubectl get pods -n "${ns}" --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
    > "${running_pods_file}" 2>/dev/null || true
  running_pods=$(wc -l < "${running_pods_file}" | tr -d ' ')

  if kubectl top pod -n "${ns}" --no-headers >/dev/null 2>&1; then
    kubectl top pod -n "${ns}" --no-headers > "${top_file}" 2>/dev/null || true
    top_line="$(
      awk '
        function cpu_to_m(v) {
          if (v ~ /m$/) { sub(/m$/, "", v); return v + 0 }
          return (v + 0) * 1000
        }
        function mem_to_mi(v) {
          if (v ~ /Ki$/) { sub(/Ki$/, "", v); return (v + 0) / 1024 }
          if (v ~ /Mi$/) { sub(/Mi$/, "", v); return v + 0 }
          if (v ~ /Gi$/) { sub(/Gi$/, "", v); return (v + 0) * 1024 }
          return v + 0
        }
        NR == FNR { running[$1]=1; next }
        ($1 in running) {
          cpu_sum += cpu_to_m($2)
          mem_sum += mem_to_mi($3)
          n++
        }
        END {
          if (n == 0) {
            # no running pods sampled by top
            print "0 0 0"
          } else {
            printf "%.0f %.0f %d\n", cpu_sum, mem_sum, n
          }
        }
      ' "${running_pods_file}" "${top_file}"
    )"
    read -r cpu_total_m mem_total_mi _top_samples <<< "${top_line}"
  fi

  if [[ "${running_pods}" -gt 0 ]]; then
    local rx_sum=0 tx_sum=0 rx tx pod
    while read -r pod; do
      [[ -z "${pod}" ]] && continue
      rx=$(kubectl exec -n "${ns}" "${pod}" -- cat /sys/class/net/eth0/statistics/rx_bytes 2>/dev/null || true)
      tx=$(kubectl exec -n "${ns}" "${pod}" -- cat /sys/class/net/eth0/statistics/tx_bytes 2>/dev/null || true)
      if [[ "${rx}" =~ ^[0-9]+$ && "${tx}" =~ ^[0-9]+$ ]]; then
        rx_sum=$((rx_sum + rx))
        tx_sum=$((tx_sum + tx))
        net_ok_count=$((net_ok_count + 1))
      fi
    done < "${running_pods_file}"

    if [[ "${net_ok_count}" -gt 0 ]]; then
      net_rx_total="${rx_sum}"
      net_tx_total="${tx_sum}"
      net_status="ok"
    fi
  fi

  rm -f "${running_pods_file}" "${top_file}"

  echo "ResourceUsage run=${run_id} ${experiment_desc} deployment_duration_s=${deployment_duration_s} runningPods=${running_pods} cpu_total_m=${cpu_total_m} mem_total_mi=${mem_total_mi} net_rx_bytes_total=${net_rx_total} net_tx_bytes_total=${net_tx_total} net_status=${net_status} net_pods_sampled=${net_ok_count}" | tee -a "${SUMMARY_FILE}" >/dev/null
  append_metric_to_run_log "${run_log_file}" "${ns}: ResourceUsage deployment_duration_s=${deployment_duration_s} runningPods=${running_pods} cpu_total_m=${cpu_total_m} mem_total_mi=${mem_total_mi} net_rx_bytes_total=${net_rx_total} net_tx_bytes_total=${net_tx_total} net_status=${net_status} net_pods_sampled=${net_ok_count}"
}

wait_for_creation_readiness() {
  local ns="${BASE_NS}"
  local experiment_desc="$1"
  local run_id="$2"
  local run_log_file="$3"
  local creation_anchor_ts="$4"

  local expected_pods expected_containers
  expected_pods="${PODS_NUMBER}"
  expected_containers=0

  local started_at now elapsed since_anchor
  local observed_ready_seconds="" pod_scheduled_seconds="" container_ready_seconds=""
  local ready_values_file scheduled_values_file ready_stats scheduled_stats
  local ready_epoch_ms scheduled_epoch_ms ready_delta_ms scheduled_delta_ms
  local cr_min cr_q1 cr_median cr_q3 cr_max cr_avg cr_count
  local ps_min ps_q1 ps_median ps_q3 ps_max ps_avg ps_count
  started_at=$(date +%s)
  if [[ -z "${creation_anchor_ts}" ]]; then
    creation_anchor_ts="${started_at}"
  fi

  while true; do
    local observed_pods ready_pods observed_containers ready_containers scheduled_pods

    observed_pods=$(kubectl get pods -n "${ns}" --no-headers 2>/dev/null | wc -l || echo 0)
    ready_pods=$(kubectl get pods -n "${ns}" --no-headers 2>/dev/null | awk '
      {
        split($2, a, "/")
        if (a[1] == a[2]) c++
      }
      END {print c + 0}
    ' || echo 0)
    observed_containers=$(kubectl get pods -n "${ns}" -o jsonpath='{range .items[*]}{.spec.containers[*].name}{"\n"}{end}' 2>/dev/null | awk '{c += NF} END {print c + 0}' || echo 0)
    ready_containers=$(kubectl get pods -n "${ns}" -o jsonpath='{range .items[*]}{.status.containerStatuses[*].ready}{"\n"}{end}' 2>/dev/null | tr ' ' '\n' | grep -c '^true$' || true)
    [[ -z "${ready_containers}" ]] && ready_containers=0
    expected_containers="${observed_containers}"
    scheduled_pods=$(kubectl get pods -n "${ns}" -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="PodScheduled")].status}{"\n"}{end}' 2>/dev/null | awk '
      {
        for (i = 1; i <= NF; i++) if ($i == "True" || $i == "true") c++
      }
      END {print c + 0}
    ' || echo 0)
    now=$(date +%s)
    since_anchor=$((now - creation_anchor_ts))

    if [[ -z "${observed_ready_seconds}" && "${observed_pods}" -ge "${expected_pods}" ]]; then
      observed_ready_seconds="${since_anchor}"
    fi
    if [[ -z "${pod_scheduled_seconds}" && "${scheduled_pods}" -ge "${expected_pods}" ]]; then
      pod_scheduled_seconds="${since_anchor}"
    fi
    if [[ -z "${container_ready_seconds}" && "${ready_containers}" -ge "${expected_containers}" ]]; then
      container_ready_seconds="${since_anchor}"
    fi

    if [[ "${ready_pods}" -ge "${expected_pods}" && "${ready_containers}" -ge "${expected_containers}" ]]; then
      ready_values_file=$(mktemp)
      scheduled_values_file=$(mktemp)
      while IFS='|' read -r _pod_name ready_ts scheduled_ts; do
        [[ -n "${ready_ts}" ]] && ready_epoch_ms=$(to_epoch_ms "${ready_ts}") || ready_epoch_ms=""
        [[ -n "${scheduled_ts}" ]] && scheduled_epoch_ms=$(to_epoch_ms "${scheduled_ts}") || scheduled_epoch_ms=""
        if [[ -n "${ready_epoch_ms}" ]]; then
          ready_delta_ms=$((ready_epoch_ms - creation_anchor_ts * 1000))
          if [[ "${ready_delta_ms}" -ge 0 ]]; then
            echo "${ready_delta_ms}" >> "${ready_values_file}"
          fi
        fi
        if [[ -n "${scheduled_epoch_ms}" ]]; then
          scheduled_delta_ms=$((scheduled_epoch_ms - creation_anchor_ts * 1000))
          if [[ "${scheduled_delta_ms}" -ge 0 ]]; then
            echo "${scheduled_delta_ms}" >> "${scheduled_values_file}"
          fi
        fi
      done < <(kubectl get pods -n "${ns}" -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.conditions[?(@.type=="Ready")].lastTransitionTime}{"|"}{.status.conditions[?(@.type=="PodScheduled")].lastTransitionTime}{"\n"}{end}' 2>/dev/null || true)

      ready_stats=$(calc_stats_from_file_ms "${ready_values_file}")
      read -r cr_min cr_q1 cr_median cr_q3 cr_max cr_avg cr_count <<< "${ready_stats}"
      scheduled_stats=$(calc_stats_from_file_ms "${scheduled_values_file}")
      read -r ps_min ps_q1 ps_median ps_q3 ps_max ps_avg ps_count <<< "${scheduled_stats}"
      rm -f "${ready_values_file}" "${scheduled_values_file}"

      {
        echo "CreateReady run=${run_id} ${experiment_desc} expectedPods=${expected_pods} observedPods=${observed_pods} readyPods=${ready_pods} expectedContainers=${expected_containers} observedContainers=${observed_containers} readyContainers=${ready_containers} pod_ready=${ready_pods} container_ready=${ready_containers}"
      } | tee -a "${CREATION_LOG}" >/dev/null
      echo "PodScheduledTime run=${run_id} ${experiment_desc} observed=${pod_scheduled_seconds}s min=${ps_min}ms q1=${ps_q1}ms median=${ps_median}ms q3=${ps_q3}ms max=${ps_max}ms avg=${ps_avg}ms samples=${ps_count} expectedPods=${expected_pods} scheduledPods=${scheduled_pods}" | tee -a "${SUMMARY_FILE}" >/dev/null
      echo "ContainerReadyTime run=${run_id} ${experiment_desc} observed=${container_ready_seconds}s min=${cr_min}ms q1=${cr_q1}ms median=${cr_median}ms q3=${cr_q3}ms max=${cr_max}ms avg=${cr_avg}ms samples=${cr_count} expectedContainers=${expected_containers} readyContainers=${ready_containers}" | tee -a "${SUMMARY_FILE}" >/dev/null
      log_pod_distribution_by_node "${ns}" "${experiment_desc}" "${run_id}"
      append_metric_to_run_log "${run_log_file}" "${ns}: PodScheduledTime observed=${pod_scheduled_seconds}s min=${ps_min}ms q1=${ps_q1}ms median=${ps_median}ms q3=${ps_q3}ms max=${ps_max}ms avg=${ps_avg}ms samples=${ps_count} expectedPods=${expected_pods} scheduledPods=${scheduled_pods}"
      append_metric_to_run_log "${run_log_file}" "${ns}: ContainerReadyTime observed=${container_ready_seconds}s min=${cr_min}ms q1=${cr_q1}ms median=${cr_median}ms q3=${cr_q3}ms max=${cr_max}ms avg=${cr_avg}ms samples=${cr_count} expectedContainers=${expected_containers} readyContainers=${ready_containers}"
      return 0
    fi

    elapsed=$((now - started_at))
    if [[ "${elapsed}" -ge "${WAIT_CREATE_TIMEOUT}" ]]; then
      {
        echo "CreateTimeout run=${run_id} ${experiment_desc} expectedPods=${expected_pods} observedPods=${observed_pods} readyPods=${ready_pods} expectedContainers=${expected_containers} observedContainers=${observed_containers} readyContainers=${ready_containers} pod_ready=${ready_pods} container_ready=${ready_containers}"
        echo "Resources snapshot (namespace=${ns}):"
        kubectl get codecoapp,pods,deploy,svc -n "${ns}" --ignore-not-found=true || true
        echo "Recent events (namespace=${ns}):"
        kubectl get events -n "${ns}" --sort-by=.lastTimestamp 2>/dev/null | tail -n 20 || true
        echo
      } >> "${CREATION_LOG}"
      return 1
    fi

    sleep "${WAIT_POLL_SECONDS}"
  done
}

init_logs

if ls kubelet-density-heavy_bookinfo_*.log >/dev/null 2>&1; then
  counter=$(ls kubelet-density-heavy_bookinfo_*.log | grep -o '[0-9]*\.log' | grep -o '[0-9]*' | sort -n | tail -1)
  counter=$((counter + 1))
else
  counter=1
fi

for (( run=1; run<=ITERATIONS; run++ )); do
  echo "============================================================"
  echo "Starting run ${run} of ${ITERATIONS}"
  echo "Using template file: ${TEMPLATE_FILE}"
  echo "Namespace: ${BASE_NS}"
  echo "Scheduler: ${SCHEDULER_NAME}"
  echo "Object template: ${OBJECT_FILE}"
  echo "============================================================"

  for experiment in "${experiments[@]}"; do
    echo "------------------------------------------------------------"
    echo "Running experiment: ${experiment}"
    echo "------------------------------------------------------------"

    kubectl delete namespace "${BASE_NS}" --ignore-not-found=true >/dev/null 2>&1 || true
    while kubectl get namespace "${BASE_NS}" >/dev/null 2>&1; do
      sleep 1
    done

    while kubectl get events "${BASE_NS}" >/dev/null 2>&1; do
      sleep 1
    done


    echo "creation is going to be started"
    kubectl create namespace "${BASE_NS}" >/dev/null

    eval "${experiment}"

    export JOB_ITERATIONS="${jobIterations}"
    export QPS="${qps}"
    export BURST="${burst}"
    export BOOKINFO_REPLICAS="${bookinfo_replicas}"
    export NAMESPACE="${BASE_NS}"
    export OBJECT_TEMPLATE="${OBJECT_FILE}"
    export SCHEDULER_NAME="${SCHEDULER_NAME}"


    envsubst < "${TEMPLATE_FILE}" > kubelet-density-heavy.yml

    if grep -q '^[[:space:]]*maxWaitTimeout:' kubelet-density-heavy.yml; then
      sed -i -E "s|^([[:space:]]*maxWaitTimeout:).*|\\1 ${MAX_WAIT_TIMEOUT}|" kubelet-density-heavy.yml
    else
      sed -i -E "/^[[:space:]]*qps:/a\\  maxWaitTimeout: ${MAX_WAIT_TIMEOUT}" kubelet-density-heavy.yml
    fi

    creation_started_at=$(date +%s)
    kube-burner init -c kubelet-density-heavy.yml

    if ls kube-burner-*.log >/dev/null 2>&1; then
      log_file=$(ls -t kube-burner-*.log | head -n 1)
      new_log_file="kubelet-density-heavy_bookinfo_${SCHEDULER_NAME}_jobIterations${jobIterations}_qps${qps}_burst${burst}_replicas${bookinfo_replicas}_${counter}.log"
      mv "${log_file}" "${new_log_file}"
    else
      new_log_file=""
    fi

    write_experiment_header "${experiment}" "${run}" "${new_log_file}"
    creation_rc=0
    wait_for_creation_readiness "${experiment}" "${run}" "${new_log_file}" "${creation_started_at}" || creation_rc=$?
    echo "............... 30sec..................."

    sleep 30
    log_worker_node_resource_usage "${experiment}" "${run}" "${new_log_file}"
    
    measure_resource_usage "${experiment}" "${run}" "${new_log_file}" "${creation_started_at}"
    measure_delete_time "${experiment}" "${run}"

    if [[ "${creation_rc}" -ne 0 ]]; then
      echo "$(date --iso-8601=seconds) ERROR: creation readiness timeout run=${run} experiment='${experiment}'" | tee -a "${RUN_STATUS_LOG}" >&2
      exit 1
    fi
    echo "$(date --iso-8601=seconds) OK: run=${run} experiment='${experiment}'" >> "${RUN_STATUS_LOG}"

    counter=$((counter + 1))
    echo "Sleeping ${INTER_EXPERIMENT_SLEEP}s before next experiment..."
    sleep "${INTER_EXPERIMENT_SLEEP}"
  done
done

echo "All Bookinfo CodecoApp experiments completed."

# run status
# started: 2026-05-13T10:14:55+02:00
# scheduler: default-scheduler
# max_wait_timeout: 3m


