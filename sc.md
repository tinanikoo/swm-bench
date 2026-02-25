# CODECO  – All-in-One Debug & Experiment Guide

Target workload namespace: **kdh**  
Other relevant namespaces are explicitly stated where needed.

The order below reflects **how issues should be investigated in practice**.

---

## 0. Automated Log Collection (RECOMMENDED)

Purpose:  
Run a single script that captures **all relevant state and logs** into one file.
## Workload Pod Status (kdh)

Purpose:
Check whether application pods are Running, Pending, or CrashLooping.
```
kubectl get pods -n kdh -o wide
```
Show only problematic pods:
```
kubectl get pods -n kdh | grep -Ev 'Running|Completed'
```
## Scheduler Placement Verification

Purpose:
Verify which scheduler placed each pod (default vs QoS / CODECO).

All namespaces:
```
kubectl get pods -A \
  -o custom-columns='NAMESPACE:metadata.namespace,NAME:metadata.name,SCHEDULER:spec.schedulerName'
```
Only kdh:
```
kubectl get pods -n kdh \
  -o custom-columns='NAME:metadata.name,NODE:spec.nodeName,SCHEDULER:spec.schedulerName'
```
Watch live placement:
```
watch kubectl get pods -n kdh -o wide
```

## CODECO Custom Resources (Core Logic)

Purpose:
Inspect how CODECO models the application and its constraints.

### CodecoApp
```
kubectl get codecoapp -n kdh -o wide
kubectl describe codecoapp dummy-1 -n kdh
QoS Scheduler Application CR
kubectl get applications.qos-scheduler.siemens.com -n kdh dummy-3 -o yaml
```
## AssignmentPlan (CRITICAL)

Purpose:
Understand intended placement vs actual pod placement.
```
kubectl get assignmentplan -n kdh acm-applicationgroup-assignment-plan -o yaml
kubectl describe assignmentplan -n kdh acm-applicationgroup-assignment-plan
```
Optional (other namespaces):
```
kubectl -n codeco-test get assignmentplan acm-applicationgroup-assignment-plan
kubectl -n kdh get assignmentplan acm-applicationgroup-assignment-plan
```
## ApplicationGroup (Scheduler Input)

Purpose:
Inspect grouping, membership, and constraints used by the scheduler.
```
kubectl get applicationgroup -n kdh acm-applicationgroup -o wide
kubectl describe applicationgroup -n kdh acm-applicationgroup
```
## Events (Timeline of Failures)

Purpose:
```
Reveal scheduling failures, restarts, and hidden reconciliation issues.
```
kdh:
```
kubectl get events -n kdh --sort-by=.lastTimestamp
```
ACM:
```
kubectl get events -n he-codeco-acm --sort-by=.lastTimestamp
```
## ACM Operator & Scheduler Logs

Purpose:
Detect rejected placements, constraint violations, or reconciliation errors.

ACM operator:
```
kubectl logs -n he-codeco-acm deploy/acm-operator-controller-manager --tail=200
kubectl logs -n he-codeco-acm deploy/acm-operator-controller-manager --previous --tail=200
```
QoS scheduler:
```
kubectl logs qos-scheduler-8556897b4c-8fnbl -n kube-system
```
## Node Pressure & Capacity (Scheduling Constraints)

Purpose:
Check whether nodes reject pods due to memory, disk, or PID pressure.

Conditions (pressure signals)
```
kubectl describe node ip-10-0-132-49 | sed -n '/^Conditions:/,/^Addresses:/p'
kubectl describe node ip-10-0-136-130 | sed -n '/^Conditions:/,/^Addresses:/p'
kubectl describe node ip-10-0-141-230 | sed -n '/^Conditions:/,/^Addresses:/p'
```
Capacity / Allocatable
```
kubectl describe node ip-10-0-132-49 | sed -n '/^Capacity:/,/^Allocatable:/p'
kubectl describe node ip-10-0-132-49 | sed -n '/^Allocatable:/,/^System Info:/p'
```
## Multus Diagnostics (Networking Layer)

Purpose:
Detect OOMKills, inotify exhaustion, or CNI instability.
```
kubectl get pods -n kube-system | grep -i multus
kubectl describe pod -n kube-system kube-multus-ds-dshtd
```
Previous crash logs:
```
kubectl logs -n kube-system kube-multus-ds-dshtd \
  -c kube-multus --previous --tail=500
```
Error scan:
```
kubectl logs -n kube-system kube-multus-ds-dshtd \
  -c kube-multus --previous --tail=2000 \
  | grep -Ei 'oom|killed|error|fatal|panic|inotify|too many open files'
```
## NETMA / Secure Connectivity

Purpose:
Ensure network monitoring and topology components are healthy.
```
kubectl get pods -n he-codeco-netma -o wide
kubectl get netma-topology netma-sample -n he-codeco-netma -o yaml
```
## Local Template Sanity Checks

Purpose:
Validate application/service relationships before deployment.
```
grep -nE "appName:|otherService:" templates/perfapp-postgres-cam.yml
```
