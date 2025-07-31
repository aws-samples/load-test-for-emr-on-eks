## Locust EC2 Server User Manual to submit jobs to SQS

### Access EC2 server for load testing
1. SSH to EC2

``` bash
===============================================
To connect to the instance use: ssh -i eks-load-test-xxxxxx-locust-key.pem ec2-user@xxx.xxx.xxx.xxx
===============================================
```

2. Install the package dependency:
```bash

cd load-test/locust/

pip install -r requirements.txt 

```

3. Source the env varibles
```bash
source env.sh 

export SQS_QUEUE_URL=$(aws sqs get-queue-url \
  --queue-name "$SQS_QUEUE_NAME" \
  --region "$AWS_REGION" \
  --query 'QueueUrl' \
  --output text)

```

4. Submit jobs to SQS via locust:
```bash

locust -f ./locustfile.py   --sqs-queue-url "$SQS_QUEUE_URL"   --aws-region us-west-2   --job-name sqs-spark-job   --job-ns-count 2   --job-azs '["us-west-2a", "us-west-2b"]'   -u 5   -t 10m   --headless   --skip-log-setup

```





## Clean up
```bash
# To remove all the messages from SQS:

aws sqs purge-queue \
  --queue-url "$SQS_QUEUE_URL" \
  --region "$AWS_REGION"


# To remove all the SparkApplications:

kubectl delete sparkapplications --all --all-namespaces

```


## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the LICENSE file.

