# etcd Secret Generator

Generates large Kubernetes Secrets to simulate customer-induced etcd disk pressure. Each Secret contains a random payload, creating realistic etcd storage growth as would happen with a misconfigured operator, CI/CD pipeline, or certificate rotation issue.

## Build

```bash
podman build -t quay.io/cveiga/etcd-secret-generator:latest .
podman push quay.io/cveiga/etcd-secret-generator:latest
```

## Usage

Run from a context with access to the hosted cluster (customer perspective).

### Setup

```bash
kubectl create namespace etcd-pressure-test

kubectl create rolebinding etcd-secret-generator \
  --namespace=etcd-pressure-test \
  --clusterrole=edit \
  --serviceaccount=etcd-pressure-test:default
```

### Generate ~500MB (quick test)

```bash
kubectl run etcd-secret-generator \
  --namespace=etcd-pressure-test \
  --image=quay.io/cveiga/etcd-secret-generator:latest \
  --env="NAMESPACE=etcd-pressure-test" \
  --env="MAX_SECRETS=1000" \
  --restart=Never
```

### Generate ~4GB

```bash
kubectl run etcd-secret-generator \
  --namespace=etcd-pressure-test \
  --image=quay.io/cveiga/etcd-secret-generator:latest \
  --env="NAMESPACE=etcd-pressure-test" \
  --env="MAX_SECRETS=8000" \
  --restart=Never
```

### Monitor progress

```bash
kubectl logs -f etcd-secret-generator -n etcd-pressure-test
```

### Cleanup

Delete the namespace to remove all Secrets, pods, and role bindings:

```bash
kubectl delete namespace etcd-pressure-test
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| SECRET_SIZE_BYTES | 524288 (500KB) | Size of each Secret's data payload |
| SECRET_PREFIX | pressure-test | Name prefix for generated Secrets |
| NAMESPACE | default | Namespace to create Secrets in |
| MAX_SECRETS | 0 (unlimited) | Stop after this many Secrets |
| CONCURRENCY | 3 | Number of parallel requests |

## Estimates

At ~20 Secrets/second (concurrency 3, 500KB each):

| Target | Secrets | Time |
|--------|---------|------|
| 500MB | 1,000 | ~1 min |
| 1GB | 2,000 | ~2 min |
| 4GB | 8,000 | ~7 min |

## Important

- **Do not use 1MB Secrets** — this can OOM-kill the API server.
- **Start small** — test with 500-1000 Secrets first to validate cluster stability.
- **Monitor the cluster** — watch for API server restarts or etcd memory spikes.
- If the cluster becomes unstable, deleting the namespace will remove all generated Secrets.
