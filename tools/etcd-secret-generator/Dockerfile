FROM registry.access.redhat.com/ubi9/ubi-minimal:latest

RUN microdnf install -y coreutils-single && microdnf clean all

COPY generate-secrets.sh /usr/local/bin/generate-secrets.sh
RUN chmod +x /usr/local/bin/generate-secrets.sh

ENV SECRET_SIZE_BYTES=524288 \
    SECRET_PREFIX=pressure-test \
    NAMESPACE=default \
    KUBEAPI_HOST=https://kubernetes.default.svc \
    CONCURRENCY=3 \
    MAX_SECRETS=0

ENTRYPOINT ["/usr/local/bin/generate-secrets.sh"]
