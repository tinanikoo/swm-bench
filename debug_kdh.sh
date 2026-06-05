#!/usr/bin/env bash

set -uo pipefail

APP_NS="kdh"
APPGROUP_NS="kubelet-density-heavy"
CODECO_TEST_NS="codeco-test"
SWM_NS="he-codeco-swm"
ACM_NS="he-codeco-acm"
KUBE_NS="kube-system"

APPGROUP_NAME="acm-applicationgroup"
ASSIGNMENTPLAN_NAME="acm-applicationgroup-assignment-plan"

K="${K:-kubectl}"
OUT="output.txt"

: > "$OUT"

run_cmd() {
    local title="$1"
    shift

    {
        echo
        echo "============================================================"
        echo "$title"
        echo "============================================================"
        echo "+ $*"
    } | tee -a "$OUT"

    "$@" 2>&1 | tee -a "$OUT" || true
}

run_cmd_shell() {
    local title="$1"
    local cmd="$2"

    {
        echo
        echo "============================================================"
        echo "$title"
        echo "============================================================"
        echo "+ $cmd"
    } | tee -a "$OUT"

    bash -c "$cmd" 2>&1 | tee -a "$OUT" || true
}

latest_match() {
    local pattern="$1"
    grep -Ein "$pattern" "$ANALYSIS_FILE" 2>/dev/null | tail -1 || true
}

###############################################################################
# PRE-CHECKS: APPLICATIONGROUP / CRDS / NODES
###############################################################################

run_cmd "ApplicationGroup - wide" \
    "$K" -n "$APPGROUP_NS" get applicationgroup "$APPGROUP_NAME" -o wide

run_cmd "ApplicationGroup - describe" \
    "$K" -n "$APPGROUP_NS" describe applicationgroup "$APPGROUP_NAME"

run_cmd_shell "CRD check - assignmentplan" \
    "$K get crd | grep -i assignmentplan || true"

run_cmd_shell "CRD check - qos" \
    "$K get crd | grep -i qos || true"

run_cmd "Nodes - wide" \
    "$K" get nodes -o wide

for node in $($K get nodes --no-headers -o custom-columns=":metadata.name" 2>/dev/null); do
    run_cmd_shell "Node pressure/capacity summary: $node" \
        "$K describe node $node | egrep -i 'Allocatable:|Capacity:|pods|Non-terminated Pods|DiskPressure|MemoryPressure|PIDPressure' -n || true"
done

###############################################################################
# ASSIGNMENTPLAN CHECKS
###############################################################################

run_cmd "AssignmentPlan in codeco-test" \
    "$K" -n "$CODECO_TEST_NS" get assignmentplan "$ASSIGNMENTPLAN_NAME"

run_cmd "AssignmentPlan in kdh - yaml" \
    "$K" -n "$APP_NS" get assignmentplan "$ASSIGNMENTPLAN_NAME" -o yaml

run_cmd_shell "AssignmentPlan status.actions" \
    "$K -n $APP_NS get assignmentplan $ASSIGNMENTPLAN_NAME -o jsonpath='{.status.actions}' 2>/dev/null || true; echo"

run_cmd_shell "AssignmentPlan status.actionInfo done/error" \
    "$K -n $APP_NS get assignmentplan $ASSIGNMENTPLAN_NAME -o jsonpath='{range .status.actionInfo[*]}action={.action}{\" done=\"}{.done}{\" error=\"}{.error}{\"\\n\"}{end}' 2>/dev/null || true"

###############################################################################
# KDH / APPLICATION
###############################################################################

run_cmd "CODECO Apps" \
    "$K" get codecoapp -n "$APP_NS"

run_cmd "Application Pods" \
    "$K" get pods -n "$APP_NS" -o wide

for pod in $($K get pods -n "$APP_NS" --no-headers -o custom-columns=":metadata.name" 2>/dev/null); do
    run_cmd "Describe Application Pod: $pod" \
        "$K" describe pod "$pod" -n "$APP_NS"
done

run_cmd "Services" \
    "$K" get svc -n "$APP_NS" -o wide

run_cmd "Channels" \
    "$K" get channels -n "$APP_NS" -o wide

run_cmd "AssignmentPlans" \
    "$K" get assignmentplans -n "$APP_NS"

run_cmd "Events" \
    "$K" get events -n "$APP_NS" --sort-by=.lastTimestamp

###############################################################################
# SWM
###############################################################################

run_cmd "SWM Pods" \
    "$K" get pods -n "$SWM_NS" -o wide

for pod in $($K get pods -n "$SWM_NS" --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep -i solver || true); do
    run_cmd "Solver Logs: $pod" \
        "$K" logs "$pod" -n "$SWM_NS" --all-containers=true --tail=-1
done

###############################################################################
# ACM
###############################################################################

run_cmd "ACM Pods" \
    "$K" get pods -n "$ACM_NS" -o wide

run_cmd "ACM controller deployment previous logs" \
    "$K" logs deploy/acm-operator-controller-manager -n "$ACM_NS" --previous --tail=200

for pod in $($K get pods -n "$ACM_NS" --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep -Ei "acm|controller" || true); do
    run_cmd "ACM Controller Logs: $pod" \
        "$K" logs "$pod" -n "$ACM_NS" --all-containers=true --tail=-1
done

###############################################################################
# MULTUS
###############################################################################

run_cmd_shell "Multus Pods" \
    "$K get pods -n $KUBE_NS -o wide | grep -i mu || true"

for pod in $($K get pods -n "$KUBE_NS" --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep -Ei "multus|mu" || true); do
    run_cmd_shell "Multus Filtered Logs: $pod" \
        "$K logs $pod -n $KUBE_NS --all-containers=true --since=30m --tail=300 2>&1 | grep -Ei 'error|err|warn|failed|failure|crash|restart|backoff|oom|too many open files|GetPod failed|cached delegates|cannot properly delete|AddedInterface|ADD finished|DEL finished' || true"
done

###############################################################################
# ANALYSIS
###############################################################################

ANALYSIS_FILE="/tmp/codeco_debug_analysis_$$.txt"
cp "$OUT" "$ANALYSIS_FILE"

{
    echo
    echo "============================================================"
    echo "Analysis Section"
    echo "============================================================"
    echo
    echo "[analysis_section]"
    echo "Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo

    echo "=== OK indicators ==="
    grep -Ein "Successfully assigned|AddedInterface|Created container|Started container|Running|Ready|ADD finished" "$ANALYSIS_FILE" || true

    echo
    echo "=== Warnings ==="
    grep -Ein "warn|warning" "$ANALYSIS_FILE" || true

    echo
    echo "=== Errors ==="
    grep -Ein "error|err|failed|failure" "$ANALYSIS_FILE" || true

    echo
    echo "=== Reconciler / Solver ==="
    grep -Ein "solver|reconciler|reconcile|placement-attempt|placement-attempts-exhausted|exhausted solver retries" "$ANALYSIS_FILE" || true

    echo
    echo "=== Scheduling feasibility issues ==="
    grep -Ein "not feasible|not feasbale|infeasible|no feasible|cannot schedule|failed scheduling|unschedulable" "$ANALYSIS_FILE" || true

    echo
    echo "=== Exhausted retries ==="
    grep -Ein "exhausted|exhusted" "$ANALYSIS_FILE" || true

    echo
    echo "=== Multus issues ==="
    grep -Ein "multus|too many open files|GetPod failed|cached delegates|cannot properly delete|failed to create pod sandbox|networkPlugin|CNI|CrashLoopBackOff|BackOff|OOMKilled|restart|restarted" "$ANALYSIS_FILE" || true

    echo
    echo "=== AssignmentPlan action issues ==="
    grep -Ein "status.actions|status.actionInfo|done=false|error=|error:" "$ANALYSIS_FILE" || true

    echo
    echo "=== Node pressure / capacity issues ==="
    grep -Ein "DiskPressure.*True|MemoryPressure.*True|PIDPressure.*True|OutOfpods|Insufficient|Allocatable|Non-terminated Pods" "$ANALYSIS_FILE" || true

    echo
    echo "=== Pod problems ==="
    grep -Ein "ContainerCreating|Pending|Terminating|NotReady|Unknown|ImagePullBackOff|ErrImagePull|CrashLoopBackOff|BackOff|OOMKilled" "$ANALYSIS_FILE" || true

    echo
    echo "=== Quick health summary ==="
    echo "Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo

    ok_count=0
    warn_count=0
    fail_count=0

    declare -a OKS
    declare -a WARNS
    declare -a FAILS

    appgroup_ready_line=$(latest_match "Ready")
    if [[ -n "$appgroup_ready_line" ]]; then
        OKS+=("ApplicationGroup readiness/status found. Latest: $appgroup_ready_line")
        ((ok_count++))
    else
        WARNS+=("ApplicationGroup readiness/status not clearly found.")
        ((warn_count++))
    fi

    crd_assignment_line=$(latest_match "assignmentplan")
    if [[ -n "$crd_assignment_line" ]]; then
        OKS+=("AssignmentPlan CRD appears present. Latest: $crd_assignment_line")
        ((ok_count++))
    else
        FAILS+=("AssignmentPlan CRD not found.")
        ((fail_count++))
    fi

    crd_qos_line=$(latest_match "qos")
    if [[ -n "$crd_qos_line" ]]; then
        OKS+=("QoS-related CRD appears present. Latest: $crd_qos_line")
        ((ok_count++))
    else
        WARNS+=("QoS-related CRD not clearly found.")
        ((warn_count++))
    fi

    scheduler_line=$(latest_match "Successfully assigned")
    if [[ -n "$scheduler_line" ]]; then
        OKS+=("Scheduler assigned at least one pod. Latest: $scheduler_line")
        ((ok_count++))
    else
        FAILS+=("No successful pod assignment detected.")
        ((fail_count++))
    fi

    multus_attach_line=$(latest_match "AddedInterface|ADD finished")
    if [[ -n "$multus_attach_line" ]]; then
        OKS+=("Multus/CNI attached at least one interface. Latest: $multus_attach_line")
        ((ok_count++))
    else
        FAILS+=("No successful Multus/CNI interface attachment detected.")
        ((fail_count++))
    fi

    container_start_line=$(latest_match "Started container")
    if [[ -n "$container_start_line" ]]; then
        OKS+=("At least one container started. Latest: $container_start_line")
        ((ok_count++))
    else
        FAILS+=("No container startup detected.")
        ((fail_count++))
    fi

    exhausted_line=$(latest_match "placement-attempts-exhausted|exhausted solver retries|exhusted")
    if [[ -n "$exhausted_line" ]]; then
        FAILS+=("Solver placement attempts were exhausted. Latest: $exhausted_line")
        ((fail_count++))
    else
        OKS+=("No exhausted solver retry message found.")
        ((ok_count++))
    fi

    infeasible_line=$(latest_match "not feasible|not feasbale|infeasible|no feasible|cannot schedule|unschedulable")
    if [[ -n "$infeasible_line" ]]; then
        FAILS+=("Scheduling feasibility problem detected. Latest: $infeasible_line")
        ((fail_count++))
    else
        OKS+=("No scheduling feasibility problem detected.")
        ((ok_count++))
    fi

    assignment_error_line=$(latest_match "error=.|error:|done=false")
    if [[ -n "$assignment_error_line" ]]; then
        FAILS+=("AssignmentPlan action error or unfinished action detected. Latest: $assignment_error_line")
        ((fail_count++))
    else
        OKS+=("No obvious AssignmentPlan action error detected.")
        ((ok_count++))
    fi

    pressure_line=$(latest_match "DiskPressure.*True|MemoryPressure.*True|PIDPressure.*True")
    if [[ -n "$pressure_line" ]]; then
        FAILS+=("Node pressure detected. Latest: $pressure_line")
        ((fail_count++))
    else
        OKS+=("No node DiskPressure/MemoryPressure/PIDPressure detected.")
        ((ok_count++))
    fi

    fd_line=$(latest_match "too many open files")
    if [[ -n "$fd_line" ]]; then
        FAILS+=("Multus/file-descriptor exhaustion detected. Latest: $fd_line")
        ((fail_count++))
    else
        OKS+=("No 'too many open files' issue detected.")
        ((ok_count++))
    fi

    cache_line=$(latest_match "GetPod failed|cached delegates|cannot properly delete")
    if [[ -n "$cache_line" ]]; then
        WARNS+=("Multus cleanup/delete cache issue detected. Latest: $cache_line")
        ((warn_count++))
    else
        OKS+=("No Multus cleanup/cache issue detected.")
        ((ok_count++))
    fi

    crash_line=$(latest_match "CrashLoopBackOff|BackOff|OOMKilled")
    if [[ -n "$crash_line" ]]; then
        FAILS+=("Crash/restart/OOM issue detected. Latest: $crash_line")
        ((fail_count++))
    else
        OKS+=("No CrashLoopBackOff/BackOff/OOMKilled issue detected.")
        ((ok_count++))
    fi

    terminating_line=$(latest_match "Terminating")
    if [[ -n "$terminating_line" ]]; then
        WARNS+=("Some pods are/were observed in Terminating state. Latest: $terminating_line")
        ((warn_count++))
    else
        OKS+=("No Terminating pods found.")
        ((ok_count++))
    fi

    echo "OK ($ok_count)"
    for x in "${OKS[@]}"; do
        echo "  [OK]   $x"
    done

    echo
    echo "WARN ($warn_count)"
    for x in "${WARNS[@]}"; do
        echo "  [WARN] $x"
    done

    echo
    echo "FAIL ($fail_count)"
    for x in "${FAILS[@]}"; do
        echo "  [FAIL] $x"
    done

    echo
    echo "TOTAL: OK=$ok_count WARN=$warn_count FAIL=$fail_count"

    echo
    echo "=== Multus restart suggestion ==="

    restart_reason=$(latest_match "too many open files|CrashLoopBackOff|BackOff|OOMKilled|failed to create pod sandbox")
    if [[ -n "$restart_reason" ]]; then
        echo "[ACTION] Multus may need restart."
        echo "Reason: $restart_reason"
        echo "Command:"
        echo "$K rollout restart ds -n $KUBE_NS kube-multus-ds"
    else
        echo "[OK] No strong reason to restart Multus based on collected logs."
    fi

} | tee -a "$OUT"

rm -f "$ANALYSIS_FILE"

echo
echo "Full report saved to: $OUT"
echo "To view analysis only:"
echo "sed -n '/\\[analysis_section\\]/,\$p' $OUT"