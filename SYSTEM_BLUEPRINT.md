# SYSTEM_BLUEPRINT

## 프로젝트 개요

이 프로젝트는 AWS EKS 위에서 동작하는 **코인 거래소 mock 시스템**을 학습용으로 구현하는 것을 목표로 한다.

핵심 목적은 다음과 같다.

- VM + Docker 중심 운영 방식에서
- Kubernetes + Helm + GitOps + IaC 중심 운영 방식으로
- 사고방식을 전환하는 것

이 프로젝트는 실제 거래소 제품이 아니라, **거래소형 아키텍처와 플랫폼 운영 패턴을 학습하기 위한 mock system**이다.

---

## 최상위 목표

이 프로젝트를 통해 다음을 검증한다.

1. Terraform으로 AWS 기반 인프라를 코드화할 수 있다.
2. EKS 위에 애플리케이션을 선언형으로 배포할 수 있다.
3. Helm chart를 이용해 서비스 배포 구성을 템플릿화할 수 있다.
4. ArgoCD를 통해 GitOps 방식으로 배포를 자동화할 수 있다.
5. 이벤트 기반 서비스 흐름을 최소 수준으로 구현할 수 있다.
6. 운영 관점에서 관측성, 롤백, 재배포, 헬스체크 구조를 이해할 수 있다.

---

## 리포지토리 분리 원칙

이 프로젝트는 아래 3개 리포지토리로 분리한다.

### 1. mock-trading-platform-infra
책임:
- AWS 인프라 생성
- VPC, subnet, security group, IAM, EKS, ECR
- ALB controller 설치를 위한 기반 준비
- dev 환경용 Terraform 구성

포함:
- Terraform modules
- envs/dev
- README
- 운영 전제 및 비용 설명

비포함:
- 애플리케이션 코드
- Helm chart
- ArgoCD application 정의

### 2. mock-trading-platform-app
책임:
- 애플리케이션 소스코드
- Dockerfile
- Helm chart
- GitHub Actions 기반 이미지 빌드 및 ECR push

포함:
- auth-service
- order-service
- wallet-service
- marketdata-service
- frontend
- charts/ (서비스별 chart + mock-trading-platform-ingress)

비포함:
- Terraform
- ArgoCD root app / environment wiring

### 3. mock-trading-platform-gitops
책임:
- ArgoCD Application 정의
- AppProject
- root app / app-of-apps
- 환경별 values 파일
- dev 환경 배포 wiring

포함:
- argocd/
- environments/dev/values/
- bootstrap 문서

비포함:
- 애플리케이션 소스코드
- Terraform 코드

---

## 목표 아키텍처

현재 구현된 구조는 다음과 같다.

Client
-> ALB Ingress (path-based routing)
  -> /api/auth   -> auth-service
  -> /api/orders -> order-service -> PostgreSQL
  -> /api/wallet -> wallet-service
  -> /api/market -> marketdata-service
  -> /           -> frontend (static SPA)

order-service -> NATS JetStream -> wallet-service
                                -> marketdata-service

운영 계층:
- ArgoCD
- Prometheus + Grafana
- Loki
- GitHub Actions
- ECR
- Terraform
- EKS
- External Secrets Operator

---

## 서비스 설명

### ALB Ingress (mock-trading-platform-ingress chart)
역할:
- 외부 진입점 (AWS Application Load Balancer)
- path 기반 라우팅으로 각 서비스에 트래픽 분배
- `/api/*` 경로를 backend 서비스로, `/`를 frontend로 라우팅
- 모든 서비스는 ClusterIP로 운영되며 외부 노출은 Ingress 하나만 담당

### auth-service
역할:
- mock login
- JWT 발급/검증
- 사용자 식별 최소 기능

### order-service
역할:
- 주문 생성
- 주문 취소
- 주문 조회
- 주문을 DB에 저장
- 주문 생성 이벤트를 NATS JetStream으로 발행

핵심:
- 초기 버전의 중심 서비스
- 서비스 전체 흐름의 시작점
- single replica, Recreate 전략으로 운영 (in-memory matcher 특성)

### wallet-service
역할:
- NATS JetStream에서 order created 이벤트 소비
- 잔고 hold/release mock 처리
- 최소 수준의 ledger-like behavior

### marketdata-service
역할:
- NATS JetStream에서 order event 소비
- in-memory read model / ticker 반영
- 조회 최적화 예시 제공

### frontend
역할:
- mock UI 제공 (Vite + React + TypeScript SPA)
- auth-service / order-service 흐름 데모
- 로그인 시 access token을 sessionStorage에 저장
- 브라우저는 항상 frontend origin 만 호출 (동일 origin, CORS 회피)

구현 방식:
- nginx는 정적 파일(SPA)만 서빙한다.
- `/api/*` 경로 라우팅은 Kubernetes Ingress가 담당한다.
- frontend는 `VITE_API_BASE=/api`로 same-origin 호출만 사용한다.

---

## 기술 스택

### 인프라
- AWS
- Terraform
- EKS
- ECR
- IAM / IRSA
- ALB Controller

### 앱/배포
- Kubernetes
- Helm
- ArgoCD
- GitHub Actions

### 데이터/메시징
- PostgreSQL
- NATS JetStream

### 관측성
- Prometheus
- Grafana
- Loki

### 시크릿 관리
- External Secrets Operator (AWS Secrets Manager 연동)

---

## 환경 범위

초기 구현 범위는 **dev only** 이다.

초기 단계에서 하지 않는 것:
- prod 환경
- stage 환경
- multi-region
- multi-account 고도화
- MSK
- Aurora
- ElastiCache
- Vault
- Karpenter
- service mesh
- 복잡한 zero-trust 정책
- 완전한 matching engine

---

## 구현 원칙

### 1. 작동하는 최소 구조 우선
초기 목표는 예쁜 추상화가 아니라,
- 실제로 올라가는 인프라
- 실제로 배포되는 서비스
- 실제로 반영되는 GitOps
를 먼저 확보하는 것이다.

### 2. 과도한 엔터프라이즈화 금지
이 프로젝트는 학습용이다.
불필요한 모듈화, 과도한 abstraction, 지나친 generic template은 피한다.

### 3. repo 책임 경계 준수
각 리포는 자기 책임만 갖는다.
infra repo는 app chart를 몰라야 하고,
app repo는 Terraform을 몰라야 하며,
gitops repo는 앱 코드 구현을 몰라야 한다.

### 4. 문서화 필수
모든 리포에는 README가 있어야 하며, 최소한 아래 내용을 포함해야 한다.
- 목적
- 구조
- 실행 또는 적용 절차
- 검증 방법
- 다음 단계

### 5. 검증 가능한 상태로 제출
각 단계 작업 후 최소 검증 절차를 제공해야 한다.
예:
- terraform validate
- helm lint
- kubectl get pods
- argocd app sync
- 서비스 health endpoint 확인

---

## 권장 구현 순서

### Phase 1: infra
- VPC
- EKS
- node group
- ECR
- 기본 IAM
- ALB controller 기반

### Phase 2: app
- auth-service
- order-service
- Helm chart
- health endpoint
- PostgreSQL 연동

### Phase 3: event flow
- NATS JetStream
- wallet-service
- marketdata-service

### Phase 4: gitops
- ArgoCD bootstrap
- AppProject
- app-of-apps
- dev values wiring

### Phase 5: observability
- Prometheus
- Grafana
- Loki
- 기본 dashboard / alert candidate

---

## 금지사항

다음은 초기 단계에서 금지한다.

- 한 번에 3개 리포 전체를 완성하려고 시도하지 말 것
- 아직 요구되지 않은 prod/stage 구조 추가 금지
- 비용이 큰 관리형 서비스 기본 탑재 금지
- 설명 없는 보안 설정 남발 금지
- 실제 사용하지 않는 boilerplate 생성 금지
- 필요 이상으로 복잡한 Helm library chart 도입 금지
- 매칭엔진을 사실상 구현하려는 시도 금지

---

## 기대 산출물

최종적으로 아래를 기대한다.

1. Terraform으로 AWS dev 인프라를 생성할 수 있다.
2. GitHub Actions로 이미지를 빌드하고 ECR로 푸시할 수 있다.
3. ArgoCD가 Helm chart를 기준으로 EKS에 자동 반영할 수 있다.
4. order-service에서 주문 생성 시 NATS JetStream으로 이벤트가 발행된다.
5. wallet-service와 marketdata-service가 해당 이벤트를 소비한다.
6. 운영 상태를 최소한의 관측 도구로 볼 수 있다.

---

## 성공 기준

다음을 만족하면 초기 목표 달성으로 본다.

- EKS 클러스터가 Terraform으로 생성된다.
- order-service가 EKS에 배포되어 정상 응답한다.
- order 생성 API 호출 시 DB 저장이 된다.
- order 이벤트가 NATS JetStream으로 발행된다.
- wallet-service가 이벤트를 소비한다.
- ArgoCD를 통해 image tag 또는 values 변경이 자동 반영된다.
- ALB Ingress를 통해 브라우저에서 frontend 접속 및 API 호출이 정상 동작한다.
- README만 읽고 다른 사람이 구조를 이해할 수 있다.
