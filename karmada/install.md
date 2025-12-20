### prepare
1. 优先使用linux或者macos系统，wsl2网络问题较多，不建议使用
2. docker-desktop enabled kubernetes
3. kind installed
4. go installed
5. kubectl 插件化配置，如，krew、kubecm等
6. helm installed

### step1 准备多个集群
创建多个k8s集群，docker-desktop默认集群作为control-plane，另外创建3个kind集群作为业务集群
```bash
kind create cluster -n member-1
kind create cluster -n member-2
kind create cluster -n member-3
```

kind默认安装好之后，当前应该有4个集群

使用 kubectl kc 调整自己的集群上下文

### step2 安装控制面

安装karmada，选择 helm+karmada operator的方式安装

```bash
# 添加karmada helm仓库
helm repo add karmada-charts https://raw.githubusercontent.com/karmada-io/karmada/master/charts
helm repo update
mkdir charts && cd charts
heml pull karmada-operator karmada-charts/karmada-operator --untar
helm install karmada-operator karmada-charts/karmada-operator -n karmada-system --create-namespace -f ./karmada-
operator/values.yaml

# 查看安装状态
NAME: karmada-operator
LAST DEPLOYED: Sat Dec 20 15:17:03 2025
NAMESPACE: karmada-system
STATUS: deployed
REVISION: 1
DESCRIPTION: Install complete
TEST SUITE: None
NOTES:
Thank you for installing karmada-operator.

Your release is named karmada-operator.

To learn more about the release, try:

  $ helm status karmada-operator -n karmada-system
  $ helm get all karmada-operator -n karmada-system            
```

karmada的部署控制器已经安装完成，只需要下发karmada cr就可以了

cr yaml链接在[这里](https://github.com/karmada-io/karmada/blob/master/operator/config/samples/karmada.yaml)

```bash
kubectl apply -f ./karmada/config/deploy
kubectl apply -f ./karmada/config/crds
```

查看karmada的pod状态
```bash
kubectl get pods -n karmada-system
```

生成karmada的kubeconfig

```bash
kubectl get secret -n karmada-system karmada-demo-admin-config -o jsonpath="{.data.karmada\.config}" | base64 -d > ~/.kube/karmada-apiserver.config
```

使用kubectl kc合并kubeconfig
```bash
kubectl kc merge -f ~/.kube/ ## 这个命令默认合并到 ~/.kube/config中，是否覆盖选true就可以了
```
‼️ 建议将karmada的kubeconfig中的ip地址替换为localhost，避免网络不通的问题，特别是开了代理的情况下，如果也不通，看看是不是这个ip被代理了

### step3 加入成员集群