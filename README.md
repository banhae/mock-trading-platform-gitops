# exchange-gitops

Exchange mock system의 GitOps 배포 구성을 관리하는 리포지토리.

ArgoCD app-of-apps 패턴을 사용하여 dev 환경의 인프라 및 서비스를 선언적으로 배포한다.

---

## 디렉터리 구조

```
exchange-gitops/
├── .env.example                           # 플레이스홀더 정의 및 기본값
├── scripts/
│   └── bootstrap-values.sh                # 플레이스홀더 치환 스크립트
├── argocd/
│   ├── root-app.yaml                      # app-of-apps 진입점
│   ├── projects/
│   │   └── mock-trading-platform-dev.yaml              # AppProject 정의
│   ├── manifests/
│   │   └── dev/
│   │       ├── external-secrets/
│   │       │   ├── secret-store.yaml      # AWS Secrets Manager 연결
│   │       │   └── secret-contract.yaml   # ExternalSecret 정의
│   │       └── monitoring/
│   │           ├── podmonitors.yaml       # 4개 서비스 PodMonitor
│   │           ├── exchange-alerts.yaml   # PrometheusRule (5xx, p99, restart)
│   │           ├── dashboard-exchange-overview.yaml # Grafana RED 대시보드
│   │           └── dashboard-infrastructure.yaml    # Grafana 인프라 대시보드
│   └── applications/
│       └── dev/
│           ├── aws-load-balancer-controller.yaml # sync-wave 1
│           ├── metrics-server.yaml        # sync-wave 1
│           ├── external-secrets.yaml      # sync-wave 1
│           ├── postgres.yaml              # sync-wave 1
│           ├── nats.yaml                  # sync-wave 1
│           ├── secret-contract.yaml       # sync-wave 2
│           ├── auth-service.yaml          # sync-wave 2
│           ├── order-service.yaml         # sync-wave 3
│           ├── wallet-service.yaml        # sync-wave 3
│           ├── marketdata-service.yaml    # sync-wave 3
│           ├── frontend.yaml              # sync-wave 3
│           ├── mock-trading-platform-ingress.yaml      # sync-wave 4
│           ├── kube-prometheus-stack.yaml # sync-wave 5
│           ├── loki.yaml                  # sync-wave 5
│           └── mock-trading-platform-monitoring.yaml   # sync-wave 6 (PodMonitor/Rule/Dashboard)
└── environments/
    └── dev/
        └── values/
            ├── postgres.yaml
            ├── auth-service.yaml
            ├── order-service.yaml
            ├── wallet-service.yaml
            ├── marketdata-service.yaml
            ├── frontend.yaml
            └── mock-trading-platform-ingress.yaml
```

---

## app-of-apps 패턴

이 리포는 ArgoCD의 **app-of-apps** 패턴을 사용한다.

1. `root-app.yaml`이 `argocd/applications/dev/` 디렉터리를 감시한다.
2. 해당 디렉터리 안의 각 YAML 파일을 `argocd` namespace에 child Application 리소스로 생성한다.
3. 각 child Application은 워크로드를 `mock-trading-platform-dev` namespace에 배포한다.
4. 각 Application은 **multi-source**로 구성되어 있다:
   - **source 1**: Helm chart (Bitnami repo 또는 exchange-app 리포)
   - **source 2**: 이 리포의 values 파일 (`$values` ref로 참조)

### AppProject 권한 모델

`argocd/projects/mock-trading-platform-dev.yaml`은 다음을 명시적으로 허용한다:

| 항목 | 값 | 이유 |
|------|----|------|
| destinations | `mock-trading-platform-dev` namespace | 워크로드 배포 대상 |
| destinations | `argocd` namespace | root-app이 child Application 리소스를 argocd namespace에 만들기 위해 필요 |
| sourceRepos | gitops repo, exchange-app repo, bitnami, aws/metrics/nats/external-secrets chart repo | chart/values pull 허용 목록 |
| clusterResourceWhitelist | `*/*` (wildcard, dev 한정) | add-on/chart가 만들 수 있는 cluster-scoped 리소스 허용 |
| namespaceResourceWhitelist | `*/*` (wildcard, dev 한정) | PodDisruptionBudget(policy), NetworkPolicy(networking.k8s.io), `argoproj.io/Application` 등을 모두 포함 |

학습용 dev 단계에서는 wildcard로 단순화한다. 운영/스테이지 단계로 넘어갈 때는 group/kind를 좁혀야 한다.

### multi-source values 참조 방식

```yaml
# 예시: argocd/applications/dev/postgres.yaml
sources:
  - repoURL: https://charts.bitnami.com/bitnami
    chart: postgresql
    targetRevision: "16.4.1"
    helm:
      valueFiles:
        - $values/environments/dev/values/postgres.yaml  # <-- $values ref

  - repoURL: https://github.com/banhae/mock-trading-platform-gitops.git
    targetRevision: main
    ref: values  # <-- 이 ref가 $values로 사용됨
```

`ref: values`로 선언된 source가 `$values`라는 이름으로 다른 source의 `valueFiles`에서 참조된다.
이를 통해 chart와 values를 서로 다른 리포에서 가져올 수 있다.

### 브랜치 운영 원칙 (source of truth)

- 운영 배포의 기준 브랜치는 **`main`** 이다.
- 각 Application의 values source(`ref: values`)는 `targetRevision: main`을 바라본다.
- feature/작업 브랜치는 검토(PR) 용도이며, merge 전까지는 배포 source of truth가 아니다.

> 예외적으로 특정 커밋/브랜치를 검증해야 할 때만 `targetRevision`을 임시 변경하고,
> 검증 후 반드시 `main`으로 되돌린다.

---

## sync 순서

sync-wave annotation으로 배포 순서를 제어한다.

| sync-wave | 대상 | 이유 |
|-----------|------|------|
| 1 | aws-load-balancer-controller, metrics-server, external-secrets, postgres, nats | 인프라/플랫폼 의존성 — 앱 서비스의 전제 조건 |
| 2 | secret-contract, auth-service | 시크릿 생성 + 인증 서비스 — 다른 서비스에서 JWT 검증에 필요 |
| 3 | order-service, wallet-service, marketdata-service, frontend | 비즈니스 서비스 |
| 4 | mock-trading-platform-ingress | API/프론트엔드 단일 진입 라우팅 |
| 5 | kube-prometheus-stack, loki | 관측성 플랫폼 (Prometheus + Grafana CRD, 로그 수집) |
| 6 | mock-trading-platform-monitoring | 도메인 PodMonitor / PrometheusRule / Grafana 대시보드 — wave 5 의 CRD 필요 |

ArgoCD는 wave 1의 리소스가 Healthy 상태가 된 후 wave 2로 진행한다.

---

## Observability

`mock-trading-platform-monitoring` Application 이 도메인 관측성 리소스를 한 번에 동기화한다.
모두 `argocd/manifests/dev/monitoring/` 아래에 정의되어 있다.

### 메트릭 수집 흐름

```
exchange-app Go 서비스 (auth/order/wallet/marketdata)
  │  /metrics  (promhttp + http_request_duration_seconds histogram)
  ▼
PodMonitor (port=http, label app.kubernetes.io/name=<service>)
  ▼
Prometheus (kube-prometheus-stack, retention=3d)
  │
  ├──▶ PrometheusRule  →  알람 (UI Alerts 탭, alertmanager 미사용)
  └──▶ Grafana sidecar  →  ConfigMap(label grafana_dashboard=1) 자동 마운트
```

### PodMonitor 라벨 매칭

각 PodMonitor 는 `app.kubernetes.io/name: <service>` 라벨로 파드를 찾는다.
이 라벨은 `exchange-app/charts/<service>/templates/_helpers.tpl` 의
`selectorLabels` 가 자동으로 부착한다. 컨테이너 포트 이름 `http` 도
exchange-app 차트에서 명시적으로 선언되어 있다.

### Grafana 대시보드 (UID 기준)

| UID | 패널 |
|---|---|
| `exchange-overview` | 서비스별 req/s, 5xx rate, p50/p99 latency, 총 요청 수, Pod up, 재시작 수 |
| `exchange-infrastructure` | 노드 CPU/Mem, 파드 CPU/Mem, 노드/파드/PVC 카운트 |

대시보드는 ConfigMap 으로 배포되며 `kube-prometheus-stack.yaml` 의
`grafana.sidecar.dashboards.searchNamespace=ALL` 설정에 의해
Grafana sidecar 가 자동 감지한다.

### Alert 규칙

`exchange-app-alerts` PrometheusRule 이 다음 알람을 정의한다.

| Alert | 조건 | for |
|---|---|---|
| `ExchangeHighErrorRate` | 5xx 비율 > 1% (5m rate) | 5m |
| `ExchangeHighLatencyP99` | p99 > 500ms (5m rate) | 10m |
| `ExchangePodCrashLooping` | 컨테이너 재시작 > 3회 (15m) | 5m |

dev 단계에서는 alertmanager 가 비활성화되어 있으므로 Prometheus UI 의
Alerts 탭에서만 발화 상태를 확인한다. 운영으로 승격할 때 alertmanager + 알림
채널(Slack/PagerDuty)을 추가한다.

### Grafana 접근 방법

```bash
kubectl -n mock-trading-platform-dev port-forward svc/mock-trading-platform-dev-kube-prometheus-stack-grafana 3000:80
# admin 비밀번호:
kubectl -n mock-trading-platform-dev get secret mock-trading-platform-dev-kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d ; echo
```

브라우저: `http://localhost:3000` → Dashboards → Exchange — RED Overview / Infrastructure

---

## 전제 조건

- EKS 클러스터가 동작 중이어야 한다 (exchange-infra 리포 참조)
- ArgoCD **2.6 이상**이 클러스터에 설치되어 있어야 한다 (multi-source 지원 필요)
- `argocd` namespace가 존재해야 한다
- ArgoCD가 이 리포와 exchange-app 리포에 접근할 수 있어야 한다

---

## Bootstrap 절차

### 0. Placeholder 치환 (필수)

이 리포의 YAML 파일에는 `<AWS_ACCOUNT_ID>`, `<AWS_REGION>`, `<IMAGE_TAG>` 등의 플레이스홀더가 포함되어 있다.
배포 전에 반드시 실제 값으로 치환해야 한다.

모든 플레이스홀더의 정의, 설명, 출처는 `.env.example` 파일에 정리되어 있다.

#### 방법 A: 로컬 치환 스크립트 (권장)

```bash
cp .env.example .env
vi .env                                          # 실제 값을 채운다
./scripts/bootstrap-values.sh                    # 치환 실행
```

Terraform output에서 인프라 값을 자동으로 읽으려면:

```bash
./scripts/bootstrap-values.sh --from-terraform ../exchange-infra/envs/dev
```

치환 후:

```bash
git diff                                         # 변경 내용 확인
git commit -am "bootstrap: set dev values"
git push
```

#### 방법 B: GitHub Repository Variables

GitHub 리포 Settings > Variables and secrets > Variables에서 설정한다.

| Variable | 출처 | 예시 |
|----------|------|------|
| `AWS_ACCOUNT_ID` | `terraform output account_id` | `123456789012` |
| `AWS_REGION` | `terraform output region` | `ap-northeast-2` |
| `EKS_CLUSTER_NAME` | `terraform output cluster_name` | `mock-trading-platform-dev` |
| `AWS_VPC_ID` | `terraform output vpc_id` | `vpc-0abc123def` |
| `AWS_LBC_IRSA_ROLE_ARN` | `terraform output alb_controller_role_arn` | `arn:aws:iam::...:role/...` |
| `NATS_CHART_VERSION` | `helm search repo nats/nats` | `2.12.6` |
| `KUBE_PROMETHEUS_STACK_CHART_VERSION` | `helm search repo prometheus-community/...` | `72.6.2` |
| `LOKI_CHART_VERSION` | `helm search repo grafana/loki` | `6.29.0` |
| `IMAGE_TAG` | CI 빌드 결과 | `sha-abc1234` |

전체 목록과 상세 설명은 `.env.example`을 참조한다.

> 두 방법 모두 동일한 `<PLACEHOLDER>` 형식을 사용하므로 충돌하지 않는다.
> 방법 A의 실제 값은 `.env`(gitignored)에만 보관된다.

### 1. ArgoCD 설치 (아직 없는 경우)

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

### 2. ArgoCD CLI 로그인

```bash
# 초기 admin 비밀번호 확인
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# 포트포워드
kubectl port-forward svc/argocd-server -n argocd 8080:443

# 로그인
argocd login localhost:8080 --username admin --password <위에서 확인한 비밀번호>
```

### 3. Git 리포지토리 등록 (private repo인 경우)

```bash
argocd repo add https://github.com/banhae/mock-trading-platform-gitops.git --username <user> --password <token>
argocd repo add https://github.com/banhae/mock-trading-platform-app.git --username <user> --password <token>
```

### 4. AppProject 생성

```bash
kubectl apply -f argocd/projects/mock-trading-platform-dev.yaml
```

### 4-1. ALB controller 값 치환 확인 (중요)

`argocd/applications/dev/aws-load-balancer-controller.yaml`의 아래 값은 실제 클러스터 값이어야 한다.

- `clusterName`
- `region`
- `vpcId` (`<AWS_VPC_ID>`에서 치환)
- `serviceAccount.annotations.eks.amazonaws.com/role-arn` (`<AWS_LBC_IRSA_ROLE_ARN>`에서 치환)

치환 누락 시 ALB target 등록 실패/Ingress reconcile 실패가 발생할 수 있다.

```bash
rg -n "clusterName|region|vpcId|role-arn" argocd/applications/dev/aws-load-balancer-controller.yaml
```

### 5. Root Application 생성

```bash
kubectl apply -f argocd/root-app.yaml
```

### 6. AppProject 권한 검증

root-app이 child Application을 argocd namespace에 생성하므로, AppProject 설정이 올바른지 확인한다.

```bash
# destinations에 mock-trading-platform-dev와 argocd가 모두 포함되어 있어야 함
kubectl get appproject mock-trading-platform-dev -n argocd \
  -o jsonpath='{.spec.destinations[*].namespace}'
# 기대 출력: mock-trading-platform-dev argocd

# wildcard whitelist 확인 (argoproj.io/Application 포함)
kubectl get appproject mock-trading-platform-dev -n argocd \
  -o jsonpath='{.spec.namespaceResourceWhitelist}'
```

### 7. sync 확인

```bash
# ArgoCD UI에서 확인 (http://localhost:8080)
# 또는 CLI로 확인:

argocd app list
argocd app get mock-trading-platform-dev-root

# 개별 앱 상태 확인
argocd app get mock-trading-platform-dev-aws-load-balancer-controller
argocd app get mock-trading-platform-dev-metrics-server
argocd app get mock-trading-platform-dev-postgres
argocd app get mock-trading-platform-dev-nats
argocd app get mock-trading-platform-dev-auth-service
argocd app get mock-trading-platform-dev-order-service
argocd app get mock-trading-platform-dev-wallet-service
argocd app get mock-trading-platform-dev-marketdata-service
argocd app get mock-trading-platform-dev-frontend
argocd app get mock-trading-platform-dev-mock-trading-platform-ingress
```

### 8. Pod 상태 확인

```bash
kubectl get pods -n mock-trading-platform-dev
kubectl get svc -n mock-trading-platform-dev
```

---

## values 파일 위치

환경별 override values는 `environments/<env>/values/` 에 위치한다.

현재는 **dev 환경만** 존재:

```
environments/dev/values/
├── postgres.yaml           # DB 인증정보, 리소스, 스토리지 (bitnami chart)
├── auth-service.yaml       # ECR 이미지 + JWT_SECRET
├── order-service.yaml      # ECR 이미지 + DATABASE_URL + JWT_SECRET
├── wallet-service.yaml     # ECR 이미지 + NATS 연결정보
├── marketdata-service.yaml # ECR 이미지 + NATS 연결정보
├── frontend.yaml           # same-origin 호출 전제 + frontend 이미지
└── mock-trading-platform-ingress.yaml   # ALB annotation + path-based routing
```

서비스 values는 **차트가 실제로 선언한 키만 override** 한다.
차트가 새 env를 노출하면 그 시점에 이 파일을 갱신한다.

차트의 `replicaCount`, `resources`, `probes` 등은 차트 기본값을 그대로 사용한다.

---

## 신규 서비스 추가 방법

1. `argocd/applications/dev/<service-name>.yaml` 생성
   - 기존 Application YAML을 복사하여 수정
   - 적절한 sync-wave 지정
   - source의 chart 경로 또는 repoURL 설정
2. `environments/dev/values/<service-name>.yaml` 생성
   - 해당 서비스의 dev 환경 override values 작성
3. 커밋 후 push
   - root-app이 자동으로 새 Application을 감지하고 생성함

---

## 주의사항

- 모든 `<PLACEHOLDER>` 값은 Bootstrap 0단계에서 반드시 치환할 것. 전체 목록은 `.env.example` 참조
- dev 전용 시크릿(`<DEV_JWT_SECRET>`, `<DEV_DB_PASSWORD>` 등)은 치환 후 리터럴로 들어간다. 운영 환경에서는 ExternalSecrets + AWS Secrets Manager로 대체할 것
- Helm chart 버전(`<NATS_CHART_VERSION>` 등)은 배포 전 `helm search repo`로 최신 안정 버전을 확인할 것
- CRD가 큰 차트(external-secrets, kube-prometheus-stack, loki)는 `syncOptions: ServerSideApply=true`를 유지할 것 (client-side apply의 annotation 262144 bytes 한계 회피)
- 이미지 태그(`<IMAGE_TAG>`)는 CI에서 `sha-<commit>` 형식으로, 수동 테스트 시에는 `latest`로 치환한다

---

## Troubleshooting

### root-app sync 실패: "Application is not permitted to use project"
원인: AppProject의 destinations에 `argocd` namespace가 빠졌거나 namespaceResourceWhitelist에 `argoproj.io/Application`이 없음.
조치: `argocd/projects/mock-trading-platform-dev.yaml`을 다시 적용하고 6단계 검증 명령으로 확인.

### child Application sync 실패: ImagePullBackOff
원인: ECR 이미지 경로 잘못. placeholder 미치환이거나 prefix `exchange/`가 빠짐.
조치:
```bash
kubectl -n mock-trading-platform-dev describe pod <pod-name> | grep -i image:
# 기대 형식: <account>.dkr.ecr.<region>.amazonaws.com/exchange/<service>:<tag>
```
- `.env` 값을 확인하고 `./scripts/bootstrap-values.sh`를 다시 실행
- 노드의 IRSA/instance profile에 ECR pull 권한이 있는지 exchange-infra에서 확인

### order-service: DB 연결 실패
원인: postgres release 이름과 DATABASE_URL의 host 불일치, 또는 비밀번호 불일치.
- host는 반드시 `mock-trading-platform-dev-postgres-postgresql` (= ArgoCD Application name `mock-trading-platform-dev-postgres` + Bitnami chart suffix `-postgresql`)
- 비밀번호는 `environments/dev/values/postgres.yaml`의 `auth.postgresPassword`와 정확히 일치해야 함

```bash
kubectl -n mock-trading-platform-dev get svc | grep postgres
kubectl -n mock-trading-platform-dev exec -it <order-pod> -- env | grep DATABASE_URL
```

### Bitnami chart 버전 pull 실패
원인: pin된 chart 버전이 repo에서 제거됨.
조치: `argocd/applications/dev/postgres.yaml`의 `targetRevision`을 현재 사용 가능한 가까운 버전으로 갱신.

### NATS chart 버전 오류 (1.x → 2.x 전환 이슈)
원인: 과거에 사용하던 NATS chart 1.x 버전이 upstream에서 제거되어 pull 실패.
조치:

```bash
helm repo add nats https://nats-io.github.io/k8s/helm/charts/
helm repo update
helm search repo nats/nats --versions | head -20
```

- `.env`의 `NATS_CHART_VERSION`을 2.x 유효 버전(예: `2.12.6`)으로 설정
- `./scripts/bootstrap-values.sh` 재실행 후 `argocd/applications/dev/nats.yaml`의 `targetRevision` 확인
- 반영 후 `argocd app sync mock-trading-platform-dev-nats`

### app-of-apps에서 새 Application이 안 보임
원인: root-app이 디렉터리 변경을 감지하지 못함.
조치: `argocd app sync mock-trading-platform-dev-root` 수동 sync.
