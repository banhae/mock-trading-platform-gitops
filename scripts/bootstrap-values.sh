#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────
# exchange-gitops placeholder 치환 스크립트
#
# 사용법 A — .env 파일:
#   cp .env.example .env && vi .env
#   ./scripts/bootstrap-values.sh
#
# 사용법 B — Terraform output 자동 읽기:
#   ./scripts/bootstrap-values.sh --from-terraform ../exchange-infra/envs/dev
#   (Terraform output 외 값은 .env에서 보충)
# ──────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"

# ── Helm chart 버전 사전 검증 ──
# 치환하려는 chart 버전이 실제로 해당 repo에 존재하는지 확인한다.
# 예전에 NATS chart 버전이 upstream에서 삭제되었는데 뒤늦게 ArgoCD sync
# 실패로 드러나 시간을 버린 사례가 있어 추가함.
verify_helm_chart() {
  local repo_name="$1"
  local repo_url="$2"
  local chart_name="$3"
  local version="$4"

  if ! command -v helm >/dev/null 2>&1; then
    echo "경고: helm CLI를 찾을 수 없어 chart 버전 사전 검증을 건너뜁니다."
    return 0
  fi

  helm repo add "$repo_name" "$repo_url" >/dev/null 2>&1 || true
  helm repo update "$repo_name" >/dev/null 2>&1 || true

  if ! helm search repo "${repo_name}/${chart_name}" \
         --version "$version" --output json 2>/dev/null \
       | grep -q "\"version\":\"${version}\""; then
    echo "오류: ${chart_name} chart ${version} 버전을 ${repo_url} 에서 찾을 수 없습니다."
    echo "사용 가능한 최근 버전:"
    helm search repo "${repo_name}/${chart_name}" --versions 2>/dev/null | head -6 || true
    exit 1
  fi
  echo "  ✓ ${chart_name} ${version}"
}

# ── Terraform 자동 읽기 모드 ──
if [[ "${1:-}" == "--from-terraform" ]]; then
  INFRA_DIR="${2:?사용법: $0 --from-terraform <exchange-infra/envs/dev 경로>}"
  echo "▶ Terraform output에서 값을 읽습니다: ${INFRA_DIR}"

  TF_ACCOUNT_ID=$(terraform -chdir="$INFRA_DIR" output -raw account_id)
  TF_REGION=$(terraform -chdir="$INFRA_DIR" output -raw region)
  TF_CLUSTER=$(terraform -chdir="$INFRA_DIR" output -raw cluster_name)
  TF_VPC=$(terraform -chdir="$INFRA_DIR" output -raw vpc_id)
  TF_LBC_ROLE=$(terraform -chdir="$INFRA_DIR" output -raw alb_controller_role_arn)

  # .env가 있으면 나머지 값 보충
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

  # Terraform 값으로 덮어쓰기
  AWS_ACCOUNT_ID="$TF_ACCOUNT_ID"
  AWS_REGION="$TF_REGION"
  EKS_CLUSTER_NAME="$TF_CLUSTER"
  AWS_VPC_ID="$TF_VPC"
  AWS_LBC_IRSA_ROLE_ARN="$TF_LBC_ROLE"
else
  # ── .env 파일 읽기 모드 ──
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "오류: .env 파일이 없습니다."
    echo "  cp .env.example .env"
    echo "  vi .env"
    echo "  ./scripts/bootstrap-values.sh"
    exit 1
  fi
  source "$ENV_FILE"
fi

# ── 필수 값 검증 ──
REQUIRED=(AWS_ACCOUNT_ID AWS_REGION EKS_CLUSTER_NAME AWS_VPC_ID AWS_LBC_IRSA_ROLE_ARN)
MISSING=()
for var in "${REQUIRED[@]}"; do
  [[ -z "${!var:-}" ]] && MISSING+=("$var")
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "오류: 다음 필수 값이 비어 있습니다:"
  printf "  - %s\n" "${MISSING[@]}"
  exit 1
fi

# ── Chart 버전 존재 확인 ──
# 기본값은 아래 sed 구문과 반드시 일치시켜야 함.
# NATS 1.x는 upstream에서 삭제됨. chart 버전이 서버 버전과 동기화되어 2.x로 재시작.
NATS_CHART_VERSION="${NATS_CHART_VERSION:-2.12.6}"
KUBE_PROMETHEUS_STACK_CHART_VERSION="${KUBE_PROMETHEUS_STACK_CHART_VERSION:-72.6.2}"
LOKI_CHART_VERSION="${LOKI_CHART_VERSION:-6.29.0}"

echo "▶ Helm chart 버전 사전 검증"
verify_helm_chart "nats"                   "https://nats-io.github.io/k8s/helm/charts/"      "nats"                  "$NATS_CHART_VERSION"
verify_helm_chart "prometheus-community"   "https://prometheus-community.github.io/helm-charts" "kube-prometheus-stack" "$KUBE_PROMETHEUS_STACK_CHART_VERSION"
verify_helm_chart "grafana"                "https://grafana.github.io/helm-charts"           "loki"                  "$LOKI_CHART_VERSION"

# ── 치환 실행 ──
echo "▶ 플레이스홀더 치환 시작 (대상: ${REPO_ROOT})"

find "$REPO_ROOT" -type f -name '*.yaml' -not -path '*/.git/*' | xargs sed -i \
  -e "s|<AWS_ACCOUNT_ID>|${AWS_ACCOUNT_ID}|g" \
  -e "s|<AWS_REGION>|${AWS_REGION}|g" \
  -e "s|<EKS_CLUSTER_NAME>|${EKS_CLUSTER_NAME}|g" \
  -e "s|<AWS_VPC_ID>|${AWS_VPC_ID}|g" \
  -e "s|<AWS_LBC_IRSA_ROLE_ARN>|${AWS_LBC_IRSA_ROLE_ARN}|g" \
  -e "s|<EXTERNAL_SECRETS_ROLE_ARN>|${EXTERNAL_SECRETS_ROLE_ARN:-}|g" \
  -e "s|<NATS_CHART_VERSION>|${NATS_CHART_VERSION}|g" \
  -e "s|<KUBE_PROMETHEUS_STACK_CHART_VERSION>|${KUBE_PROMETHEUS_STACK_CHART_VERSION}|g" \
  -e "s|<LOKI_CHART_VERSION>|${LOKI_CHART_VERSION}|g" \
  -e "s|<SM_PATH_AUTH_JWT>|${SM_PATH_AUTH_JWT:-exchange/dev/auth-jwt}|g" \
  -e "s|<SM_PATH_APP_DB>|${SM_PATH_APP_DB:-exchange/dev/app-db}|g" \
  -e "s|<SM_PATH_APP_NATS>|${SM_PATH_APP_NATS:-exchange/dev/app-nats}|g" \
  -e "s|<DEV_PUBLIC_HOSTNAME>|${DEV_PUBLIC_HOSTNAME:-}|g" \
  -e "s|<IMAGE_TAG>|${IMAGE_TAG:-latest}|g" \
  -e "s|<DEV_JWT_SECRET>|${DEV_JWT_SECRET:-dev-jwt-secret-change-me}|g" \
  -e "s|<DEV_DB_PASSWORD>|${DEV_DB_PASSWORD:-dev-db-password-change-me}|g" \
  -e "s|<DEV_DATABASE_URL>|${DEV_DATABASE_URL:-postgresql://postgres:dev-db-password-change-me@mock-trading-platform-dev-postgres-postgresql:5432/exchange?sslmode=disable}|g" \
  -e "s|<DEV_NATS_URL>|${DEV_NATS_URL:-nats://mock-trading-platform-dev-nats:4222}|g" \
  -e "s|<DEV_NATS_TOKEN>|${DEV_NATS_TOKEN:-}|g"

echo ""
echo "✔ 치환 완료. 변경된 파일:"
cd "$REPO_ROOT" && git diff --name-only
echo ""
echo "다음 단계:"
echo "  git diff                                    # 변경 내용 확인"
echo "  git commit -am 'bootstrap: set dev values'  # 커밋"
echo "  git push                                    # ArgoCD 반영"
