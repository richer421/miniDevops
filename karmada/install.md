### prepare
1. mac os, 以下操作均在mac os下进行
2. docker-desktop enabled kubernetes
3. kind installed
4. go installed
5. kubectl 插件化配置，如，krew、kubecm等
6. helm installed

### step1 准备多个集群
创建多个k8s集群，docker-desktop默认集群作为control-plane，另外创建3个kind集群作为业务集群
```bash
## 创建集群时，先unset掉各种代理，避免网络问题，不然默认会将代理信息也写到容器环境中
kind create cluster -n member-1
kind create cluster -n member-2
kind create cluster -n member-3
```

kind默认安装好之后，当前应该有4个集群

使用 kubectl kc 调整自己的集群上下文

### step2 安装控制面

安装karmada，选择 helm 安装方式，不推荐 operator 方式，operator 模式未提供 agent 的安装方式
也不推荐使用 karmadactl 安装方式，无法自定义镜像

```bash
# 添加helm仓库
helm repo add karmada-charts https://raw.githubusercontent.com/karmada-io/karmada/master/charts

elm repo list
NAME            URL
karmada-charts   https://raw.githubusercontent.com/karmada-io/karmada/master/charts

helm repo update
```


```bash
# 下载 karmada chart
helm search repo karmada-charts
NAME                            CHART VERSION   APP VERSION     DESCRIPTION                      
karmada-charts/karmada          v1.16.0         v1.16.0         A Helm chart for karmada         
karmada-charts/karmada-operator v1.16.0         v1.16.0         A Helm chart for karmada-operator


helm pull karmada-charts/karmada --version v1.16.0 --untar --untardir ./charts 

# 切换到正确的集群上下文中
kubectl kc switch

# 安装 karmada 控制面, 安装之前，将 "host.docker.internal" 添加到 values.yaml 的 certs.auto.hosts 中，防止网络不通
helm install karmada karmada-charts/karmada -f ./charts/karmada/values.yaml \
     --namespace karmada-system --create-namespace --set apiServer.serviceType=NodePort 
     
# output
NAME: karmada
LAST DEPLOYED: Sun Dec 21 11:13:06 2025
NAMESPACE: karmada-system
STATUS: deployed
REVISION: 1
DESCRIPTION: Install complete
TEST SUITE: None

# 查看安装状态
kubectl -n karmada-system get pods

# output
NAME                                               READY   STATUS    RESTARTS   AGE
etcd-0                                             1/1     Running   0          30s
karmada-aggregated-apiserver-657696b848-g5pzs      1/1     Running   0          30s
karmada-apiserver-589d7d9cff-jc2ph                 1/1     Running   0          30s
karmada-controller-manager-5f9b7db9b7-mkpsv        1/1     Running   0          30s
karmada-kube-controller-manager-75ddf9fcc6-fw9zx   1/1     Running   0          30s
karmada-scheduler-96f885fc-6nsg9                   1/1     Running   0          30s
karmada-webhook-759bccf697-tsr4r                   1/1     Running   0          30s
```
控制面安装完成后，需要生成karmada-apiserver的访问配置文件kubeconfig，后续注册集群需要使用
```bash
# 生成karmada-apiserver的kubeconfig文件
kubectl get secret -n karmada-system karmada-kubeconfig -o jsonpath={.data.kubeconfig} | base64 -d > ~/.kube/karmada-apiserver.config
# 先修改一下当前的kubeconfig的endpoint，ip为127.0.0.1，端口为NodePort端口，然后merge到当前的kubeconfig中
kubectl kc merge -f ~/.kube/
```

### step3 注册成员集群

核心要修改的部分如下
```yaml
## @param installMode "host" and "agent" are provided
## "host" means install karmada in the control-cluster
## "agent" means install agent client in the member cluster
## "component" means install selected components in the control-cluster
installMode: "agent"

## agent client config
agent:
  ## @param agent.clusterName name of the member cluster
  clusterName: ""
  ## @param agent.clusterEndpoint server endpoint of the member cluster
  clusterEndpoint: ""
  ## kubeconfig of the karmada
  kubeconfig:
    ## @param agent.kubeconfig.caCrt ca of the certificate
    caCrt: |
      -----BEGIN CERTIFICATE-----
      XXXXXXXXXXXXXXXXXXXXXXXXXXX
      -----END CERTIFICATE-----
    ## @param agent.kubeconfig.crt crt of the certificate
    crt: |
      -----BEGIN CERTIFICATE-----
      XXXXXXXXXXXXXXXXXXXXXXXXXXX
      -----END CERTIFICATE-----
    ## @param agent.kubeconfig.key key of the certificate
    key: |
      -----BEGIN RSA PRIVATE KEY-----
      XXXXXXXXXXXXXXXXXXXXXXXXXXX
      -----END RSA PRIVATE KEY-----
    ## @param agent.kubeconfig.server apiserver of the karmada
    server: ""
```

```bash
# 执行extract-certs.sh脚本，方便后续填写证书信息
/bin/bash ./karmada/scripts/extract_certs.sh 

# 切换到 member-1 集群上下文

# 注册 member-1 集群
helm install karmada-agent karmada-charts/karmada \
     --namespace karmada-system --create-namespace \
     --set installMode=agent \
     --set-file agent.kubeconfig.caCrt=$HOME/.kube/karmada-certs/ca.crt \
     --set-file agent.kubeconfig.crt=$HOME/.kube/karmada-certs/client.crt \
     --set-file agent.kubeconfig.key=$HOME/.kube/karmada-certs/client.key \
     --set agent.clusterName=member-1 \
     --set agent.clusterEndpoint=https://host.docker.internal:54904 \
     --set agent.kubeconfig.server=https://host.docker.internal:30160 ## 这里比较特殊，容器网络内交互，需要使用docker-desktop的ip地址

# 查看安装状态ß
kubectl get pods -n karmada-agent-system
NAME                             READY   STATUS    RESTARTS   AGE
karmada-agent-7df888b566-rcg9k   1/1     Running   0          26s
```

# 尝试验证
```bash
# 切换到控制面集群上下文
kubectl kc switch
kubectl apply -f ./karmada/test/deployment.yaml
kubectl apply -f ./karmada/test/propagationpolicy.yaml
```
# 这个时候，查看应该就已经部署到 member-1 集群中了
# 如果出现问题，一般是文档遗漏了某些步骤，可以参考官方文档进行排查



# 后续，部署其他 member 集群了

