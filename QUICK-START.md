# 🚀 Quick Start Guide
## LLM-Powered Spark Job Management System

### ⚡ Super Simple Setup (4 Commands)

```bash
# 1. Deploy everything (EKS, AI agents, SQS, Prometheus, Grafana, Locust)
./setup.sh

# 2. Run demo (10 cost-optimized jobs)
./demo.sh

# 3. Check results
./stats.sh

# 4. Clean up everything
./cleanup.sh
```

---

## 📋 What Gets Deployed

### 🏗️ Infrastructure
- **EKS Cluster** with Spark Operators
- **AI Agents** with Claude 3.5 Sonnet LLM
- **SQS Priority Queues** (High/Medium/Low + DLQ)
- **Prometheus & Grafana** monitoring
- **Karpenter** auto-scaling
- **Locust** load testing (EC2 + Kubernetes)

### 🤖 AI-Powered Features
- **Intelligent job scheduling** based on cluster health
- **Priority-based processing** (High → Medium → Low)
- **Automatic retries** and failure handling
- **Rich metadata tracking** (organizations, projects, priorities)

---

## 🎯 Available Commands

### Essential Commands
```bash
./setup.sh      # Deploy complete system
./demo.sh       # Submit 10 demo jobs
./stats.sh      # Check queue & job statistics
./cleanup.sh    # Remove everything
```

### Advanced Commands
```bash
./load-test.sh 10 2 5m    # Custom load test
./status.sh               # Detailed system status
```

---

## 📊 Monitoring & Access

### Locust Load Testing
```bash
kubectl port-forward svc/locust-master 8089:8089 -n locust
# Open: http://localhost:8089
```

### Prometheus Monitoring
```bash
kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 -n prometheus
# Open: http://localhost:9090
```

### Grafana Dashboard
- **Amazon Managed Grafana** (configured automatically)
- Access via AWS Console → Grafana → Your workspace

---

## 💰 Cost Optimization

### Demo Jobs (Cost-Optimized)
- **10 jobs maximum** per demo
- **2 executors** per job (instead of 4-8)
- **512MB memory** per container (instead of 1-4GB)
- **Small workload** (SparkPi with 10 iterations)

### Load Testing
- Use small parameters: `./load-test.sh 5 1 2m`
- Monitor costs with AWS Cost Explorer

---

## 🏢 Job Metadata Examples

The system tracks rich metadata for realistic enterprise scenarios:

### Organizations
- **DataCorp Analytics** (org-a) - Premium tier
- **TechStart Solutions** (org-b) - Standard tier  
- **Research Institute** (org-c) - Basic tier
- **Financial Services** (org-d) - Premium tier
- **Healthcare Systems** (org-e) - Standard tier

### Projects
- **Alpha** - Data Processing
- **Beta** - ML Training
- **Gamma** - Analytics
- **Delta** - ETL Pipeline
- **Epsilon** - Reporting
- **Zeta** - Real-time Processing

### Priorities
- **🔴 High** - Processed first (premium customers)
- **🟡 Medium** - Standard processing
- **🟢 Low** - Background processing

---

## 🔧 Troubleshooting

### Common Issues
1. **Setup fails**: Check AWS credentials and permissions
2. **Jobs stuck**: Run `./stats.sh` to check queue status
3. **High costs**: Use demo mode and small load tests only

### Debug Commands
```bash
kubectl get pods --all-namespaces    # Check all pods
kubectl logs -n spark-agents deployment/scheduler-agent    # AI agent logs
aws sqs get-queue-attributes --queue-url <url> --attribute-names All    # Queue status
```

---

## 🎉 Success Indicators

After running `./demo.sh`, you should see:
- ✅ Jobs distributed across 5 organizations
- ✅ Multiple projects (Alpha, Beta, Gamma, etc.)
- ✅ Priority-based processing (High → Medium → Low)
- ✅ 100% success rate
- ✅ Rich metadata in job names

**Example output from `./stats.sh`:**
```
🏢 Jobs by Organization:
   📊 DataCorp Analytics (org-a): 3 jobs
   🏭 TechStart Solutions (org-b): 2 jobs
   🔬 Research Institute (org-c): 1 job

🎯 Jobs by Priority:
   🔴 High Priority: 4 jobs
   🟡 Medium Priority: 3 jobs
   🟢 Low Priority: 1 job
```

---

## 📞 Support

- Check the main [README.md](README.md) for detailed documentation
- Review AWS costs regularly
- Use cost-optimized settings for testing

**Happy load testing with LLM-powered job management!** 🚀
