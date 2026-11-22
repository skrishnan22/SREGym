# Chapter 2: SRE and Kubernetes Primer for the Harness Builder

After reading this chapter you will be able to sit in the agent's seat on an [SREGym](https://www.sregym.com) problem and say what a competent human SRE would run, in what order, and why. You will also be able to read a failed agent transcript and tell whether it failed on method, on Kubernetes knowledge, or on handling the tool output.

**A rule for this whole project: do not leak answers.** This chapter describes fault *classes* ("a Service that selects the wrong pods"). It deliberately does not pair any specific problem ID with its exact root cause and fix. Do not put per-problem answers, or hints distilled from reading the problem code in the SREGym repo, into your agent's prompt, tools or memory. That would measure your prompt-writing, not your harness, and the results would not transfer to real incidents.

## 1. The incident-response method

Google's SRE book describes troubleshooting as a loop: observe a problem, hypothesize, test the hypothesis, and treat the result as new evidence ([Effective Troubleshooting](https://sre.google/sre-book/effective-troubleshooting/)). In practice:

1. **Observe symptoms.** What is the user-visible failure? Errors, latency, missing data, a pod that will not start. Write down what is actually broken and what you have only assumed.
2. **Form hypotheses.** Rank them by likelihood and by cost to test. Recent changes, resource limits, config, and dependencies are the usual first suspects.
3. **Test.** Pick the cheapest command that can falsify a hypothesis. A hypothesis you cannot test is a guess.
4. **Separate root cause from symptom.** A crash-looping pod is a symptom. "Its database password is wrong" is nearer to a cause. "A secret was rotated and the pod still holds the old value" is the root cause. Keep asking "why" until the answer is something you could change.
5. **Mitigate.** Stop the harm. Prefer the smallest change that removes the cause. Restarting a pod can look like a fix, but it only masks the cause if the cause is still there.
6. **Verify.** Confirm that the original symptom is gone, that dependent services recover, and that the fix survives a restart. A good SRE also re-checks after a few minutes, because some faults come back.

**Why root cause matters in SREGym.** The benchmark grades the two phases separately, and a run counts only if both pass. According to the [SREGym paper](https://arxiv.org/html/2605.07161) (arXiv 2605.07161):

- **Diagnosis** is graded by an LLM judge using a nine-question yes/no checklist in three dimensions: *fault localization* (did you name the originating component and distinguish it from downstream victims?), *fault characterization* (did you identify the injected mechanism, with concrete detail?), and *failure scope* (did you avoid over- or under-attributing blame?). It passes at 7/9 or better. Naming a downstream victim, or saying "the service was unhealthy" without a mechanism, fails.
- **Mitigation** is graded by a problem-specific oracle that checks that the target fault is actually resolved and that the system is healthy again, using client-side signals such as request success rate and system-side state in the cluster.

The practical lesson for the harness: the agent's final diagnosis should name one component, one mechanism, and the evidence, and it should explicitly rule out the victims. The fix should target the cause.

## 2. Kubernetes objects that matter when debugging

Kubernetes is a set of control loops. You declare desired state (objects), controllers compare it to actual state and act. Most faults are an object whose declared state is wrong, or a controller that cannot converge.

| Object | What it is | How it breaks |
|---|---|---|
| [Pod](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/) | One or more containers sharing network and storage; the unit that runs | Crashes, never schedules, image cannot be pulled, killed for memory, fails probes |
| [Deployment](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/) / ReplicaSet | Declares N identical pods; the Deployment manages ReplicaSets for rolling updates | Bad rollout (new ReplicaSet never becomes ready), replicas scaled to 0, update-strategy settings that stall or over-surge |
| [Service](https://kubernetes.io/docs/concepts/services-networking/service/) / Endpoints | A stable virtual IP and DNS name; Endpoints (EndpointSlices) list the ready pod IPs behind it | Selector matches no pods (empty endpoints), wrong `targetPort`, traffic policy that excludes pods, pods not ready so removed from endpoints |
| [ConfigMap](https://kubernetes.io/docs/concepts/configuration/configmap/) | Non-secret config injected as env vars or files | Missing (pod stuck `CreateContainerConfigError`), wrong value, env vars not refreshed until pod restart |
| [Secret](https://kubernetes.io/docs/concepts/configuration/secret/) | Credentials and certificates, base64-encoded | Rotated while consumers keep the old value, wrong key, expired certificate |
| [PVC / PV](https://kubernetes.io/docs/concepts/storage/persistent-volumes/) | A claim for storage and the volume that satisfies it | Claim stays `Pending`, access mode conflicts (two pods, one volume), node affinity of the volume conflicts with pod placement |
| [NetworkPolicy](https://kubernetes.io/docs/concepts/services-networking/network-policies/) | Allow-lists for pod traffic | A policy silently drops traffic: connections time out rather than being refused |
| [Ingress](https://kubernetes.io/docs/concepts/services-networking/ingress/) | HTTP routing from outside the cluster to Services | Rule routes a path to the wrong Service, wrong port, missing TLS secret |
| [Job / CronJob](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/) | Run-to-completion work, once or on a schedule | Never completes (a container that never exits), backoff exhausted, overlapping runs |
| [Node](https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/) (taints, tolerations, [affinity](https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/)) | A machine; taints repel pods unless tolerated; affinity attracts or repels | Pod has no toleration for a taint, affinity rules nobody can satisfy, node `NotReady`, node under resource pressure evicting pods |
| [ResourceQuota](https://kubernetes.io/docs/concepts/policy/resource-quotas/) / [LimitRange](https://kubernetes.io/docs/concepts/policy/limit-range/) | Namespace-wide caps and per-container defaults/limits | New pods are rejected or the ReplicaSet cannot create pods (look at its events, not the pod's, because no pod exists); defaults that are too small |
| [Admission webhooks](https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/) | External callbacks that mutate or validate objects at creation time | Webhook down or slow, so creates fail or time out; a mutating webhook rewrites your spec (for example resource limits) so the live object differs from what you applied |
| [Finalizers](https://kubernetes.io/docs/concepts/overview/working-with-objects/finalizers/) | Keys on an object that block deletion until a controller cleans up | Object stuck `Terminating` because the controller that should remove the finalizer is gone or deadlocked |
| [Probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/) | Liveness (restart if failing), readiness (remove from endpoints if failing), startup (delay the others) | Liveness too aggressive kills healthy slow-starting pods; readiness wrong so a healthy pod never gets traffic; probe port or path wrong |
| [CoreDNS](https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/) | Cluster DNS; resolves `svc.namespace.svc.cluster.local` | Stale or broken config, wrong pod `dnsPolicy`, name resolves to a wrong or stale address |

Two relationships to keep in mind. First, a Service finds pods only by label selector, and only *ready* pods appear in its endpoints. Second, a Deployment never creates pods directly: Deployment creates ReplicaSet creates Pod, and errors can surface at any layer. When no pod exists, look at the ReplicaSet's events.

## 3. The debugging toolkit

Commands below are real kubectl usage; see the [kubectl quick reference](https://kubernetes.io/docs/reference/kubectl/quick-reference/) and the Kubernetes guides to [debugging pods](https://kubernetes.io/docs/tasks/debug/debug-application/debug-pods/) and [debugging Services](https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/).

```bash
# What exists, where it runs, what state it is in
kubectl get pods -n NS -o wide              # NODE and IP columns; READY x/y; STATUS; RESTARTS
kubectl get pods -A --field-selector=status.phase!=Running   # only the non-running ones, all namespaces
kubectl get deploy,rs,svc,endpoints -n NS   # the chain from controller to traffic

# Why is it in that state? The Events section at the bottom is the most valuable part
kubectl describe pod POD -n NS

# What did the process say?
kubectl logs POD -n NS --tail=100           # bound the output
kubectl logs POD -n NS --since=10m          # time-bound it
kubectl logs POD -n NS --previous           # logs of the last crashed container
kubectl logs POD -n NS -c CONTAINER         # required when the pod has several containers

# What has the cluster itself been saying?
kubectl get events -n NS --sort-by=.lastTimestamp
kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp

# Does a Service actually have backends?
kubectl get endpoints SVC -n NS             # <none> or empty means the selector or readiness is wrong
kubectl get svc SVC -n NS -o yaml           # compare .spec.selector and ports to the pod labels

# Look inside
kubectl exec -it POD -n NS -- sh            # then curl, nslookup, env, cat config
kubectl exec POD -n NS -- env | grep -i DB  # one-shot, bounded

# Resource pressure (needs metrics-server)
kubectl top pods -n NS
kubectl top nodes

# Rollouts
kubectl rollout status deploy/NAME -n NS
kubectl rollout history deploy/NAME -n NS
kubectl rollout undo deploy/NAME -n NS      # a mitigation, not a diagnosis

# Permissions
kubectl auth can-i get secrets -n NS --as=system:serviceaccount:NS:SA

# Targeted reads of the live spec
kubectl get deploy NAME -n NS -o yaml | grep -n -A3 -iE 'image:|resources:|env:|livenessProbe'
kubectl get deploy NAME -n NS -o jsonpath='{.spec.template.spec.containers[*].image}'

# Ephemeral debug container in a pod that has no shell tools
kubectl debug -it POD -n NS --image=busybox:1.36 --target=CONTAINER
```

`kubectl debug` is documented in [Debug Running Pods](https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/). Note that `kubectl top` depends on metrics-server being installed; if it errors, that is an environment fact, not necessarily a fault.

### What each output tells you

- **`get pods -o wide`**: STATUS names the failure; READY `0/1` with STATUS `Running` means readiness is failing; RESTARTS climbing means crash loops or liveness kills; NODE shows whether the failures cluster on one node (suspect the node) or are spread (suspect config).
- **`describe pod`**: read bottom up. Events say *scheduler could not place it*, *image pull failed*, *probe failed*, *container killed*. The upper part has the last state and exit code (`Last State: Terminated`, `Reason: OOMKilled`, `Exit Code: 137`).
- **`logs --previous`**: for a container in CrashLoopBackOff, current logs are often empty because the new container just started. The previous container's logs hold the actual error.
- **`get endpoints`**: the single fastest test for "is this Service wired to anything?"
- **`get events --sort-by`**: events are not ordered by default; sort them. They expire (about an hour by default), so an old fault may have left none.
- **`auth can-i`**: answers "is this an RBAC problem?" in one line.

### Commands that produce huge output, and how to bound them

This matters more for an LLM than for a human, because every token lands in the context window.

| Command | Why it is large | Bounded form |
|---|---|---|
| `kubectl logs` | An unbounded stream, possibly thousands of lines of repeated errors | `--tail=100`, `--since=5m`, pipe to `grep -iE 'error|fail|timeout' | tail -50` |
| `kubectl get pods -A` | Dozens to hundreds of rows across all namespaces (SREGym also runs monitoring stacks) | `-n APPNS`, or `--field-selector=status.phase!=Running`, or `\| grep -v Running` |
| `kubectl get ... -o yaml` | Hundreds of lines per object, mostly `managedFields` and defaults | `-o jsonpath=...`, `\| grep -n -A3 pattern`, or `kubectl get ... -o yaml --show-managed-fields=false` (this is the default in recent versions; still bound with grep) |
| `kubectl describe node` | Long, includes every pod on the node | `\| sed -n '/Conditions/,/Addresses/p'` or `\| grep -A8 Taints` |
| `kubectl get events -A` | Every event in the cluster | `-n NS`, `--field-selector type=Warning`, `\| tail -30` |
| `kubectl api-resources`, `kubectl explain --recursive` | Very long reference output | Avoid; use `kubectl explain pod.spec.containers.livenessProbe` for one field |
| Prometheus or Jaeger raw queries | Large JSON | Limit the time range, aggregate in the query (`topk`, `sum by`), request only needed fields |

A harness should enforce this itself: truncate any tool output past a budget, keep the head and the tail, and say so ("output truncated, 4,812 lines omitted; rerun with grep"). Do not rely on the model to remember `--tail`.

### The first five minutes

A human SRE in an unfamiliar namespace does roughly this. Your agent should too.

1. **Get the lay of the land (30 seconds).** `kubectl get pods -n NS -o wide` and `kubectl get svc,endpoints -n NS`. What is not `Running` and `1/1`? Which Services have empty endpoints?
2. **Read the cluster's own complaints.** `kubectl get events -n NS --sort-by=.lastTimestamp | tail -30`. Scheduling, image, quota, probe and admission failures are named here directly.
3. **Pick the most upstream broken thing and describe it.** `kubectl describe pod/deploy/svc X`. Note exit codes, last state, and the event reasons.
4. **Read its logs, bounded.** `kubectl logs X --tail=100`, plus `--previous` if it restarted. Look for the first error, not the loudest.
5. **Trace the dependency edge.** From the failing caller, who does it call? Check that callee's pods, endpoints, and logs. Repeat until you reach something that is broken without a broken dependency. That is your candidate root cause.

Then state a hypothesis, test it with one more command, and only then change something. Write the diagnosis before mitigating, because a mitigation can erase the evidence.

## 4. Reading pod status

| Status | Usual causes | Next command |
|---|---|---|
| `Pending` | Scheduler cannot place it: insufficient CPU or memory, unsatisfied node affinity or taint without toleration, unbound PVC, quota | `kubectl describe pod` and read the `FailedScheduling` event, which states the reason per node; `kubectl get pvc`; `kubectl describe node \| grep -A8 Taints` |
| `ContainerCreating` (long) | Volume mount failing, missing ConfigMap or Secret, CNI problems | `describe pod` events |
| `CrashLoopBackOff` | Process exits repeatedly: bad config, missing env var, cannot reach or authenticate to a dependency, crash on startup. Kubernetes backs off between restarts | `kubectl logs POD --previous`; exit code from `describe` |
| `ImagePullBackOff` / `ErrImagePull` | Wrong image name or tag, registry unreachable, missing pull secret | `describe pod` events show the exact pull error; `kubectl get deploy -o jsonpath` for the image |
| `OOMKilled` (a *reason* in last state, exit code 137, not a status column) | Container exceeded its memory limit; limit too low or a leak | `describe pod`, then `kubectl top pod` and compare to `resources.limits.memory`; check for a LimitRange or ResourceQuota that set the limit |
| `Completed` | A Job pod finished; normal. If a Job or CronJob *should* have completed and has not, the opposite is the problem | `kubectl get jobs`; check for a second container (sidecar) that never exits |
| `Init:0/2`, `Init:1/2` | Init containers run in sequence; the pod waits for them. Stuck means one is waiting on a dependency or failing | `kubectl logs POD -c INIT_CONTAINER_NAME` |
| `Running`, READY `0/1` | Readiness probe failing or the probe targets the wrong port/path. The pod is not in Service endpoints | `describe pod` for `Readiness probe failed`; `kubectl exec` and curl the probe path yourself |
| `Terminating` (stuck) | A finalizer on the pod or its dependents, a node that is `NotReady`, a volume that will not detach | `kubectl get pod POD -o jsonpath='{.metadata.finalizers}'`; `kubectl get nodes` |
| `Error` / `CreateContainerConfigError` | Referenced ConfigMap/Secret or key is missing | `describe pod` names the missing object |
| `Evicted` | Node pressure (memory, disk) | `describe node` conditions; see [node-pressure eviction](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/) |

The exit codes are the Linux convention: 137 is SIGKILL (128+9), which in Kubernetes usually means OOM kill or a liveness-probe kill; 143 is SIGTERM. See [Determine the reason for pod failure](https://kubernetes.io/docs/tasks/debug/debug-application/determine-reason-pod-failure/).

## 5. Observability basics

Three signal types answer different questions.

**Metrics** are numeric time series, cheap to store and good for "how bad, since when, how widespread." [Prometheus](https://prometheus.io/docs/prometheus/latest/querying/basics/) scrapes them and you query with PromQL. Examples (metric names depend on the app and exporters; check what exists first with a query like `{__name__=~"http.*"}` bounded by a time range):

```promql
# Per-service request rate over 5 minutes
sum by (service) (rate(http_requests_total[5m]))

# Error ratio
sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))

# p99 latency from a histogram
histogram_quantile(0.99, sum by (le, service) (rate(http_request_duration_seconds_bucket[5m])))

# Containers restarting
increase(kube_pod_container_status_restarts_total[15m]) > 0

# Memory near its limit (cAdvisor + kube-state-metrics names)
container_memory_working_set_bytes / on(namespace,pod,container) kube_pod_container_resource_limits{resource="memory"}
```

`rate` and `histogram_quantile` are documented in the [PromQL functions reference](https://prometheus.io/docs/prometheus/latest/querying/functions/). Metrics tell you *which* service is bad; they rarely tell you *why*.

**Traces** record one request's path across services as spans with timings ([Jaeger](https://www.jaegertracing.io/docs/latest/) is the viewer SREGym's apps use). They are best for "where in the call chain is the time or the error?" A trace with a slow or erroring span three hops deep shows you the true origin while the front end merely reports a timeout. Sampling matters: DeathStarBench's Hotel Reservation defaults to tracing only 1% of requests (`JAEGER_SAMPLE_RATIO`, per its [README](https://github.com/delimitrou/DeathStarBench/blob/master/hotelReservation/README.md)), so you may find no trace for a rare error.

**Logs** are per-process text. They are best for the *reason*: the exception, the refused connection, the auth failure. They are worst for scale: volume is high and the interesting line is often the first one, long before the repeated copies.

Use them in that order when there is a user-facing symptom: metrics to find the sick service, traces to find the sick hop, logs to read the reason. The SREGym paper says agents get access to metrics (Prometheus), logs (Loki), traces (Jaeger), and kubectl through MCP servers, plus a submission tool ([paper](https://arxiv.org/html/2605.07161)). Your harness uses a shell with kubectl, so check what is reachable from your sandbox before assuming any of these exist.

## 6. The applications

SREGym's README and paper say its problems run on five applications; this chapter covers the three that the Lite suite uses. The upstream docs are thin on internals, so the descriptions below stay at the level the docs and source tree support.

**Hotel Reservation** ([DeathStarBench](https://github.com/delimitrou/DeathStarBench/tree/master/hotelReservation)). A Go and gRPC application for browsing hotels, getting recommendations and making reservations, per its README. The `services/` directory of the repo lists: `frontend`, `search`, `geo`, `rate`, `profile`, `recommendation`, `reservation`, `user`, `attractions`, `review`. The README documents memcached (with a timeout setting) and Jaeger tracing. The data stores per service (MongoDB plus memcached for most of the data services) are not described in the README; the problem IDs in SREGym that mention `mongodb-geo` and `mongodb-rate` confirm per-service MongoDB instances. A request enters at `frontend`, which fans out over gRPC. A search goes through `search`, which in turn uses `geo` (nearby hotels) and `rate` (prices); `profile` supplies hotel details. This request flow is my reading of the service names and common knowledge of the project, not stated in the README; treat it as unverified detail and confirm with Jaeger on a live cluster.

**Social Network** ([DeathStarBench](https://github.com/delimitrou/DeathStarBench/tree/master/socialNetwork)). A social network with one-way follow relationships, built from loosely coupled microservices that talk over Thrift RPC, behind an nginx web frontend on port 8080 (per its README). The source tree contains services including `ComposePostService`, `HomeTimelineService`, `UserTimelineService`, `PostStorageService`, `SocialGraphService`, `TextService`, `MediaService`, `UniqueIdService`, `UrlShortenService`, `UserMentionService`, `UserService`, and `WriteHomeTimelineService`. The README references Redis and MongoDB, and the code has memcached utilities, so caches and databases sit behind the storage-facing services. Composing a post goes through nginx to `ComposePostService`, which calls the text, media, URL-shortening, user-mention and unique-ID services and then stores the post and updates timelines. Jaeger shows these hops for a compose request.

**Astronomy Shop** ([OpenTelemetry Demo](https://opentelemetry.io/docs/demo/architecture/)). An online store whose purpose is to exercise telemetry, written in many languages. From the demo's architecture page: a front-end proxy (Envoy) is the single entry point and routes to the `frontend` (TypeScript), which calls `ad`, `cart`, `currency`, `shipping`, `product-catalog`, `recommendation` and `checkout`. `checkout` (Go) orchestrates `cart`, `currency`, `payment`, `shipping` (which calls `quote`), `email` and `product-catalog`, then publishes the order to **Kafka**; `fraud-detection` and `accounting` consume it, and `accounting` writes to **PostgreSQL**. `cart` stores carts in **Valkey** (a Redis-compatible cache). `product-catalog` reads PostgreSQL. A load generator (Locust) sends constant traffic, and **flagd** provides [feature flags](https://opentelemetry.io/docs/demo/feature-flags/) that services query, which is the demo's built-in fault-injection mechanism. Telemetry flows through the OpenTelemetry Collector to Prometheus (metrics), Jaeger (traces) and OpenSearch (logs), visualized in Grafana. Newer demo versions also include a chatbot, agent and MCP service.

Practical consequences: Astronomy Shop has many more components and a Kafka and database layer, so "which of 25 healthy things is the broken one" is harder. The DeathStarBench apps are leaner but older and less forgiving about config.

## 7. SREGym's fault families

The [problems page](https://www.sregym.com/problems) lists 90 faults in the SREGym-0508 cohort, grouped as Ported (34, from earlier benchmarks), Similar Failures (43) and New Failures (13). The paper describes the 90 problems as built from 47 fault primitives over five applications ([paper](https://arxiv.org/html/2605.07161)). The [registry](https://github.com/SREGym/SREGym/blob/main/sregym/conductor/problems/registry.py) groups the code by injector. The categories below are my grouping for thinking about diagnosis. The paper's fault types include fail-stop, fail-slow, OS and hardware faults, misdeployment and misconfiguration, code bugs, operator misoperation, service overload, network delay and loss, and noisy neighbors.

Note that the registry's own comment lists about twenty "saturated" problems (every evaluated model passed at 100% pass@3) that are no longer registered, and the registry also contains problems for other apps (Frappe, Saleor, Slack Spine, GitLab, Stripe-style scenarios). Do not assume the website's list and the registry match.

| Family | Example IDs (registry) | What diagnosing it typically requires |
|---|---|---|
| Service wiring (selectors, ports, DNS, ingress, traffic policy) | `service_wrong_pod_selection_hotel_reservation`, `wrong_service_selector_astronomy_shop`, `ingress_misroute`, `internal_traffic_policy_local_astronomy_shop`, `service_dns_resolution_failure_social_network`, `wrong_dns_policy_hotel_reservation` | Compare the Service object to pod labels and ports; check endpoints; test name resolution and connectivity from inside a pod |
| Scheduling and placement | `taint_no_toleration_social_network`, `unschedulable_incorrect_port_assignment`, `persistent_volume_affinity_violation`, `priority_preemption_cascade_hotel_reservation` | Read `FailedScheduling` events; inspect taints, affinity, PVC and priority classes |
| Resource limits and quota | `namespace_memory_limit`, `resource_request_too_small`, `mutating_webhook_resource_limits_social_network`, `cfs_cpu_throttling_hotel_reservation` | Compare limits to usage; find *who* set the limit (quota, LimitRange, webhook), not just the container |
| Config and secrets | `configmap_drift_hotel_reservation`, `missing_configmap_hotel_reservation`, `env_variable_shadowing_astronomy_shop`, `secret_rotation_stale_env_credentials_astronomy_shop`, `misconfig_app_hotel_res` | Compare live config to what the process actually sees (`exec env`); remember pods do not see changed env vars until restarted |
| Datastore auth and availability | `valkey_auth_disruption`, `valkey_memory_disruption`, `revoke_auth_mongodb-1`, `auth_miss_mongodb`, `postgres_lock_contention_product_catalog` | Follow an application error to the datastore; test auth and state from inside the cluster |
| Probes and lifecycle | `liveness_probe_too_aggressive_hotel_reservation`, `readiness_probe_misconfiguration_hotel_reservation`, `init_container_dependency_hang_social_network`, `sidecar_port_conflict_social_network` | Compare restart counts and probe events to actual app readiness; read init container logs |
| Controllers and rollouts | `rolling_update_misconfigured_social_network`, `scale_pod_zero_social_net`, `finalizer_deadlock_controller_hotel_reservation`, `cronjob_sidecar_blocks_completion_hotel_reservation`, `duplicate_pvc_mounts_social_network` | Walk Deployment to ReplicaSet to Pod; inspect update strategy, finalizers, Job completion semantics, volume access modes |
| Network and security policy | `network_policy_block`, `psa_restricted_blocks_recreation_hotel_reservation`, `expired_tls_hotel_reservation`, `admission_webhook_tls_mismatch_hotel_reservation` | Connection *timeouts* point to policy; admission failures show up in ReplicaSet/event messages, not pod logs |
| Application and messaging faults | `kafka_poison_pill_hol_block`, `kafka_queue_problems`, `astronomy_shop_cart_service_failure`, `feature_flag_latent_bug_hotel_reservation` | Traces and consumer logs; understand queue semantics and feature-flag state |
| Performance and overload | `edge_request_filter_cpu_saturation`, `astronomy_shop_ad_service_high_cpu`, `gc_capacity_degradation`, `loadgenerator_flood_homepage` | Metrics first (CPU, latency), then find what is consuming the resource |
| Metastable failures | `search_rate_retry_collapse_hotel_reservation`, `load_spike_rpc_retry_storm`, `capacity_decrease_rpc_retry_storm` | See section 8 |
| Node and OS level | `kubelet_crash`, `kubelet_eviction_threshold_misconfig`, `node_clock_drift_hotel_reservation`, `node_conntrack_exhaustion_hotel_reservation`, `pod_cidr_exhaustion_hotel_reservation`, `file_descriptor_exhaustion` | See section 8 |
| Operator misoperation | `operator_overload_replicas`, `operator_wrong_operator_image`, `operator_invalid_affinity_toleration` | See section 8 |
| Correlated / multiple faults | `update_incompatible_correlated`; concurrent-fault bundles exist in the registry but are commented out at the time of reading | More than one thing is wrong; stopping at the first is a partial fix |

### SREGym-Lite: the 17 problems

[SREGym-Lite](https://github.com/SREGym/SREGym/blob/main/docs/SREGym-Lite.md) is a curated set of 17 problems chosen to be reliable to run; it fits a kind cluster of one control-plane and three workers on a machine with 8 vCPU and 16 GB RAM, and excludes TrainTicket and hardware faults. The doc lists IDs only. The "fault class" column below is inferred from the ID (and, where noted, the problem class's docstring), not from the answer. Where I could not tell, I say so.

| # | Problem ID | Application | Fault class (plain description) |
|---|---|---|---|
| 1 | `cronjob_sidecar_blocks_completion_hotel_reservation` | Hotel Reservation | A scheduled Job that does not finish because of a sidecar container |
| 2 | `edge_request_filter_cpu_saturation` | Astronomy Shop | CPU saturation at the edge proxy caused by request filtering (the class docstring says a vulnerable WAF regex is injected) |
| 3 | `network_policy_block` | Hotel Reservation (registry binds it to `recommendation`) | A NetworkPolicy that blocks legitimate traffic |
| 4 | `env_variable_shadowing_astronomy_shop` | Astronomy Shop | An environment variable whose value is overridden or shadowed by another source |
| 5 | `mutating_webhook_resource_limits_social_network` | Social Network | A mutating admission webhook altering resource limits |
| 6 | `finalizer_deadlock_controller_hotel_reservation` | Hotel Reservation | Object deletion deadlocked on a finalizer and a controller |
| 7 | `kafka_poison_pill_hol_block` | Astronomy Shop (Kafka consumers) | A bad message at the head of a queue blocking those behind it (head-of-line blocking) |
| 8 | `internal_traffic_policy_local_astronomy_shop` | Astronomy Shop | A Service traffic policy restricting traffic to node-local endpoints |
| 9 | `service_dns_resolution_failure_social_network` | Social Network | Service name resolution failing |
| 10 | `service_wrong_pod_selection_hotel_reservation` | Hotel Reservation | A Service selecting the wrong pods |
| 11 | `namespace_memory_limit` | Not stated in the ID (no app suffix) | A namespace-level memory cap causing failures |
| 12 | `valkey_auth_disruption` | Astronomy Shop (Valkey backs `cart`) | Authentication to the Valkey cache disrupted |
| 13 | `secret_rotation_stale_env_credentials_astronomy_shop` | Astronomy Shop | A rotated credential that running pods have not picked up |
| 14 | `unschedulable_incorrect_port_assignment` | Not stated in the ID | A port misassignment variant created with an "unschedulable" option, so pods fail to schedule |
| 15 | `duplicate_pvc_mounts_social_network` | Social Network | Pods sharing a persistent volume claim in a way that conflicts |
| 16 | `rolling_update_misconfigured_social_network` | Social Network | A Deployment rolling-update configuration that misbehaves |
| 17 | `search_rate_retry_collapse_hotel_reservation` | Hotel Reservation | A metastable retry-amplification collapse between `search` and `rate` (class docstring) |

Rows 11 and 14 have no application suffix in the ID, so the application is not derivable from the ID alone. I did not read the problem source for their targets. If you want the application in your own metrics, take it from the harness's run metadata, not from reading problem code. Read the documented method rather than the answer: figure out which family a problem is in by symptoms, as your agent must.

## 8. Harder categories, conceptually

**Metastable failures and retry storms.** A system enters a bad state that sustains itself after the original trigger is gone. The standard pattern: a brief overload or capacity dip causes timeouts, clients retry, retries add load, the extra load causes more timeouts. Removing the trigger (the load spike) does not restore health because the retry traffic alone keeps the service saturated. The canonical reference is [Metastable Failures in the Wild (OSDI 2022)](https://www.usenix.org/conference/osdi22/presentation/huang-lexiang). Diagnosis: the "root cause" is the feedback loop (retry policy, queueing, no backoff or shedding), not the original trigger. The fix has to break the loop (reduce or shed load, change retry behavior, add capacity) and then the system has to drain. Symptoms: high request rate to a downstream service far above the front-end rate, queues growing, latency pinned at the timeout value. Restarting one pod usually does not help because load reappears immediately.

**Correlated failures.** One shared cause produces several symptoms across components (a bad rollout, shared dependency, shared node). The trap is treating each broken component as its own incident, or picking the loudest victim. Look for what they have in common: same image tag, same node, same config source, same time of onset.

**Operator misoperation.** The cluster runs a Kubernetes operator (a controller that manages an application from a custom resource). A bad change to the custom resource, or a bad operator, produces wrong child objects. The trap: editing the child objects (Deployment, StatefulSet) does nothing lasting, because the operator reconciles them straight back. You must fix the custom resource (or the operator). If your edit keeps getting reverted, a controller is overwriting you; find its owner with `kubectl get X -o jsonpath='{.metadata.ownerReferences}'`.

**Node and OS-level faults.** The kubelet crashing, eviction thresholds set wrong, clock drift, conntrack table exhaustion, pod CIDR exhaustion, file descriptor exhaustion. Symptoms are generic (timeouts, `NotReady`, evictions, intermittent connection failures, certificate errors) and `kubectl logs` on the app shows only the victim. You need `kubectl describe node`, node conditions, and often a debug pod on the node (`kubectl debug node/NAME -it --image=busybox:1.36`) to look at the host. In kind, a "node" is a Docker container, which limits what is realistic, so these problems are partly about knowing the right place to look.

## 9. Why this is hard for an LLM agent specifically

The SREGym paper reports that agents differ by up to 40% end-to-end and that injected ambient noise (transient self-recovering disturbances unrelated to the root cause, such as a pod restarting) lowers diagnosis success for every agent-model pair tested ([paper](https://arxiv.org/html/2605.07161)). Beyond that, these are the recurring failure shapes to look for in transcripts:

- **Huge, noisy output.** One `get pods -A` or `-o yaml` can consume thousands of tokens, and the signal is a single line. Fix with output budgets (section 3), not with a longer prompt.
- **Many healthy components.** Astronomy Shop has dozens of services. Agents that chase every warning waste steps. Noise events (a restarted pod, a failed probe once) are *designed* to distract. Teach the agent to ask "is this still happening, and is it on the path of the symptom?"
- **Symptom far from cause.** The frontend times out; the cause is three hops deep. Without tracing the dependency edge, the agent fixes the frontend.
- **Fixes that mask symptoms.** Deleting a pod, scaling to more replicas, raising a limit blindly, or deleting a NetworkPolicy may turn health green without addressing a cause that returns or leaves the diagnosis wrong. Remember both graders: diagnosis is scored on the cause, and mitigation checks the fault is resolved.
- **State that changes while you look.** Pods restart, endpoints flap, events expire, retry storms evolve. A command's output is a snapshot. Re-check before acting, and prefer evidence from two moments.
- **Stopping at the first finding.** Correlated and concurrent faults mean the first fix may be only partial. Verify the whole app, not only the one component.
- **Confident wrong diagnosis.** The judge penalizes over-attribution. A diagnosis that lists five suspects scores worse than one that names one and rules out the rest.

When reading a failed transcript, classify the failure: (a) wrong method (no hypotheses, no verification), (b) wrong Kubernetes knowledge (misread a status, looked in the wrong place), (c) tool handling (truncated output, timeouts, malformed commands), (d) premature or masking mitigation. Each points at a different harness fix.

## Glossary

- **Admission webhook**: an HTTP callback the API server calls to validate or modify objects on create or update.
- **CrashLoopBackOff**: the state of a container that keeps exiting, with Kubernetes waiting longer between restarts.
- **CoreDNS**: the cluster DNS server; resolves Service names.
- **Control loop / reconciliation**: a controller repeatedly moving actual state toward declared state.
- **Endpoints / EndpointSlice**: the list of ready pod addresses behind a Service.
- **Ephemeral container**: a temporary debugging container added to a running pod (`kubectl debug`).
- **Finalizer**: a marker that blocks deletion until a controller finishes cleanup.
- **kind**: Kubernetes in Docker; each "node" is a container ([quick start](https://kind.sigs.k8s.io/docs/user/quick-start/)).
- **Label selector**: key/value match used by Services and controllers to find pods.
- **Metastable failure**: a self-sustaining overload that persists after the trigger is removed.
- **Mutating webhook**: an admission webhook that changes the object before it is stored.
- **OOMKilled**: a container killed by the kernel for exceeding its memory limit (exit code 137).
- **Operator**: a controller that manages an application through a custom resource.
- **p99**: the latency below which 99% of requests fall.
- **Probe (liveness, readiness, startup)**: health checks by the kubelet that restart a container, gate traffic, or defer the others.
- **PromQL**: Prometheus's query language.
- **QoS / requests and limits**: reserved vs maximum resources per container ([docs](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)).
- **Root cause**: the earliest condition you can change that, when changed, removes the failure.
- **SLO / SLI**: a reliability target / the measured indicator for it.
- **Taint / toleration**: a node repels pods unless the pod tolerates it.
- **Trace / span**: one request's path / one timed step of it.

## Hands-on exercises

Set up a throwaway cluster: `kind create cluster --name sre-lab` (see [kind quick start](https://kind.sigs.k8s.io/docs/user/quick-start/)). Use a namespace `lab`. A small app is enough: for example two `nginx` Deployments, one acting as a "backend" and one calling it with `curl`. For each exercise, break it, then diagnose it using only `kubectl`, as your agent would, before you check what you did.

1. **Break a Service selector.** Create a Deployment with label `app=web` and a Service whose selector says `app=webb`. Run `kubectl get endpoints`, compare `svc -o yaml` to `get pods --show-labels`. Notice that pods are `Running` and logs are clean; only the endpoints reveal it.
2. **Wrong `targetPort`.** Point the Service at a port the container does not listen on. Endpoints will look populated. Find it with `kubectl exec` and `curl` against the pod IP and the Service name.
3. **Crash loop from a missing env var.** Deploy an image that exits if `DB_URL` is unset. Read `get pods`, `describe` and `logs --previous`. Fix it with `kubectl set env`, then watch `rollout status`.
4. **Memory limit.** Set a tiny memory limit (for example 10Mi) on a pod running something that uses more. Find `OOMKilled` and exit code 137 in `describe`. Then create a `ResourceQuota` and a `LimitRange` in the namespace and see how a new pod's limits change.
5. **Unschedulable pod.** Taint a node (`kubectl taint nodes NODE key=val:NoSchedule`) and deploy a pod without a toleration, or request more CPU than any node has. Read the `FailedScheduling` event. Remove the taint with `kubectl taint nodes NODE key=val:NoSchedule-`.
6. **NetworkPolicy.** Apply a default-deny ingress policy to the backend and observe the caller *time out* rather than get refused. Note: kind's default CNI may not enforce NetworkPolicy; if nothing breaks, that is an environment limit, so install a CNI that supports it before concluding anything.
7. **Stuck `Terminating`.** Add a finalizer to a ConfigMap (`kubectl patch cm X -p '{"metadata":{"finalizers":["example.com/hold"]}}' --type=merge`), delete it, and observe it hang. Clear the finalizer and see it go.
8. **Bound your output.** Pick the noisiest log and the biggest YAML in your cluster. Write the one-line commands that extract only the needed lines. Then write the same as a rule your harness could apply automatically (head and tail with a truncation notice).

For a bonus, deploy the [OpenTelemetry demo](https://github.com/open-telemetry/opentelemetry-demo) and use its [feature flags](https://opentelemetry.io/docs/demo/feature-flags/) to see how a service-level fault looks in Jaeger and Prometheus before you pull a trace for it.
