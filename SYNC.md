# SYNC.md — upstream(exchange-gitops) 동기화 규칙

## 관계

- **upstream (source of truth, 비공개)**: `exchange-gitops`
- **이 리포 (공개 mirror)**: `mock-trading-platform-gitops`
- **방향**: upstream → mock **단방향**. mock 의 변경을 upstream 으로 역류시키지 않는다.

mock 은 upstream 의 **구조/로직을 placeholder 형태 + mock 네이밍으로** 가진다.
upstream 은 실제 account/VPC/ARN/시크릿이 구워진 인스턴스이고, mock 은 그 템플릿이다.
**따라서 동기화는 "파일 복사"가 아니라 "로직 이식"이다.**

> ⚠️ 과거에 upstream account 가 공개 리포로 복사되어 리포를 통째로 삭제·재생성한
> 사고가 있었다. 아래 C 분류와 `scripts/sync-guard.sh` 는 그 재발 방지가 목적이다.

---

## 분류 — 무엇을 어떻게 다루나

| 분류 | 처리 | 이 리포의 대상 |
|---|---|---|
| **A. 구조/로직** | upstream → mock **이식**(네이밍 변환하여) | `argocd/applications/dev/*.yaml`(구조·sync-wave·chart 버전), `argocd/manifests/dev/monitoring/*`, `environments/dev/values/*.yaml`의 **키 구조**, `scripts/bootstrap-values.sh`의 **로직**, README 절차 |
| **B. 네이밍** | **변환**(무시 아님) | `exchange` → `mock-trading-platform`, `exchange-dev` → `mock-trading-platform-dev`. 파일명·리소스명·project명·role명·repo URL(`banhae/exchange-*` → `banhae/mock-trading-platform-*`) 모두 |
| **C. account/시크릿** | **이식 금지 / placeholder·자체값 유지** (= 민감정보 drift 는 무시) | `aws-load-balancer-controller.yaml`의 `vpcId`·account·role-arn → `<AWS_VPC_ID>`/`<AWS_ACCOUNT_ID>` 유지; `environments/dev/values/*.yaml`의 시크릿 → placeholder 유지; `argocd/repositories/*.yaml`(PAT 렌더 산출물, gitignored); `.env`; upstream `CLAUDE.md`(비공개 — 이식 안 함) |

**"민감정보 drift 는 무시한다"** = C 분류. upstream 이 구체값으로 바뀌어도 mock 은
placeholder/자체 네이밍을 그대로 둔다. 이 drift 는 의도된 것이며 맞추지 않는다.

---

## 동기화 절차

upstream(`exchange-gitops`)에 변경이 생겼을 때:

1. **변경 성격 분류** — A(구조/로직)만 이식 대상. B는 변환, C는 건드리지 않음.
2. **로직 이식** — 해당 파일/부분을 mock 에 반영하되:
   - 모든 `exchange*` 네이밍을 `mock-trading-platform*` 로 변환(B)
   - 실제 account/VPC/ARN/시크릿이 보이면 placeholder 로 되돌림(C)
3. **가드 실행** (필수):
   ```bash
   ./scripts/sync-guard.sh
   ```
   `✓ 통과` 가 떠야 한다. ❌ 가 뜨면 upstream 값/네이밍이 새어든 것 — 2번으로 돌아간다.
4. **PR** 로 올린다(이 리포는 PR 워크플로우). main 직접 푸시 금지.

### pre-push 자동화 (권장)
```bash
ln -sf ../../scripts/sync-guard.sh .git/hooks/pre-push
```
이후 `git push` 마다 가드가 자동 실행되어, 위반 시 푸시가 차단된다.

---

## 현재 미동기화 항목 (예시)

- `scripts/bootstrap-values.sh` 에 upstream 의 **vpcId idempotent 재동기화** 로직이
  아직 없음(클러스터 재생성 시 `vpcId:` 줄을 terraform 현재값으로 덮어쓰는 sed).
  A 분류 — 네이밍 변환하여 이식 대상. (upstream `exchange-gitops` 해당 커밋 참조.)

---

## 빠른 체크리스트

- [ ] 이식한 변경이 A(구조/로직)인가? (C 라면 멈춤)
- [ ] 모든 `exchange*` → `mock-trading-platform*` 변환했는가?
- [ ] account/VPC/ARN/시크릿이 placeholder 인가?
- [ ] `./scripts/sync-guard.sh` 통과했는가?
- [ ] PR 로 올렸는가?
