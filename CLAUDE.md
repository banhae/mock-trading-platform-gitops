# CLAUDE.md

## 리포 목적

이 리포는 exchange mock system의 GitOps 배포 구성을 관리한다.

책임 범위:
- ArgoCD AppProject
- root application
- app-of-apps
- environment values
- dev 배포 wiring
- bootstrap 절차 문서화

책임 범위 아님:
- Terraform
- 서비스 소스코드
- Dockerfile
- 애플리케이션 비즈니스 로직

---

## 현재 단계의 목표

dev 환경에서 ArgoCD를 통해 다음 리소스를 안정적으로 배포한다.

플랫폼 의존성 (sync-wave 1):
- aws-load-balancer-controller
- metrics-server
- external-secrets
- postgres (Bitnami chart)
- nats (NATS JetStream)

애플리케이션 (sync-wave 2~3):
- auth-service
- order-service
- wallet-service
- marketdata-service
- frontend

라우팅 (sync-wave 4):
- mock-trading-platform-ingress (ALB)

관측성 (sync-wave 5):
- kube-prometheus-stack
- loki

---

## 구현 원칙

1. dev only
2. 명확한 디렉터리 구조
3. sync 순서 가시화
4. values 분리
5. bootstrap 문서화

---

## 구조 원칙

권장 구조:
- argocd/root-app.yaml
- argocd/projects/
- argocd/applications/dev/
- environments/dev/values/

root app -> applications(dev) -> Helm chart values 연결 구조를 선호한다.

---

## sync 원칙

의존성이 강한 순서:
1. 플랫폼 의존성 — aws-load-balancer-controller, metrics-server, external-secrets, postgres, nats
2. auth-service, secret-contract
3. order-service, wallet-service, marketdata-service, frontend
4. mock-trading-platform-ingress (ALB)
5. kube-prometheus-stack, loki

sync wave annotation을 사용해 순서를 명시한다.
지나치게 복잡하게 만들지 않는다.

대형 CRD를 포함하는 차트(external-secrets, kube-prometheus-stack 등)는
ArgoCD `ServerSideApply=true` syncOption을 사용해 client-side apply의
`last-applied-configuration` annotation 262144 bytes 한계를 회피한다.

---

## values 원칙

환경별 values는 이 리포에서 관리한다.
차트 기본값은 app repo에 남기고,
환경 차이는 이 리포에서 override 한다.

초기에는 dev values만 만든다.

---

## 파일 작업 규칙

새 yaml을 쓰기 전 반드시:
1. 생성/수정 파일 목록
2. 파일 간 참조 관계
3. sync 흐름 설명
을 먼저 제시한다.

---

## 문서화 규칙

README에는 반드시 아래를 포함한다.
- bootstrap 절차
- ArgoCD 설치 전제
- sync 방법
- app-of-apps 설명
- values 파일 위치
- 신규 서비스 추가 방법

---

## 금지사항

- prod/stage 추가 금지
- secret manager 연동 기본 포함 금지 (현재 ESO + AWS Secrets Manager는 P1에서 IRSA 마무리 예정)
- ApplicationSet 고도화 금지
- 지나친 템플릿 추상화 금지
- chart source path를 불명확하게 만들지 말 것
