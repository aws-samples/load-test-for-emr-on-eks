FROM locustio/locust

USER root
# install eks tools
RUN apt-get update && \
    apt-get install -y curl tar gzip && \
    rm -rf /var/lib/apt/lists/*
RUN apt-get update && \
    apt-get install -y curl tar gzip && \
    rm -rf /var/lib/apt/lists/*
RUN curl -LO https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl \
    && chmod +x kubectl \
    && mv kubectl /usr/local/bin/kubectl
RUN curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp && \
    mv /tmp/eksctl /usr/local/bin  

# Enable venv
RUN python -m venv /opt/venv/bin
ENV PATH="/opt/venv/bin:$PATH"
RUN pip3 install urllib3 prometheus_client==0.21.0 boto3==1.40.64 botocore==1.40.64 rich==13.7.1
# Copy project files
COPY locust/locustfiles/lib /opt/venv/bin/lib
RUN chown -R locust:locust /opt/venv/bin
WORKDIR /home/locust
USER locust

# Default command
# CMD ["locust", "-f", "locustfile.py", "-t", "60m"]