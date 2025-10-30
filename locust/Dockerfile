FROM locustio/locust
ENV LOCUST_SKIP_MONKEY_PATCH="1"
RUN pip3 install boto3==1.34.89 botocore==1.34.89 urllib3 prometheus_client rich==13.7.1
# install only binary wheels
# COPY locust/requirements.txt /tmp/
# RUN pip install --only-binary=:all: -r /tmp/requirements.txt
# Copy your project files
COPY locust/resources /mnt/locust/
WORKDIR /mnt/locust

# Default command
# CMD ["locust", "-f", "locustfile.py"]
