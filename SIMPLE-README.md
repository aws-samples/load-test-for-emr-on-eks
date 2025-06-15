# 🚀 LLM-Powered Spark Job Management System

## ⚡ Quick Start (4 Simple Commands)

```bash
./setup.sh      # Deploy everything
./demo.sh       # Run demo jobs  
./stats.sh      # Check results
./cleanup.sh    # Remove everything
```

## 📋 What You Get

- **🤖 AI-Powered Job Scheduling** with Claude 3.5 Sonnet
- **📊 Priority-Based Processing** (High → Medium → Low)
- **🏢 Rich Metadata Tracking** (5 organizations, 6 projects)
- **📈 Complete Monitoring** (Prometheus + Grafana)
- **🧪 Load Testing** with Locust
- **💰 Cost-Optimized** (2 executors, 512MB per job)

## 🎯 File Structure

### Essential Scripts
```
./setup.sh      # Deploy complete system (EKS, AI agents, SQS, monitoring)
./demo.sh       # Submit 10 cost-optimized demo jobs
./stats.sh      # Show queue status and job metadata
./cleanup.sh    # Remove all AWS resources
```

### Advanced Scripts  
```
./load-test.sh  # Custom Locust load testing
./status.sh     # Detailed system health check
```

### Configuration
```
env.sh          # Environment variables
```

### Infrastructure (Internal)
```
infra-provision.sh    # Main infrastructure deployment
locust-provision.sh   # Locust EC2 setup
```

## 🏢 Demo Job Metadata

The system simulates realistic enterprise scenarios:

### Organizations
- **DataCorp Analytics** (org-a) - Premium
- **TechStart Solutions** (org-b) - Standard  
- **Research Institute** (org-c) - Basic
- **Financial Services** (org-d) - Premium
- **Healthcare Systems** (org-e) - Standard

### Projects
- **Alpha** - Data Processing
- **Beta** - ML Training  
- **Gamma** - Analytics
- **Delta** - ETL Pipeline
- **Epsilon** - Reporting
- **Zeta** - Real-time Processing

## 📊 Example Usage

```bash
# 1. Deploy system
./setup.sh

# 2. Run demo
./demo.sh
# Output: 10 jobs across 5 organizations, 3 priority levels

# 3. Check results  
./stats.sh
# Shows: org-a: 3 jobs, org-b: 2 jobs, etc.

# 4. Custom load test
./load-test.sh 20 5 10m
# 20 users, 5 spawn rate, 10 minutes

# 5. Clean up
./cleanup.sh
# Removes everything automatically
```

## 💰 Cost Optimization

- **Max 10 jobs** per demo
- **2 executors** per job (not 4-8)
- **512MB memory** per container (not 1-4GB)
- **Small workloads** (SparkPi with 10 iterations)
- **~70% cost reduction** vs default settings

## 🎉 Success Example

After `./demo.sh`:
```
🏢 Jobs by Organization:
   📊 DataCorp Analytics (org-a): 3 jobs
   🏭 TechStart Solutions (org-b): 2 jobs
   🔬 Research Institute (org-c): 1 job

🎯 Jobs by Priority:
   🔴 High Priority: 4 jobs
   🟡 Medium Priority: 3 jobs  
   🟢 Low Priority: 1 job

📈 Job Status:
   ✅ Completed: 8 jobs (100% success rate)
```

## 🔧 Troubleshooting

- **Setup fails**: Check AWS credentials
- **Jobs stuck**: Run `./stats.sh` 
- **High costs**: Use demo mode only
- **Cleanup issues**: Re-run `./cleanup.sh`

---

**Simple, powerful, and cost-effective LLM-powered Spark job management!** 🚀
