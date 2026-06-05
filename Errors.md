=== Quick health summary ===
Generated: 2026-06-05 13:01:39 CEST

OK (7)
  [OK]   ApplicationGroup readiness/status found. Latest: 33563:Already exists: Updating SWM app
  [OK]   AssignmentPlan CRD appears present. Latest: 175:+ kubectl get assignmentplans -n kdh
  [OK]   QoS-related CRD appears present. Latest: 34198:               "podName": "bookinfo-swmapp-17-qos-scheduler-reviews-v9",
  [OK]   Multus/CNI attached at least one interface. Latest: 34255:+ kubectl logs kube-multus-ds-vcxf9 -n kube-system --all-containers=true --since=5m --tail=300 2>&1 | grep -Ei 'error|err|warn|failed|failure|crash|restart|backoff|oom|too many open files|GetPod failed|cached delegates|cannot properly delete|AddedInterface|ADD finished|DEL finished' || true
  [OK]   No exhausted solver retry message found.
  [OK]   No scheduling feasibility problem detected.
  [OK]   No Terminating pods found.

WARN (1)
  [WARN] Multus cleanup/delete cache issue detected. Latest: 34255:+ kubectl logs kube-multus-ds-vcxf9 -n kube-system --all-containers=true --since=5m --tail=300 2>&1 | grep -Ei 'error|err|warn|failed|failure|crash|restart|backoff|oom|too many open files|GetPod failed|cached delegates|cannot properly delete|AddedInterface|ADD finished|DEL finished' || true

FAIL (6)
  [FAIL] No successful pod assignment detected.
  [FAIL] No container startup detected.
  [FAIL] AssignmentPlan action error or unfinished action detected. Latest: 146:+ kubectl -n kdh get assignmentplan acm-applicationgroup-assignment-plan -o jsonpath='{range .status.actionInfo[*]}action={.action}{" done="}{.done}{" error="}{.error}{"\n"}{end}' 2>/dev/null || true
  [FAIL] Node pressure detected. Latest: 115:+ kubectl describe node working5 | egrep -i 'Allocatable:|Capacity:|pods|Non-terminated Pods|DiskPressure|MemoryPressure|PIDPressure' -n || true
  [FAIL] Multus/file-descriptor exhaustion detected. Latest: 34255:+ kubectl logs kube-multus-ds-vcxf9 -n kube-system --all-containers=true --since=5m --tail=300 2>&1 | grep -Ei 'error|err|warn|failed|failure|crash|restart|backoff|oom|too many open files|GetPod failed|cached delegates|cannot properly delete|AddedInterface|ADD finished|DEL finished' || true
  [FAIL] Crash/restart/OOM issue detected. Latest: 34255:+ kubectl logs kube-multus-ds-vcxf9 -n kube-system --all-containers=true --since=5m --tail=300 2>&1 | grep -Ei 'error|err|warn|failed|failure|crash|restart|backoff|oom|too many open files|GetPod failed|cached delegates|cannot properly delete|AddedInterface|ADD finished|DEL finished' || true

TOTAL: OK=7 WARN=1 FAIL=6

=== Multus restart suggestion ===
