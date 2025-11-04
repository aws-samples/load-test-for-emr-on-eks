FROM locustio/locust
# ENV LOCUST_SKIP_MONKEY_PATCH="1"
# USER root
# RUN apt-get update && apt-get install -y ca-certificates
RUN python3 -m pip install --upgrade pip
# RUN pip3 install urllib3 prometheus_client==0.21.0 boto3==1.40.64 botocore==1.40.64 rich==13.7.1
COPY locust/requirements.txt /tmp/
RUN pip3 install --only-binary=:all: -r /tmp/requirements.txt
# Copy your project files
COPY locust/resources /mnt/locust/
WORKDIR /mnt/locust

# Default command
# CMD ["locust", "-f", "locustfile.py", "-t", "60m"]
