FROM locustio/locust:2.42.1 AS locust
USER root
RUN apt-get update && \
    apt-get install -y curl unzip tar gzip && \
    rm -rf /var/lib/apt/lists/*

# Install AWS CLI v2 with multi-platform support
RUN ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "amd64" ]; then \
        AWS_ARCH="x86_64"; KUBE_ARCH="amd64"; EKSCTL_ARCH="amd64"; \
    elif [ "$ARCH" = "arm64" ]; then \
        AWS_ARCH="aarch64"; KUBE_ARCH="arm64"; EKSCTL_ARCH="arm64"; \
    else echo "Unsupported architecture: $ARCH" && exit 1; fi && \
    # install AWS CLIv2
    curl "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli --update && \
     # Install kubectl
    curl -LO "dl.k8s.io/release/$(curl -L -s dl.k8s.io/release/stable.txt)/bin/linux/${KUBE_ARCH}/kubectl" && \
    chmod +x kubectl && mv kubectl /usr/local/bin/ && \
    # Install eksctl
    curl --silent --location "github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_${EKSCTL_ARCH}.tar.gz" | tar xz -C /tmp && \
    mv /tmp/eksctl /usr/local/bin/

# redirect aws dir to a writable location
ENV AWS_CONFIG_DIR=/opt/venv/.aws
ENV HOME=/opt/venv
RUN mkdir -p /opt/venv/.aws && chown -R locust:locust /opt/venv/.aws
# Create Python virtual environment
RUN python -m venv /opt/venv/bin
ENV PATH="/opt/venv/bin:$PATH"
RUN pip3 install urllib3 prometheus_client==0.21.0 boto3==1.40.64 botocore==1.40.64 rich==13.7.1
COPY locust/locustfiles/lib /opt/venv/bin/lib
RUN chown -R locust:locust /opt/venv/bin

WORKDIR /opt/venv
USER locust