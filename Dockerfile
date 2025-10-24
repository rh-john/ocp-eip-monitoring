# Optimized EIP Monitoring container
FROM registry.access.redhat.com/ubi9/python-312:latest

# Switch to root to install packages
USER root

# Install required packages (Python 3.12 and pip are already included)
# Use --allowerasing to replace conflicting packages like curl-minimal with curl
RUN dnf update -y && \
    dnf install -y --allowerasing \
    curl \
    ca-certificates \
    procps-ng \
    && dnf clean all

# Install Python packages for metrics server
RUN pip3 install --no-cache-dir \
    prometheus-client==0.17.1 \
    flask==2.3.3 \
    requests==2.31.0

# Install OpenShift CLI (using the generic stable link)
RUN curl -L https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz \
    -o /tmp/openshift-client-linux.tar.gz && \
    tar -xzf /tmp/openshift-client-linux.tar.gz -C /usr/local/bin/ oc kubectl && \
    chmod +x /usr/local/bin/oc /usr/local/bin/kubectl && \
    rm -f /tmp/openshift-client-linux.tar.gz

# Create app directory
WORKDIR /app

# Copy application files
COPY src/metrics_server.py /app/
COPY src/entrypoint.sh /app/

# Make scripts executable
RUN chmod +x /app/*.sh

# Set up permissions for OpenShift compatibility
RUN chown -R 1001:0 /app && \
    chmod -R g=u /app && \
    mkdir -p /app/runs /app/metrics && \
    chown -R 1001:0 /app/runs /app/metrics && \
    chmod -R g=u /app/runs /app/metrics

# Use a non-root user
USER 1001

# Expose metrics port
EXPOSE 8080

# Health check handled by OpenShift/Kubernetes instead of container
# (OCI format doesn't support HEALTHCHECK, so we rely on k8s health checks)

# Set entrypoint
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["server"]
