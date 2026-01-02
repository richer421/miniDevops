# karmada-aggregate-apiserver 学习笔记

## 核心功能

- **一句话概括**：通过 Kubernetes 原生 apiserver 构建方法，构建了管理自定义资源 cluster 的 apiserver 服务器，实现对自定义资源 `Cluster` 的统一访问入口（非直接管理集群）。

## 关键机制

1. **APIService 机制**
   - 主 Kubernetes APIServer 通过 `APIService` 资源将请求动态转发到 `karmada-aggregate-apiserver`（核心：主 APIServer → karmada-aggregate-apiserver）。
2. **Cluster 聚合访问**
   - `Cluster` CRD（自定义资源）在 `karmada-aggregate-apiserver` 中定义，通过 APIService 统一暴露到主集群 API，实现跨集群资源查询/操作。

## 为何用 APIService 而非 CRD？（关键澄清）

> CRD 仅定义资源结构（如 `Cluster` 的字段、验证规则），Kubernetes API Server 会自动提供基础 REST API 端点（如 `GET /apis/cluster.karmada.io/v1/clusters`），但**无法自定义请求转发逻辑**。所有请求由 kube-apiserver 直接处理，无法实现跨集群请求转发。**正确机制**：
>
> - CRD 仅提供资源定义，**不包含业务逻辑**。
> - APIService 机制通过注册 `APIService` 资源，将请求动态路由到后端服务（如 `karmada-aggregate-apiserver`），由后端服务实现自定义转发逻辑（如将请求转发至目标集群的 APIServer）。

## 核心实现

1. **启动独立 APIServer**
   - `karmada-aggregate-apiserver` 基于 K8s 原生 APIServer 框架启动。
2. **注册 Cluster CRD**
   - 在 `karmada-aggregate-apiserver` 中定义 `Cluster` 自定义资源（结构定义）。
3. **注册 APIService**
   - 在主 Kubernetes 集群中创建 `APIService` 资源，指向 `karmada-aggregate-apiserver`。
4. **请求处理流程**
   - 用户发起 `GET /clusters` 请求 → 主 APIServer 通过 APIService 转发至 `karmada-aggregate-apiserver` → `karmada-aggregate-apiserver` 将请求转发至目标集群 APIServer → 目标集群响应返回 → 最终结果返回给用户。

## K8s REST 实现机制

- **REST 接口**：K8s API Server 通过 RESTful 接口（如 `Get`/`List`）处理请求。
- **APIService 关键作用**：
  `APIService` 对象的 `REST Connector` 实现**请求动态路由**，将集群请求转发至 `karmada-aggregate-apiserver`，由后者实现跨集群转发逻辑。

在Kubernetes中，为资源生成RESTful API主要有两种路径：


| 对比维度              | **CRD模式** (Custom Resource Definition)                                              | **聚合API服务器模式** (AA, Karmada所用)                                                                 |
| --------------------- | ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| **本质**              | **声明式**：向K8s主API服务器注册一个“新表结构”。                                    | **编程式**：启动一个独立的、实现了完整API服务器的进程。                                                 |
| **REST端点生成**      | **全自动生成**：K8s主API服务器根据CRD的Schema，使用**通用代码**自动生成全套CRUD端点。 | **半自动生成**：开发者实现`rest.Storage`接口，K8s的`genericapiserver`框架根据实现**自动绑定HTTP路由**。 |
| **业务逻辑位置**      | 无内置逻辑。需通过**Webhook**（准入、验证、转换）注入。                               | **内置在REST Storage实现中**，直接编码`Create`, `Get`等方法。                                           |
| **Connect等特殊接口** | **无法实现**。仅限标准CRUD。                                                          | **可以实现**，通过实现`rest.Connecter`等扩展接口。                                                      |
| **性能与耦合度**      | 与主API服务器同进程，性能好，但逻辑分离。                                             | 独立进程，有网络开销，但**业务逻辑完全自主**。                                                          |

### 🔧 CRD模式：自动生成的“空壳”接口

当您创建一个CRD时，K8s主API服务器会像操作一张新的数据库表一样，为它**自动生成全套标准的REST端点**。

#### **1. 生成的接口列表（以 `yourresources.yourgroup.com` 为例）**

这些端点是 **“凭空”** 生成的，您无需编写任何Go代码：


| HTTP方法   | 路径                                                          | 对应操作 | 实现方式                   |
| ---------- | ------------------------------------------------------------- | -------- | -------------------------- |
| **POST**   | `/apis/yourgroup.com/v1/namespaces/{ns}/yourresources`        | 创建     | 通用代码，将JSON存入etcd   |
| **GET**    | `/apis/yourgroup.com/v1/namespaces/{ns}/yourresources`        | 列表     | 通用代码，从etcd查询列表   |
| **GET**    | `/apis/yourgroup.com/v1/namespaces/{ns}/yourresources/{name}` | 获取     | 通用代码，从etcd按key查询  |
| **PUT**    | `/apis/yourgroup.com/v1/namespaces/{ns}/yourresources/{name}` | 更新     | 通用代码，替换etcd中的值   |
| **PATCH**  | `/apis/yourgroup.com/v1/namespaces/{ns}/yourresources/{name}` | 部分更新 | 通用代码，应用JSON Patch等 |
| **DELETE** | `/apis/yourgroup.com/v1/namespaces/{ns}/yourresources/{name}` | 删除     | 通用代码，从etcd删除key    |
| **WATCH**  | `/apis/yourgroup.com/v1/watch/...`                            | 监听变更 | 通用代码，监听etcd事件流   |

#### **2. “无逻辑”的含义**

这些自动生成的接口 **只有最基础的存储逻辑**，相当于一个**智能的键值存储包装器**。它们会：

* 进行基础的JSON/YAML解析。
* 依据CRD中定义的**OpenAPI Schema**（`spec.versions.schema`）进行简单的类型校验。
* 将验证通过的数据**直接存储到etcd**，或从etcd读取。

**它们没有**：

* 复杂的业务校验（如“集群名称不能重复”）。
* 默认值填充（除非使用Schema的`default`字段）。
* 副作用（如创建资源时自动创建其他关联资源）。
* 任何与外部系统交互的逻辑。

#### **3. Connect接口在CRD中完全缺失**

对于需要**建立长连接、流式传输或代理**的操作，如：

* `Exec`（在容器内执行命令）
* `Attach`（附加到容器）
* `PortForward`（端口转发）
* `Proxy`（代理请求）

CRD模式**无法实现**。因为K8s主API服务器无法为它不知道如何处理的资源自动生成这些复杂逻辑。这些操作需要实现 `rest.Connecter` 接口，而这**仅在聚合API服务器模式中可行**。

**CRD模式的高级逻辑只能通过Webhook注入：**


| Webhook类型                      | 触发时机       | 常见用途                              |
| -------------------------------- | -------------- | ------------------------------------- |
| **Mutating Admission Webhook**   | 对象持久化之前 | 注入默认值、修改规格（如注入sidecar） |
| **Validating Admission Webhook** | 对象持久化之前 | 执行复杂的业务规则校验                |
| **Conversion Webhook**           | 多版本转换时   | 在不同API版本间转换资源表示           |

### ⚙️ 三、聚合API服务器模式：基于实现的“绑定式”生成（Karmada采用）

#### **1. 生成机制：接口绑定**

在聚合API服务器中，**开发者需要手动编写REST Storage的实现**。框架 (`genericapiserver`) 会**检查该实现具体满足了`rest.Storage`接口的哪些子集**，然后自动绑定对应的HTTP路由。

这个过程是**“半自动”**的：

* **您负责实现**：业务逻辑的Go方法（`Create`, `Get`等）。
* **框架负责**：生成HTTP路由、处理协议细节、装配中间件链。

在Kubernetes中，为资源生成RESTful API主要有两种路径：


| 对比维度              | **CRD模式** (Custom Resource Definition)                                              | **聚合API服务器模式** (AA, Karmada所用)                                                                 |
| --------------------- | ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| **本质**              | **声明式**：向K8s主API服务器注册一个“新表结构”。                                    | **编程式**：启动一个独立的、实现了完整API服务器的进程。                                                 |
| **REST端点生成**      | **全自动生成**：K8s主API服务器根据CRD的Schema，使用**通用代码**自动生成全套CRUD端点。 | **半自动生成**：开发者实现`rest.Storage`接口，K8s的`genericapiserver`框架根据实现**自动绑定HTTP路由**。 |
| **业务逻辑位置**      | 无内置逻辑。需通过**Webhook**（准入、验证、转换）注入。                               | **内置在REST Storage实现中**，直接编码`Create`, `Get`等方法。                                           |
| **Connect等特殊接口** | **无法实现**。仅限标准CRUD。                                                          | **可以实现**，通过实现`rest.Connecter`等扩展接口。                                                      |
| **性能与耦合度**      | 与主API服务器同进程，性能好，但逻辑分离。                                             | 独立进程，有网络开销，但**业务逻辑完全自主**。                                                          |



| **2. “无 |  |  |  |
| --------- | - | - | - |
|           |  |  |  |
|           |  |  |  |
|           |  |  |  |

**它们没有**：

* 复杂的业务校验（如“集群名称不能重复”）。
* 默认值填充（除非使用Schema的`default`字段）。
* 副作用（如创建资源时自动创建其他关联资源）。
* 任何与外部系统交互的逻辑。

#### **3. Connect接口在CRD中完全缺失**

对于需要**建立长连接、流式传输或代理**的操作，如：

* `Exec`（在容器内执行命令）
* `Attach`（附加到容器）
* `PortForward`（端口转发）
* `Proxy`（代理请求）

CRD模式**无法实现**。因为K8s主API服务器无法为它不知道如何处理的资源自动生成这些复杂逻辑。这些操作需要实现 `rest.Connecter` 接口，而这**仅在聚合API服务器模式中可行**。

**CRD模式的高级逻辑只能通过Webhook注入：**


| Webhook类型                      | 触发时机       | 常见用途                              |
| -------------------------------- | -------------- | ------------------------------------- |
| **Mutating Admission Webhook**   | 对象持久化之前 | 注入默认值、修改规格（如注入sidecar） |
| **Validating Admission Webhook** | 对象持久化之前 | 执行复杂的业务规则校验                |
| **Conversion Webhook**           | 多版本转换时   | 在不同API版本间转换资源表示           |

### ⚙️ 三、聚合API服务器模式：基于实现的“绑定式”生成（Karmada采用）

#### **1. 生成机制：接口绑定**

在聚合API服务器中，**开发者需要手动编写REST Storage的实现**。框架 (`genericapiserver`) 会**检查该实现具体满足了`rest.Storage`接口的哪些子集**，然后自动绑定对应的HTTP路由。

这个过程是**“半自动”**的：

* **您负责实现**：业务逻辑的Go方法（`Create`, `Get`等）。
* **框架负责**：生成HTTP路由、处理协议细节、装配中间件链。

在Kubernetes中，为资源生成RESTful API主要有两种路径：


| 对比维度              | **CRD模式** (Custom Resource Definition)                                              | **聚合API服务器模式** (AA, Karmada所用)                                                                 |
| --------------------- | ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| **本质**              | **声明式**：向K8s主API服务器注册一个“新表结构”。                                    | **编程式**：启动一个独立的、实现了完整API服务器的进程。                                                 |
| **REST端点生成**      | **全自动生成**：K8s主API服务器根据CRD的Schema，使用**通用代码**自动生成全套CRUD端点。 | **半自动生成**：开发者实现`rest.Storage`接口，K8s的`genericapiserver`框架根据实现**自动绑定HTTP路由**。 |
| **业务逻辑位置**      | 无内置逻辑。需通过**Webhook**（准入、验证、转换）注入。                               | **内置在REST Storage实现中**，直接编码`Create`, `Get`等方法。                                           |
| **Connect等特殊接口** | **无法实现**。仅限标准CRUD。                                                          | **可以实现**，通过实现`rest.Connecter`等扩展接口。                                                      |
| **性能与耦合度**      | 与主API服务器同进程，性能好，但逻辑分离。                                             | 独立进程，有网络开销，但**业务逻辑完全自主**。                                                          |

### 🔧 二、CRD模式：自动生成的“空壳”接口

当您创建一个CRD时，K8s主API服务器会像操作一张新的数据库表一样，为它**自动生成全套标准的REST端点**。

#### **1. 生成的接口列表（以 `yourresources.yourgroup.com` 为例）**

这些端点是 **“凭空”** 生成的，您无需编写任何Go代码：


| HTTP方法   | 路径                                                          | 对应操作 | 实现方式                   |
| ---------- | ------------------------------------------------------------- | -------- | -------------------------- |
| **POST**   | `/apis/yourgroup.com/v1/namespaces/{ns}/yourresources`        | 创建     | 通用代码，将JSON存入etcd   |
| **GET**    | `/apis/yourgroup.com/v1/namespaces/{ns}/yourresources`        | 列表     | 通用代码，从etcd查询列表   |
| **GET**    | `/apis/yourgroup.com/v1/namespaces/{ns}/yourresources/{name}` | 获取     | 通用代码，从etcd按key查询  |
| **PUT**    | `/apis/yourgroup.com/v1/namespaces/{ns}/yourresources/{name}` | 更新     | 通用代码，替换etcd中的值   |
| **PATCH**  | `/apis/yourgroup.com/v1/namespaces/{ns}/yourresources/{name}` | 部分更新 | 通用代码，应用JSON Patch等 |
| **DELETE** | `/apis/yourgroup.com/v1/namespaces/{ns}/yourresources/{name}` | 删除     | 通用代码，从etcd删除key    |
| **WATCH**  | `/apis/yourgroup.com/v1/watch/...`                            | 监听变更 | 通用代码，监听etcd事件流   |

#### **2. “无逻辑”的含义**

这些自动生成的接口 **只有最基础的存储逻辑**，相当于一个**智能的键值存储包装器**。它们会：

* 进行基础的JSON/YAML解析。
* 依据CRD中定义的**OpenAPI Schema**（`spec.versions.schema`）进行简单的类型校验。
* 将验证通过的数据**直接存储到etcd**，或从etcd读取。

**它们没有**：

* 复杂的业务校验（如“集群名称不能重复”）。
* 默认值填充（除非使用Schema的`default`字段）。
* 副作用（如创建资源时自动创建其他关联资源）。
* 任何与外部系统交互的逻辑。

#### **3. Connect接口在CRD中完全缺失**

对于需要**建立长连接、流式传输或代理**的操作，如：

* `Exec`（在容器内执行命令）
* `Attach`（附加到容器）
* `PortForward`（端口转发）
* `Proxy`（代理请求）

CRD模式**无法实现**。因为K8s主API服务器无法为它不知道如何处理的资源自动生成这些复杂逻辑。这些操作需要实现 `rest.Connecter` 接口，而这**仅在聚合API服务器模式中可行**。

**CRD模式的高级逻辑只能通过Webhook注入：**


| Webhook类型                      | 触发时机       | 常见用途                              |
| -------------------------------- | -------------- | ------------------------------------- |
| **Mutating Admission Webhook**   | 对象持久化之前 | 注入默认值、修改规格（如注入sidecar） |
| **Validating Admission Webhook** | 对象持久化之前 | 执行复杂的业务规则校验                |
| **Conversion Webhook**           | 多版本转换时   | 在不同API版本间转换资源表示           |

### ⚙️ 三、聚合API服务器模式：基于实现的“绑定式”生成（Karmada采用）

#### **1. 生成机制：接口绑定**

在聚合API服务器中，**开发者需要手动编写REST Storage的实现**。框架 (`genericapiserver`) 会**检查该实现具体满足了`rest.Storage`接口的哪些子集**，然后自动绑定对应的HTTP路由。

这个过程是**“半自动”**的：

* **您负责实现**：业务逻辑的Go方法（`Create`, `Get`等）。
* **框架负责**：生成HTTP路由、处理协议细节、装配中间件链。

在Kubernetes中，为资源生成RESTful API主要有两种路径：


| 对比维度              | **CRD模式** (Custom Resource Definition)                                              | **聚合API服务器模式** (AA, Karmada所用)                                                                 |
| --------------------- | ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| **本质**              | **声明式**：向K8s主API服务器注册一个“新表结构”。                                    | **编程式**：启动一个独立的、实现了完整API服务器的进程。                                                 |
| **REST端点生成**      | **全自动生成**：K8s主API服务器根据CRD的Schema，使用**通用代码**自动生成全套CRUD端点。 | **半自动生成**：开发者实现`rest.Storage`接口，K8s的`genericapiserver`框架根据实现**自动绑定HTTP路由**。 |
| **业务逻辑位置**      | 无内置逻辑。需通过**Webhook**（准入、验证、转换）注入。                               | **内置在REST Storage实现中**，直接编码`Create`, `Get`等方法。                                           |
| **Connect等特殊接口** | **无法实现**。仅限标准CRUD。                                                          | **可以实现**，通过实现`rest.Connecter`等扩展接口。                                                      |
| **性能与耦合度**      | 与主API服务器同进程，性能好，但逻辑分离。                                             | 独立进程，有网络开销，但**业务逻辑完全自主**。                                                          |

### 🔧 二、CRD模式：自动生成的“空壳”接口

当您创建一个CRD时，K8s主API服务器会像操作一张新的数据库表一样，为它**自动生成全套标准的REST端点**。

#### **1. 生成的接口列表（以 `yourresources.yourgroup.com` 为例）**

这些端点是 **“凭空”** 生成的，您无需编写任何Go代码：


| HTTP方法   | 路径                                                          | 对应操作 | 实现方式                   |
| ---------- | ------------------------------------------------------------- | -------- | -------------------------- |
| **POST**   | `/apis/yourgroup.com/v1/namespaces/{ns}/yourresources`        | 创建     | 通用代码，将JSON存入etcd   |
| **GET**    | `/apis/yourgroup.com/v1/namespaces/{ns}/yourresources`        | 列表     | 通用代码，从etcd查询列表   |
| **GET**    | `/apis/yourgroup.com/v1/namespaces/{ns}/yourresources/{name}` | 获取     | 通用代码，从etcd按key查询  |
| **PUT**    | `/apis/yourgroup.com/v1/namespaces/{ns}/yourresources/{name}` | 更新     | 通用代码，替换etcd中的值   |
| **PATCH**  | `/apis/yourgroup.com/v1/namespaces/{ns}/yourresources/{name}` | 部分更新 | 通用代码，应用JSON Patch等 |
| **DELETE** | `/apis/yourgroup.com/v1/namespaces/{ns}/yourresources/{name}` | 删除     | 通用代码，从etcd删除key    |
| **WATCH**  | `/apis/yourgroup.com/v1/watch/...`                            | 监听变更 | 通用代码，监听etcd事件流   |

#### **2. “无逻辑”的含义**

这些自动生成的接口 **只有最基础的存储逻辑**，相当于一个**智能的键值存储包装器**。它们会：

* 进行基础的JSON/YAML解析。
* 依据CRD中定义的**OpenAPI Schema**（`spec.versions.schema`）进行简单的类型校验。
* 将验证通过的数据**直接存储到etcd**，或从etcd读取。

**它们没有**：

* 复杂的业务校验（如“集群名称不能重复”）。
* 默认值填充（除非使用Schema的`default`字段）。
* 副作用（如创建资源时自动创建其他关联资源）。
* 任何与外部系统交互的逻辑。

#### **3. Connect接口在CRD中完全缺失**

对于需要**建立长连接、流式传输或代理**的操作，如：

* `Exec`（在容器内执行命令）
* `Attach`（附加到容器）
* `PortForward`（端口转发）
* `Proxy`（代理请求）

CRD模式**无法实现**。因为K8s主API服务器无法为它不知道如何处理的资源自动生成这些复杂逻辑。这些操作需要实现 `rest.Connecter` 接口，而这**仅在聚合API服务器模式中可行**。

**CRD模式的高级逻辑只能通过Webhook注入：**


| Webhook类型                      | 触发时机       | 常见用途                              |
| -------------------------------- | -------------- | ------------------------------------- |
| **Mutating Admission Webhook**   | 对象持久化之前 | 注入默认值、修改规格（如注入sidecar） |
| **Validating Admission Webhook** | 对象持久化之前 | 执行复杂的业务规则校验                |
| **Conversion Webhook**           | 多版本转换时   | 在不同API版本间转换资源表示           |
