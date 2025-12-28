#!/bin/bash
# 提取证书脚本：extract-certs.sh

KUBECONFIG_FILE="$HOME/.kube/karmada-apiserver.config"
OUTPUT_DIR="$HOME/.kube/karmada-certs"

# 创建输出目录
mkdir -p "$OUTPUT_DIR"

# 1. 提取CA证书（验证服务端用）
echo "正在提取CA证书..."
kubectl --kubeconfig="$KUBECONFIG_FILE" config view --raw \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | \
  base64 -d > "$OUTPUT_DIR/ca.crt"

# 2. 提取客户端证书（身份证明用）
echo "正在提取客户端证书..."
kubectl --kubeconfig="$KUBECONFIG_FILE" config view --raw \
  -o jsonpath='{.users[0].user.client-certificate-data}' | \
  base64 -d > "$OUTPUT_DIR/client.crt"

# 3. 提取客户端私钥（身份验证用）
echo "正在提取客户端私钥..."
kubectl --kubeconfig="$KUBECONFIG_FILE" config view --raw \
  -o jsonpath='{.users[0].user.client-key-data}' | \
  base64 -d > "$OUTPUT_DIR/client.key"

# 设置私钥权限（非常重要！）
chmod 600 "$OUTPUT_DIR/client.key"

echo "✅ 证书提取完成！"
echo "📁 输出目录: $OUTPUT_DIR"
echo ""
echo "文件清单:"
ls -la "$OUTPUT_DIR/"
echo ""
echo "验证证书:"
openssl x509 -in "$OUTPUT_DIR/ca.crt" -text -noout | grep -E "(Subject:|Issuer:|Not Before|Not After)"
openssl x509 -in "$OUTPUT_DIR/client.crt" -text -noout | grep -E "(Subject:|Issuer:|Not Before|Not After)"