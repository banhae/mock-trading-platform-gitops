# argocd/repositories

ArgoCD 가 이 리포(`mock-trading-platform-gitops`) 와 `mock-trading-platform-app`
private repo 에 접근할 때 사용하는 declarative repository Secret 의 자리.

## 동작

`*.yaml.tmpl` 은 placeholder (`<GITHUB_USER>`, `<GITHUB_PAT>`) 가 들어간
template 이고 commit 된다. `scripts/bootstrap-values.sh` 가 `.env` 의
`GITHUB_USER` / `GITHUB_PAT` 로 치환해 같은 디렉터리에 `*.yaml` 을
생성하며, 이 결과물은 `.gitignore` 로 추적에서 제외된다 (PAT 평문 포함).

## 사용

```bash
cp .env.example .env
vi .env                                # GITHUB_USER, GITHUB_PAT 채움
./scripts/bootstrap-values.sh          # *.yaml 생성
kubectl apply -n argocd -f argocd/repositories/
```

`argocd repo list` 에 두 repo 가 `Successful` 로 등록되면 완료.

## 주의

- `*.yaml` 파일은 절대 commit 하지 말 것 (PAT 노출). gitignore 가 1차 방어선.
- 이 디렉터리는 `root-app` 의 sync scope 밖이다. ArgoCD 가 자기 자신의
  자격증명을 GitOps 로 self-manage 하면 chicken-and-egg 가 되므로
  부트스트랩 단계의 한 번만 `kubectl apply` 로 직접 등록한다.
- public repo 라면 자격증명 없이도 ArgoCD 가 접근할 수 있으므로 이 등록은
  생략 가능하다. private repo 일 때만 필수다.
- PAT 회전 시 `.env` 의 `GITHUB_PAT` 만 갱신하고 위 4단계를 다시 실행.
