#!/bin/bash

# 检查参数
if [ "$1" != "start" ] && [ "$1" != "sleep" ]; then
  echo "用法: ./ng_operation [start|sleep]"
  echo "  start: 设置节点组为运行状态 (根据类型设置不同的最大节点数)"
  echo "  sleep: 设置所有节点组为休眠状态 (min=0, desired=0)"
  exit 1
fi

# 使用已设置的集群名称
CLUSTER_NAME="eks-load-test-e543"

# 获取所有 Node Group 名称
NODE_GROUPS=$(aws eks list-nodegroups --cluster-name $CLUSTER_NAME --query 'nodegroups[*]' --output text)

# 根据参数执行不同的操作
if [ "$1" == "start" ]; then
  # 启动模式 - 根据节点组类型设置不同配置
  echo "正在将节点组设置为运行状态..."
  
  for NG in $NODE_GROUPS; do
    if [[ $NG == *"worker"* ]]; then
      echo "正在更新 worker Node Group: $NG (min=1, desired=1, max=350)"
      aws eks update-nodegroup-config \
        --cluster-name $CLUSTER_NAME \
        --nodegroup-name $NG \
        --scaling-config minSize=1,maxSize=350,desiredSize=1
    
    elif [[ $NG == *"operational"* ]]; then
      echo "正在更新 operational Node Group: $NG (min=1, desired=1, max=3)"
      aws eks update-nodegroup-config \
        --cluster-name $CLUSTER_NAME \
        --nodegroup-name $NG \
        --scaling-config minSize=1,maxSize=3,desiredSize=1
    
    elif [[ $NG == *"sparkoperator"* ]]; then
      echo "正在更新 sparkoperator Node Group: $NG (min=1, desired=1, max=20)"
      aws eks update-nodegroup-config \
        --cluster-name $CLUSTER_NAME \
        --nodegroup-name $NG \
        --scaling-config minSize=1,maxSize=20,desiredSize=1
    
    else
      echo "跳过未匹配的 Node Group: $NG"
    fi
  done

elif [ "$1" == "sleep" ]; then
  # 休眠模式 - 将所有节点组设置为 min=0, desired=0
  echo "正在将所有节点组设置为休眠状态..."
  
  for NG in $NODE_GROUPS; do
    # 获取当前节点组的最大节点数，保持不变
    MAX_SIZE=$(aws eks describe-nodegroup --cluster-name $CLUSTER_NAME --nodegroup-name $NG --query 'nodegroup.scalingConfig.maxSize' --output text)
    
    echo "正在更新 Node Group: $NG (min=0, desired=0, max=$MAX_SIZE)"
    aws eks update-nodegroup-config \
      --cluster-name $CLUSTER_NAME \
      --nodegroup-name $NG \
      --scaling-config minSize=0,maxSize=$MAX_SIZE,desiredSize=0
  done
fi

echo "所有 Node Group 已更新完成"
