FROM locustio/locust
# ENV LOCUST_SKIP_MONKEY_PATCH=1

USER root
RUN apt-get update && \
    apt-get install -y curl tar gzip && \
    rm -rf /var/lib/apt/lists/*
USER root
RUN apt-get update && \
    apt-get install -y curl tar gzip && \
    rm -rf /var/lib/apt/lists/*
RUN curl -LO https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl \
    && chmod +x kubectl \
    && mv kubectl /usr/local/bin/kubectl
RUN curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp && \
    mv /tmp/eksctl /usr/local/bin  
      
RUN python -m venv /opt/venv
# Enable venv
ENV PATH="/opt/venv/bin:$PATH"
# ENV LOCUST_LIB_PATH="/home/locust"
RUN pip3 install urllib3 prometheus_client==0.21.0 boto3==1.40.64 botocore==1.40.64 rich==13.7.1
WORKDIR /home/locust
# COPY locust/requirements.txt /tmp/
# RUN pip install --upgrade pip setuptools wheel truststore certifi && \
#  pip install -Ur /tmp/requirements.txt
# Copy your project files
COPY locust/locustfiles/lib /home/locust/lib
COPY locust/locustfiles/resources /home/locust/resources
ENV PYTHONPATH="/home/locust"

# RUN chown -R root:root /home/locust

# Default command
# CMD ["locust", "-f", "locustfile.py", "-t", "60m"]
