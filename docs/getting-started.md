# Mahanaim 시작 가이드

**대상 독자:** Mahanaim을 처음 사용하는 Nim 개발자
**안정성 기준:** project generator와 core routing은 stable 범위다.
**검증:** `nimble docsExamples`, `nimble test`, `nimble check`

이 가이드는 새 프로젝트를 만들고, 앱 모듈을 추가하고, 테스트를 실행하는 가장
짧은 경로를 설명한다. 서버를 외부에 공개하기 전에는 보안·배포 가이드와
[보안 배포 점검표](security-deployment-checklist.md)를 반드시 읽는다.

## 준비물

- Nim `>= 2.2.0` — CI 기준은 Nim 2.2.4다.
- Nimble과 Mahanaim CLI가 PATH에 있어야 한다.

프레임워크 자체를 복제해 작업한다면 다음으로 상태를 확인한다.

```text
nimble check
nimble test
```

## 1. 프로젝트 만들기

비어 있는 상위 디렉터리에서 실행한다.

```text
mahanaim new shop ./shop
cd shop
nimble install
```

> **Git 요구 사항:** Nimble 2.2는 `nimble test` 전에 VCS metadata를 읽는다.
> 따라서 `mahanaim new`는 Git repository와 `Initial Mahanaim project` baseline commit을
> 만들며, 기존 Git identity 설정은 바꾸지 않는다. 작성자를 바꾸려면 identity를 설정한 뒤
> `git commit --amend --reset-author --no-edit`를 실행한다.

`new`는 대상이 비어 있지 않거나 프로젝트 이름이 유효한 Nim 식별자가 아니면
실패한다. 기존 파일을 덮어쓰지 않는다.

## 2. 첫 테스트 실행

```text
nimble test
nimble build
```

생성 프로젝트는 `/health` route, metadata/migration, CRUD/Admin/auth 구성의
작은 수직 슬라이스를 포함한다. 생성물의 위치와 책임은
[프로젝트 구조](project-layout.md)를 참고한다.

## 3. 앱 모듈 추가

프로젝트 루트에서 `catalog` 기능 모듈을 추가한다.

```text
mahanaim app catalog
```

이 명령은 `src/catalog.nim`과 `tests/test_catalog.nim`을 만들고
`/catalog/health` route를 제공한다. 모듈은 자동 발견되지 않으므로 composition
root에 명시적으로 설치한다.

```nim
import mahanaim
import catalog

let app = newApplication()
app.installModules([catalogModule()])
```

이 코드는 생성된 앱 테스트와 같은 public API를 사용한다. Application/module의
lifecycle과 provider는 [애플리케이션과 모듈](application-and-modules.md)에서
설명한다.

## 다음 단계

1. 라우팅 가이드에서 실제 handler와 middleware를 추가한다.
2. 모델·migration 가이드로 데이터를 저장한다.
3. Admin 또는 API 개발 가이드로 사용자 인터페이스를 만든다.

## 문제 해결

| 증상 | 확인할 내용 |
| --- | --- |
| `mahanaim`을 찾을 수 없음 | 패키지 bin 경로가 PATH에 있는지, 또는 `nimble build` 후 로컬 binary를 쓰는지 확인한다. |
| `new`가 대상이 비어 있지 않다고 실패 | 새 경로를 지정한다. 생성기는 안전을 위해 기존 파일을 지우거나 덮어쓰지 않는다. |
| `app`이 `src`/`tests`가 없다고 실패 | 생성 프로젝트 루트에서 실행하거나 두 디렉터리를 먼저 만든다. |
| 테스트가 compile 실패 | Nim 버전과 `mahanaim.nimble`의 dependency를 확인한 뒤 `nimble test`를 다시 실행한다. |
