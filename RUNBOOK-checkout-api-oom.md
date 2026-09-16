# Runbook: checkout-api `OOMKilled`

Use this runbook when `checkout-api` pods are restarting and the container
reports `Reason: OOMKilled`. The incident described in the postmortem was
caused by a memory limit reduced from `128Mi` to `8Mi`; the application did
not have a memory leak. The deployment runs in the `checkout-api` namespace.

## Diagnosis

### 1. Confirm the symptom and scope

Set the namespace and list the workload before changing anything:

```bash
NS=checkout-api
kubectl -n "$NS" get deployment checkout-api
kubectl -n "$NS" get pods -l app=checkout-api -o wide
kubectl -n "$NS" get pods -l app=checkout-api \
  -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,PHASE:.status.phase'
```

Look for a rising restart count, pods that are not Ready, or more than one
pod affected. Check the service and endpoints as well if requests are
failing:

```bash
kubectl -n "$NS" get service,endpoints -l app=checkout-api
```

### 2. Verify that the termination was an OOM kill

Capture the affected pod name, then inspect its last container state:

```bash
POD="$(kubectl -n "$NS" get pod -l app=checkout-api \
  -o jsonpath='{.items[0].metadata.name}')"
kubectl -n "$NS" describe pod "$POD"
kubectl -n "$NS" get pod "$POD" \
  -o jsonpath='{range .status.containerStatuses[*]}{.name}{" lastReason="}{.lastState.terminated.reason}{" exitCode="}{.lastState.terminated.exitCode}{" finishedAt="}{.lastState.terminated.finishedAt}{"\n"}{end}'
```

Confirm `Reason: OOMKilled` (normally exit code `137`) under the
`checkout-api` container's last state. Do not treat a probe failure alone as
an OOM kill.

Review logs from the terminated container and the namespace events:

```bash
kubectl -n "$NS" logs "$POD" -c checkout-api --previous --timestamps
kubectl -n "$NS" get events --sort-by='.lastTimestamp' \
  | tail -n 30
```

### 3. Check the configured limit against actual usage

Inspect the live deployment and pod resource settings:

```bash
kubectl -n "$NS" get deployment checkout-api \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="checkout-api")].resources}{"\n"}'
kubectl -n "$NS" get pod "$POD" \
  -o jsonpath='{.spec.containers[?(@.name=="checkout-api")].resources}{"\n"}'
kubectl -n "$NS" top pod "$POD" --containers
```

`kubectl top` requires Metrics Server. If it is unavailable, continue with
the configured resources and container logs/events; do not infer that usage
is zero. Compare the live value with the checked-in deployment manifest:

```bash
grep -A8 -B2 'name: checkout-api' checkout-api-deployment.yaml
kubectl -n "$NS" get deployment checkout-api -o yaml
```

For this incident, an `8Mi` limit is invalid for the workload even at idle.
Also check whether the node itself is under memory pressure, since node
eviction is a different failure mode:

```bash
NODE="$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.spec.nodeName}')"
kubectl describe node "$NODE" | grep -A8 -E 'Conditions:|MemoryPressure'
```

Record the pod description, resource values, restart count, timestamps, and
relevant events in the incident. If the evidence does not show
`OOMKilled`, stop this runbook and route the incident to the appropriate
probe, node-pressure, or application-error procedure.

## Resolution

### 1. Restore the known-good memory limit

If the live limit is below the workload's known-good value, restore the
postmortem value of `128Mi` for both the request and limit. Apply the
change through the Deployment so newly created pods receive it:

```bash
kubectl -n "$NS" patch deployment checkout-api --type='strategic' \
  -p '{"spec":{"template":{"spec":{"containers":[{"name":"checkout-api","resources":{"requests":{"memory":"128Mi"},"limits":{"memory":"128Mi"}}}]}}}}'
```

Do not lower the limit further during the incident. If `128Mi` is not the
approved value for the current release, use the last known-good value from
version control or the approved change record instead.

### 2. Wait for the rollout and verify recovery

```bash
kubectl -n "$NS" rollout status deployment/checkout-api --timeout=120s
kubectl -n "$NS" get pods -l app=checkout-api -o wide
kubectl -n "$NS" get pods -l app=checkout-api \
  -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,PHASE:.status.phase'
kubectl -n "$NS" get endpoints -l app=checkout-api
```

Confirm that pods are Ready, restart counts stop increasing, endpoints are
present, and requests succeed. If available, check current usage again:

```bash
kubectl -n "$NS" top pod -l app=checkout-api --containers
```

If the rollout does not stabilize, capture the new `describe`, `logs
--previous`, and events output. Escalate rather than repeatedly restarting
pods; a continuing OOM kill may indicate that the approved limit is
insufficient or that a separate application issue is present.

### 3. Close out the incident

Record the start and recovery times, affected pods, observed limit, restored
limit, commands/output used to confirm recovery, and request impact. Open a
follow-up to validate resource-limit changes against observed usage before
deployment and to add automated checks preventing unrealistic limits such as
`8Mi`.
