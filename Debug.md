# CODECO / ACM / SWM Troubleshooting Guide

## Goal

This guide helps diagnose why an ApplicationGroup or CodecoApp is not deployed successfully.

Typical symptoms:

* Pods remain Pending
* Pods remain ContainerCreating
* No AssignmentPlan generated
* AssignmentPlan exists but actions are not completed
* Solver reports infeasible placement
* ACM controller does not react
* Multus networking issues
* Pods start and later fail

---

# Step 1 – Verify ApplicationGroup

Confirm the ApplicationGroup exists and inspect its status.

```bash
kubectl -n kubelet-density-heavy get applicationgroup acm-applicationgroup -o wide

kubectl -n kubelet-density-heavy describe applicationgroup acm-applicationgroup
```

Things to check:

* ApplicationGroup exists
* Status is Ready
* No warning events
* No reconciliation errors

Possible issues:

* ApplicationGroup not found
* ApplicationGroup stuck in reconciliation
* Missing dependencies

---

# Step 2 – Verify CRDs

Check that ACM and SWM CRDs are installed.

```bash
kubectl get crd | grep -i assignmentplan

kubectl get crd | grep -i qos
```

Expected:

* AssignmentPlan CRD exists
* QoS/SWM CRDs exist

Possible issues:

* SWM installation incomplete
* ACM installation incomplete

---

# Step 3 – Verify Cluster Nodes

Check node availability.

```bash
kubectl get nodes -o wide
```

Expected:

* All nodes Ready

Possible issues:

* NotReady nodes
* Network partition
* Worker unavailable

---

# Step 4 – Verify Node Capacity

Inspect every node.

```bash
kubectl describe node <node-name>
```

Important sections:

```text
Capacity
Allocatable
Non-terminated Pods
DiskPressure
MemoryPressure
PIDPressure
```

Quick filter:

```bash
kubectl describe node <node-name> \
| egrep -i 'Allocatable:|Capacity:|pods|Non-terminated Pods|DiskPressure|MemoryPressure|PIDPressure'
```

Expected:

```text
DiskPressure=False
MemoryPressure=False
PIDPressure=False
```

Possible issues:

```text
DiskPressure=True
MemoryPressure=True
PIDPressure=True
```

These often prevent scheduling.

---

# Step 5 – Verify AssignmentPlan Creation

Check whether the solver generated a plan.

```bash
kubectl -n codeco-test get assignmentplan \
acm-applicationgroup-assignment-plan

kubectl -n kdh get assignmentplan \
acm-applicationgroup-assignment-plan -o yaml
```

If AssignmentPlan does not exist:

* Solver did not run
* ACM did not trigger the solver
* CRDs/controllers missing

---

# Step 6 – Inspect AssignmentPlan Status

Inspect the most important fields.

```bash
kubectl -n kdh get assignmentplan \
acm-applicationgroup-assignment-plan \
-o yaml
```

Focus on:

```yaml
status:
  actions:
  actionInfo:
```

Important fields:

```yaml
status.actions

status.actionInfo[*].done

status.actionInfo[*].error
```

Interpretation:

### Healthy

```yaml
done: true
error: ""
```

### Problematic

```yaml
done: false
error: ...
```

This usually indicates:

* Placement failed
* Execution failed
* Resource constraints
* ACM execution issue

---

# Step 7 – Verify ACM Controller

Check ACM pods.

```bash
kubectl get pods -n he-codeco-acm
```

Inspect logs.

```bash
kubectl logs deploy/acm-operator-controller-manager \
-n he-codeco-acm \
--tail=200
```

If the controller restarted:

```bash
kubectl logs deploy/acm-operator-controller-manager \
-n he-codeco-acm \
--previous \
--tail=200
```

Look for:

```text
error
failed
reconcile
reconciler
```

Common issues:

* Reconciliation failures
* Missing resources
* Invalid AssignmentPlan

---

# Step 8 – Verify SWM Solver

Check solver pods.

```bash
kubectl get pods -n he-codeco-swm
```

Inspect logs.

```bash
kubectl logs <solver-pod> \
-n he-codeco-swm
```

Look for:

```text
not feasible
infeasible
placement-attempts-exhausted
solver retries exhausted
```

Interpretation:

### not feasible

No valid placement found.

Possible causes:

* Insufficient resources
* Affinity constraints
* Network constraints
* Missing node labels

### exhausted retries

Solver repeatedly failed.

---

# Step 9 – Verify Workload Pods

Check workload status.

```bash
kubectl get pods -n kdh -o wide
```

Inspect individual pods.

```bash
kubectl describe pod <pod-name> -n kdh
```

Important states:

### Pending

Usually scheduling issue.

### ContainerCreating

Usually image, volume, or networking issue.

### CrashLoopBackOff

Application crash.

### Terminating

Cleanup problem.

---

# Step 10 – Verify Events

Events often provide the fastest explanation.

```bash
kubectl get events -n kdh \
--sort-by=.lastTimestamp
```

Look for:

```text
FailedScheduling
FailedCreatePodSandBox
BackOff
Failed
```

---

# Step 11 – Verify Multus

Check Multus pods.

```bash
kubectl get pods -n kube-system -o wide | grep -i mu
```

Inspect logs.

```bash
kubectl logs <multus-pod> \
-n kube-system
```

Important messages:

### Healthy

```text
AddedInterface
ADD finished
DEL finished
```

### Warning

```text
GetPod failed
failed to get cached delegates file
cannot properly delete
```

Usually cleanup-related.

### Critical

```text
too many open files
failed to create pod sandbox
CrashLoopBackOff
```

These often affect networking.

---

# Step 12 – Decide Whether to Restart Multus

Restart only if:

```text
too many open files
failed to create pod sandbox
CrashLoopBackOff
persistent networking failures
```

Command:

```bash
kubectl rollout restart ds \
-n kube-system \
kube-multus-ds
```

Note:

A running Multus pod can still be unhealthy.

Kubernetes automatically restarts crashed containers, but it does not restart a daemon that is still Running while internally degraded.

---

# Quick Diagnosis Flow

```text
┌─────────────────────────────┐
│      ApplicationGroup       │
└──────────────┬──────────────┘
               │
               ▼
┌─────────────────────────────┐
│ AssignmentPlan created ?    │
└───────┬─────────────────┬───┘
        │ YES             │ NO
        │                 │
        ▼                 ▼
┌─────────────────┐  ┌─────────────────────┐
│ AssignmentPlan  │  │ Check ACM Controller│
│ actions done ?  │  └─────────────────────┘
└──────┬─────┬────┘             │
       │YES  │NO                ▼
       │     │         ┌─────────────────────┐
       │     └────────▶│ Check CRDs          │
       │               └─────────────────────┘
       │
       ▼
┌─────────────────────────────┐
│ Pods scheduled ?            │
└───────┬───────────────────┬─┘
        │ YES               │ NO
        │                   │
        ▼                   ▼
┌───────────────────────┐ ┌───────────────────┐
│ Pods ContainerCreating│ │ Check Solver Logs │
│ ?                     │ └───────────────────┘
└───────┬─────┬──────┬──┘           │
        │ NO  │      │ YES          ▼
        │     │      │         ┌───────────────────┐
        │     │      └────────▶│ Check Node        │
        │     │                │ Resources         │
        │     │                └───────────────────┘
        │     │Stucked	       ┌───────────────────┐
      	│     └───────────────▶│ Check Multus      │
      	│		                   └───────────┬───────┘
     		│			               	             │
     		│			            	               ▼
     		│		                   ┌───────────────────┐
     		│		                   │ Check Events      │
     		│		                   └───────────────────┘
        │                
        ▼
┌─────────────────────────────┐
│ Pods CrashLoopBackOff ?     │
└───────┬──────────────────┬──┘
        │ NO               │ YES
        │                  │
        ▼                  ▼
┌─────────────────┐ ┌─────────────────────┐
│ Application     │ │ Check Application   │
│ Healthy         │ │ Logs                │
└─────────────────┘ └─────────────────────┘


```
