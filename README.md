# Claude Code Azure OpenAI 프록시 사용 가이드

이 레포는 Claude Code를 Azure OpenAI 모델과 함께 쓰기 위한 로컬 실행 템플릿입니다.

Claude Code는 OpenAI/Azure OpenAI API 키를 직접 넣는 방식을 공식 지원하지 않습니다. 그래서 중간에 LiteLLM 프록시를 띄우고, Claude Code가 이 프록시를 Anthropic API처럼 바라보게 만듭니다.

```text
Claude Code -> LiteLLM 프록시 -> Azure OpenAI 배포 (opus=Sol, sonnet=Terra, haiku=Luna)
```

## 모델 티어 매핑

Claude Code의 세 티어(opus/sonnet/haiku)를 서로 다른 Azure 배포로 라우팅합니다. `/model` 명령으로 티어를 바꾸면 아래 배포로 연결됩니다.

| Claude 티어 | Azure 배포 (예) | 모델 | 특징 | 가격(입력/출력, 백만 토큰) |
| --- | --- | --- | --- | --- |
| opus | `gpt-5.6-sol` | **Sol** (최상위 플래그십) | 복잡한 코딩, 사이버 보안, 과학 연구, 장기 추론 등 최고 수준 지능이 필요한 고난도 작업 | $5 / $30 |
| sonnet | `gpt-5.6-terra` | **Terra** (성능·비용 균형형) | 이전 세대(GPT-5.5) 수준 성능을 절반 가격에 제공, 일반 업무 자동화·문서 분석에 무난 | $2.50 / $15 |
| haiku | `gpt-5.6-luna` | **Luna** (속도·비용 최적화형) | 가장 빠르고 저렴, 대량 데이터 분류·단순 정보 추출 등 속도·가성비 우선 작업 | $1 / $6 |

각 매핑은 `.env`의 `AZURE_DEPLOYMENT_OPUS`/`AZURE_DEPLOYMENT_SONNET`/`AZURE_DEPLOYMENT_HAIKU`(Azure 배포명)와 `CLAUDE_CODE_OPUS_ALIAS`/`CLAUDE_CODE_SONNET_ALIAS`/`CLAUDE_CODE_HAIKU_ALIAS`(Claude Code에 노출할 별칭)로 설정합니다.

## 빠른 시작: clone부터 첫 실행까지

Linux/macOS 기준으로 아래 프로그램과 Azure OpenAI 배포가 필요합니다.

- Claude Code CLI
- `uvx`
- `curl`
- `make`
- Azure OpenAI GPT-5.6-sol 배포

설치 여부를 확인합니다.

```bash
claude --version
uvx --version
curl --version
make --version
```

저장소를 clone하고 `.env`를 만듭니다.

```bash
git clone https://github.com/WontaeKim89/claude-code-azure-openai-proxy.git
cd claude-code-azure-openai-proxy
make setup
```

`.env`를 열어 Azure OpenAI 배포 정보를 입력합니다.

```dotenv
AZURE_API_KEY=여기에_Azure_OpenAI_API_Key_입력
AZURE_API_BASE=https://your-resource-name.openai.azure.com
AZURE_API_VERSION=2025-03-01-preview

# Claude 티어별 Azure 배포 (opus=Sol, sonnet=Terra, haiku=Luna)
AZURE_DEPLOYMENT_OPUS=your-gpt-56-sol-deployment-name
AZURE_DEPLOYMENT_SONNET=your-gpt-56-terra-deployment-name
AZURE_DEPLOYMENT_HAIKU=your-gpt-56-luna-deployment-name

LITELLM_HOST=127.0.0.1
LITELLM_PORT=4000
LITELLM_MASTER_KEY=sk-local-claude-code-proxy

# Claude Code에 노출할 티어별 별칭
CLAUDE_CODE_OPUS_ALIAS=opus
CLAUDE_CODE_SONNET_ALIAS=sonnet
CLAUDE_CODE_HAIKU_ALIAS=haiku
```

설정과 자동 수명 주기를 확인한 뒤 `claude-azure` 명령을 설치합니다.

```bash
make doctor
make test-lifecycle
make alias
source ~/.zshrc
```

`make test-lifecycle`은 mock 프록시를 사용하므로 Azure 요청이나 모델 사용 비용이 발생하지 않습니다. 정상이라면 `All lifecycle tests passed.`가 출력됩니다.

이제 작업하려는 프로젝트로 이동해 실행합니다.

```bash
cd /path/to/your/project
claude-azure
```

`claude-azure`가 LiteLLM을 자동으로 시작하고, 마지막 Claude Code 세션이 끝나면 자신이 시작한 프록시를 자동 종료합니다. 별도로 `make proxy`를 먼저 실행할 필요가 없습니다.

주의할 점:

- `AZURE_API_BASE`는 Azure OpenAI 리소스의 endpoint입니다.
- `AZURE_DEPLOYMENT_OPUS`/`AZURE_DEPLOYMENT_SONNET`/`AZURE_DEPLOYMENT_HAIKU`는 모델 이름이 아니라 Azure에서 만든 deployment name이며, Claude의 opus/sonnet/haiku 티어에 각각 매핑됩니다.
- `AZURE_API_VERSION`은 `2025-03-01-preview` 이상이어야 합니다.
- `LITELLM_MASTER_KEY`는 Claude Code와 로컬 LiteLLM 사이에서 사용하는 로컬 인증 키입니다. 실제 Anthropic API 키가 아닙니다.
- `LITELLM_HOST`는 외부에 노출되지 않도록 기본값 `127.0.0.1` 사용을 권장합니다.
- `CLAUDE_CODE_OPUS_ALIAS`/`CLAUDE_CODE_SONNET_ALIAS`/`CLAUDE_CODE_HAIKU_ALIAS`는 Claude Code에 노출할 티어별 이름이며 Azure deployment name과 달라도 됩니다.
- `.env`는 Git에 올라가지 않도록 무시 처리되어 있습니다.
- `make doctor`에서 `env ok`가 나오면 환경 설정 검사가 완료된 것입니다.
- `claude-azure`를 찾지 못하면 `source ~/.zshrc`를 실행하세요. shim을 직접 사용할 경우에는 `~/.local/bin`이 `PATH`에 포함되어 있어야 합니다.
- 저장소를 이동했다면 새 경로에서 `make alias`를 다시 실행하세요.

## 매번 사용하는 방법

처음 한 번 alias를 설치한 뒤에는 작업할 프로젝트 디렉터리에서 `claude-azure`만 실행합니다. LiteLLM 프록시는 자동으로 백그라운드에서 시작되고, 마지막 Claude Code 세션이 끝나면 자동으로 종료됩니다.

## 어느 레포에서든 쉽게 실행하기

매번 긴 스크립트 경로를 입력하지 않으려면 alias를 한 번만 등록합니다.

```bash
cd /path/to/claude-code-azure-openai-proxy
make alias
source ~/.zshrc
```

`make alias`는 두 가지를 설정합니다.

- `~/.zshrc`에 `claude-azure` alias 등록
- `~/.local/bin/claude-azure` 실행 파일 shim 생성

이후부터는 작업하려는 프로젝트 폴더로 먼저 이동한 뒤 `claude-azure`만 실행하면 됩니다.

```bash
cd /path/to/your/project
claude-azure
```

중요한 점:

- `claude-azure`는 현재 터미널의 작업 디렉토리에서 Claude Code를 실행합니다.
- 그래서 먼저 작업할 레포로 `cd`한 다음 실행해야 합니다.
- 기존 Claude Code 전역 설정은 그대로 사용하고, 모델 요청 경로만 LiteLLM/Azure OpenAI로 바뀝니다.
- alias를 다시 등록해도 기존 블록을 교체하므로 `~/.zshrc`에 중복으로 쌓이지 않습니다.
- 이미 열린 터미널에서 alias가 바로 안 잡히면 `source ~/.zshrc`를 한 번 실행하세요.
- 저장소를 다른 경로로 옮겼다면 새 경로에서 `make alias`를 다시 실행하세요.

### 프록시 자동 수명 주기

`claude-azure`는 다음 순서로 동작합니다.

1. 이 저장소의 `.env`를 읽고 LiteLLM 상태를 확인합니다.
2. 프록시가 없으면 `.claude-runtime/`에 로그와 PID 정보를 두고 백그라운드로 시작합니다.
3. 프록시가 준비된 뒤 현재 디렉터리에서 Claude Code를 실행합니다.
4. 동시에 여러 `claude-azure` 세션이 있으면 프록시 하나를 공유합니다.
5. 마지막 세션이 끝나면 이 launcher가 시작한 프록시만 자동 종료합니다.

사용자가 `make proxy` 등으로 미리 실행한 호환 프록시는 재사용하지만 `claude-azure`가 소유하지 않으므로 자동으로 종료하지 않습니다. 같은 포트에 인증되지 않은 다른 서비스가 있으면 해당 프로세스를 종료하지 않고 시작 오류를 표시합니다.

수동으로 프록시 로그와 상태를 확인할 수 있습니다.

```bash
make status
tail -f .claude-runtime/proxy.log
```

프록시 자체를 디버깅할 때만 포그라운드 실행을 사용합니다.

```bash
make proxy
```

### 연결 테스트

처음 실행할 때는 프록시가 잘 동작하는지 확인합니다.

```bash
cd /path/to/claude-code-azure-openai-proxy
make test
```

아래처럼 응답이 오면 성공입니다.

```json
{
  "model": "gpt-5.6-sol",
  "content": [
    {
      "type": "text",
      "text": "The proxy works."
    }
  ]
}
```

### Claude Code 실행

현재 레포에서 Claude Code를 실행하려면 아래 명령을 씁니다.

```bash
make claude
```

다른 프로젝트에서 Claude Code를 실행하려면, 먼저 그 프로젝트 폴더로 이동한 뒤 이 레포의 실행 스크립트를 호출합니다.

```bash
cd /path/to/your/project
/path/to/claude-code-azure-openai-proxy/scripts/claude-via-azure-openai.sh
```

Claude Code 화면에서 API key 사용 여부를 물어보면 `Yes`를 선택하세요. 이 키는 실제 Anthropic 키가 아니라 로컬 LiteLLM 프록시에 접근하기 위한 키입니다.

이 실행 스크립트는 기존 전역 Claude Code 설정인 `~/.claude`를 그대로 사용합니다. `CLAUDE_CONFIG_DIR`을 바꾸지 않고, 권한 설정, status line, `claude-hud`, 플러그인, 훅도 건드리지 않습니다.

즉 `claude`를 직접 실행했을 때와 동일한 Claude Code 환경에서, 모델 요청 경로만 LiteLLM/Azure OpenAI로 바뀝니다.

## 종료 방법

Claude Code 화면에서 종료하면 됩니다.

```text
/exit
```

마지막 `claude-azure` 세션이면 자동으로 시작했던 LiteLLM도 함께 종료됩니다. 상태가 궁금하면 다음 명령을 사용합니다.

```bash
make status
```

비정상 종료 뒤 managed 프록시가 남아 있으면 안전하게 종료할 수 있습니다. 활성 Claude 세션이 있으면 `make stop`은 중단하여 다른 세션을 보호합니다.

```bash
make stop
```

활성 세션을 중단해도 되는 경우에만 강제 관리 종료를 사용합니다.

```bash
make stop-force
```

이 명령들은 이 저장소가 관리하는 프로세스만 종료하며, 같은 포트의 외부 프로세스는 종료하지 않습니다. 포그라운드 `make proxy`를 실행했다면 해당 터미널에서 `Ctrl-C`로 종료합니다.

## 내부 동작 방식

`scripts/claude-via-azure-openai.sh`는 Claude Code 실행 전에 아래 환경변수를 설정합니다.

```bash
ANTHROPIC_BASE_URL=http://127.0.0.1:4000
ANTHROPIC_AUTH_TOKEN=$LITELLM_MASTER_KEY
ANTHROPIC_MODEL=opus
ANTHROPIC_DEFAULT_SONNET_MODEL=sonnet
ANTHROPIC_DEFAULT_HAIKU_MODEL=haiku
CLAUDE_CODE_SUBAGENT_MODEL=sonnet
```

Claude Code 입장에서는 `http://127.0.0.1:4000`에 있는 Anthropic 호환 API를 호출합니다. 실제로는 LiteLLM이 이 요청을 Azure OpenAI 요청으로 변환합니다.

모델 연결은 `config/litellm.config.yaml` 템플릿을 사용합니다.

```yaml
model_list:
  - model_name: __CLAUDE_CODE_OPUS_ALIAS__
    litellm_params:
      model: azure/__AZURE_DEPLOYMENT_OPUS__
  - model_name: __CLAUDE_CODE_SONNET_ALIAS__
    litellm_params:
      model: azure/__AZURE_DEPLOYMENT_SONNET__
  - model_name: __CLAUDE_CODE_HAIKU_ALIAS__
    litellm_params:
      model: azure/__AZURE_DEPLOYMENT_HAIKU__
```

`make proxy`를 실행하면 `.env` 값을 읽어서 `.generated/litellm.config.yaml`을 만들고 LiteLLM을 실행합니다.

## Azure OpenAI 프록시 사용 시 안정화 원칙

이 방식은 Claude Code의 공식 Azure OpenAI 네이티브 연동이 아닙니다. Claude Code는 Anthropic 모델과 Anthropic tool/use 메시지 형식을 기준으로 만들어져 있고, LiteLLM이 그 요청을 Azure OpenAI 요청으로 변환합니다.

따라서 아래 원칙을 지키는 것이 좋습니다.

- 일반 사용은 `make claude`, `claude-azure` 또는 `scripts/claude-via-azure-openai.sh`로 시작해 프록시 수명 주기를 자동 관리합니다.
- 기존 Claude Code 전역 설정은 그대로 사용합니다.
- Claude Code 고급 기능 중 일부는 Anthropic 모델 기준으로 동작하므로, Azure OpenAI에서는 간단한 코드 작업부터 검증합니다.
- 문제가 생기면 먼저 `make test`로 LiteLLM 연결을 확인하고, 그 다음 `make claude`로 Claude Code 레벨을 확인합니다.

## 자주 나는 오류

### 1. Azure Responses API version 오류

오류 메시지:

```text
Azure OpenAI Responses API is enabled only for api-version 2025-03-01-preview and later
```

해결:

`.env`에서 `AZURE_API_VERSION`을 `2025-03-01-preview` 이상으로 바꿉니다.

```bash
AZURE_API_VERSION=2025-03-01-preview
```

그 다음 프록시를 재시작합니다.

```bash
make restart
```

### 2. Auth conflict 경고

오류 메시지:

```text
Auth conflict: Both a token (ANTHROPIC_AUTH_TOKEN) and an API key (ANTHROPIC_API_KEY) are set.
```

해결:

최신 스크립트는 `ANTHROPIC_API_KEY`를 사용하지 않고 `ANTHROPIC_AUTH_TOKEN`만 사용합니다. 아래 명령으로 최신 변경을 받은 뒤 다시 실행하세요.

```bash
git pull
make claude
```

로컬 셸에 `ANTHROPIC_API_KEY`가 직접 설정되어 있다면 해제합니다.

```bash
unset ANTHROPIC_API_KEY
```

### 3. 프록시 연결 실패

오류 예시:

```text
Connection refused
Could not connect to 127.0.0.1:4000
```

해결:

프록시가 켜져 있는지 확인합니다.

```bash
make proxy
```

프록시는 Claude Code를 쓰는 동안 계속 실행되어 있어야 합니다.

### 4. 모델 또는 deployment 오류

오류 예시:

```text
DeploymentNotFound
The API deployment for this resource does not exist
```

해결:

`.env`의 `AZURE_DEPLOYMENT_OPUS`/`AZURE_DEPLOYMENT_SONNET`/`AZURE_DEPLOYMENT_HAIKU`가 Azure OpenAI Studio의 deployment name과 정확히 같은지 확인하세요.

```bash
AZURE_DEPLOYMENT_OPUS=your-gpt-56-sol-deployment-name
AZURE_DEPLOYMENT_SONNET=your-gpt-56-terra-deployment-name
AZURE_DEPLOYMENT_HAIKU=your-gpt-56-luna-deployment-name
```

## Windows 제한망/폐쇄망 배포 가이드

이 섹션은 인터넷 접속이 제한된 Windows 개발 환경에서 Claude Code를 Azure OpenAI 프록시와 함께 쓰기 위한 배포 방식입니다. 내부 보안 정책에 맞춰 승인된 파일만 반입하고, 무결성 검증 결과를 남기는 것을 전제로 합니다.

중요한 전제:

- Claude Code 실행 파일은 반입 설치할 수 있습니다.
- 이 레포와 LiteLLM 프록시도 내부망에 배포할 수 있습니다.
- 단, 모델 요청은 결국 Azure OpenAI 또는 내부 LLM Gateway에 도달해야 합니다.
- 완전 물리 폐쇄망에서 Azure OpenAI endpoint로 나갈 수 없다면 이 방식으로 모델 호출은 불가능합니다.
- Azure OpenAI Private Endpoint, ExpressRoute, 사내 전용망, 내부 API Gateway 등 승인된 경로가 있어야 합니다.

권장 구조:

```text
Windows 개발 PC
  -> Claude Code
  -> 로컬 LiteLLM 프록시 또는 내부 공용 LiteLLM 프록시
  -> Azure OpenAI Private Endpoint / 내부 LLM Gateway
  -> Azure OpenAI GPT-5.6-sol 배포
```

### 케이스 A: 개발자 PC마다 로컬 프록시 실행

각 Windows PC에 Claude Code와 LiteLLM을 설치하고, 프록시를 `127.0.0.1:4000`으로 띄우는 방식입니다.

장점:

- 사용자별 API key와 설정 분리가 쉽습니다.
- 장애가 한 사용자 PC에만 한정됩니다.
- 이 레포의 기본 구조와 가장 비슷합니다.

단점:

- PC마다 Python/Docker/LiteLLM 실행 환경이 필요합니다.
- 버전 관리와 업데이트 배포를 사용자가 따라야 합니다.

사용 흐름:

```text
PowerShell 1: LiteLLM 프록시 실행
PowerShell 2: Claude Code 실행
```

### 케이스 B: 내부망에 공용 LiteLLM 프록시 운영

개발자 PC에는 Claude Code만 설치하고, LiteLLM은 내부 서버에서 운영하는 방식입니다.

장점:

- 개발자 PC 설치 항목이 줄어듭니다.
- Azure OpenAI key를 중앙에서 관리할 수 있습니다.
- 로깅, rate limit, 모델 라우팅을 한 곳에서 관리하기 좋습니다.

단점:

- 내부 프록시 서버가 공용 장애 지점이 됩니다.
- 인증, 접근 제어, 감사 로그 설계가 필요합니다.
- `ANTHROPIC_BASE_URL`을 내부 프록시 주소로 바꿔야 합니다.

예시:

```powershell
$env:ANTHROPIC_BASE_URL = "https://llm-gateway.internal.example.com"
$env:ANTHROPIC_AUTH_TOKEN = "내부_프록시_토큰"
$env:ANTHROPIC_MODEL = "opus"
$env:ANTHROPIC_DEFAULT_SONNET_MODEL = "sonnet"
$env:ANTHROPIC_DEFAULT_HAIKU_MODEL = "haiku"
claude
```

### Windows용 Claude Code 설치 파일 준비

외부망 준비 PC에서 Windows용 Claude Code 설치 artifact를 준비합니다. Anthropic 공식 문서 기준으로 Claude Code native installer는 Windows PowerShell 설치를 지원합니다.

공식 문서:

- Claude Code 설치: <https://docs.anthropic.com/en/docs/claude-code/setup>
- Claude Code Quickstart: <https://docs.anthropic.com/en/docs/claude-code/quickstart>

외부망에서 일반 설치를 검증할 때의 공식 PowerShell 설치 방식:

```powershell
irm https://claude.ai/install.ps1 | iex
```

제한망 반입용으로는 위 명령을 내부망 PC에서 바로 실행하는 방식이 아니라, 외부망 준비 PC에서 공식 installer가 내려받는 Windows용 native artifact를 확보하고 검증한 뒤 내부 승인 저장소로 옮기는 흐름을 권장합니다. artifact URL이나 파일명은 버전에 따라 바뀔 수 있으므로 README에 고정하지 않습니다.

권장 순서:

1. 외부망 준비 PC에서 공식 installer 또는 기존 `claude install` 경로로 Windows용 native 설치를 먼저 검증합니다.
2. 설치 과정에서 확보한 Windows용 Claude Code artifact, manifest, signature, checksum을 함께 보관합니다.
3. 공식 문서의 manifest/signature/checksum 절차로 무결성을 검증합니다.
4. 검증 결과, 버전, 파일명, SHA256 값을 기록합니다.
5. 내부 보안 절차에 따라 승인된 저장소나 파일 배포 경로에 올립니다.
6. Windows 개발 PC에서 설치합니다.

검증 시 확인할 것:

- Claude Code 버전
- OS/아키텍처: Windows x64 또는 Windows ARM64
- SHA256 checksum
- Anthropic release signing key fingerprint
- 내부 반입 승인 이력

공식 문서에서 공개된 Anthropic release signing key fingerprint:

```text
31DD DE24 DDFA B679 F42D  7BD2 BAA9 29FF 1A7E CACE
```

주의:

- 검증되지 않은 블로그, 미러, 개인 저장소의 설치 파일은 사용하지 마세요.
- 설치 스크립트가 특정 시점에 내려받는 파일명과 경로를 문서에 하드코딩하지 마세요. 버전이 바뀌면 깨지고, 잘못된 artifact를 고정할 위험이 있습니다.
- npm 방식으로 반입할 경우 `@anthropic-ai/claude-code` 본 패키지뿐 아니라 Windows 플랫폼용 optional dependency까지 같이 준비해야 합니다.
- 조직 표준이 없다면 Windows에서는 native binary 또는 공식 패키지 기반 배포가 npm 복사보다 운영하기 쉽습니다.

### Windows에서 LiteLLM 준비

인터넷이 제한된 Windows 환경에서는 `uvx`가 즉석에서 LiteLLM을 다운로드하지 못합니다. 아래 둘 중 하나를 선택하세요.

#### 방식 1: Docker 이미지 반입

Docker Desktop 또는 사내 컨테이너 런타임 사용이 가능하면 가장 단순합니다.

외부망 준비 PC:

```powershell
docker pull ghcr.io/berriai/litellm:main-latest
docker save ghcr.io/berriai/litellm:main-latest -o litellm-main-latest.tar
```

운영 배포에서는 `main-latest` 대신 내부 검증이 끝난 고정 버전 태그를 사용하는 것을 권장합니다.

내부망 Windows PC:

```powershell
docker load -i .\litellm-main-latest.tar
```

그 다음 이 레포의 `config/litellm.config.yaml`을 기준으로 내부 환경에 맞는 실행 스크립트를 만듭니다.

#### 방식 2: Python wheelhouse 반입

Docker를 사용할 수 없으면 외부망에서 Python wheel 파일을 모두 받아 내부망으로 옮깁니다.

외부망 준비 PC:

```powershell
mkdir wheelhouse
pip download "litellm[proxy]" -d wheelhouse
```

내부망 Windows PC:

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install --no-index --find-links .\wheelhouse "litellm[proxy]"
```

이 방식은 Python 버전과 OS/아키텍처가 외부망 준비 PC와 내부망 PC에서 맞아야 합니다.

### Windows용 환경 파일 예시

PowerShell에서는 `.env`를 자동으로 source하지 않습니다. Windows 전용으로는 `.ps1` 실행 스크립트를 별도로 두는 것을 권장합니다.

예시 `Start-Proxy.ps1`:

```powershell
$env:AZURE_API_KEY = "여기에_Azure_OpenAI_API_Key_입력"
$env:AZURE_API_BASE = "https://your-resource-name.openai.azure.com"
$env:AZURE_API_VERSION = "2025-03-01-preview"
$env:AZURE_DEPLOYMENT_OPUS = "your-gpt-56-sol-deployment-name"
$env:AZURE_DEPLOYMENT_SONNET = "your-gpt-56-terra-deployment-name"
$env:AZURE_DEPLOYMENT_HAIKU = "your-gpt-56-luna-deployment-name"
$env:LITELLM_MASTER_KEY = "sk-local-claude-code-proxy"

litellm --config .\config\litellm.config.yaml --host 127.0.0.1 --port 4000
```

예시 `Start-Claude-Via-AzureOpenAI.ps1`:

```powershell
$env:ANTHROPIC_BASE_URL = "http://127.0.0.1:4000"
$env:ANTHROPIC_AUTH_TOKEN = "sk-local-claude-code-proxy"
Remove-Item Env:\ANTHROPIC_API_KEY -ErrorAction SilentlyContinue

$env:ANTHROPIC_MODEL = "opus"
$env:ANTHROPIC_DEFAULT_SONNET_MODEL = "sonnet"
$env:ANTHROPIC_DEFAULT_HAIKU_MODEL = "haiku"
$env:CLAUDE_CODE_SUBAGENT_MODEL = "sonnet"

$env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1"
$env:DISABLE_TELEMETRY = "1"
$env:CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL = "1"
$env:CLAUDE_CODE_PLUGIN_KEEP_MARKETPLACE_ON_FAILURE = "1"

claude
```

이 PowerShell 예시는 기존 Claude Code 전역 설정을 그대로 사용합니다. `CLAUDE_CONFIG_DIR`을 바꾸지 않으므로 기존 권한 설정, status line, 플러그인, 훅은 그대로 유지됩니다.

### Windows에서 실행 순서

1. PowerShell 1에서 프록시 실행

```powershell
.\Start-Proxy.ps1
```

2. PowerShell 2에서 프록시 테스트

```powershell
curl.exe http://127.0.0.1:4000/v1/messages `
  -H "Authorization: Bearer sk-local-claude-code-proxy" `
  -H "x-api-key: sk-local-claude-code-proxy" `
  -H "anthropic-version: 2023-06-01" `
  -H "content-type: application/json" `
  -d "{ `"model`": `"gpt-5.6-sol`", `"max_tokens`": 64, `"messages`": [{ `"role`": `"user`", `"content`": `"Reply with one short sentence confirming the proxy works.`" }] }"
```

3. PowerShell 2에서 Claude Code 실행

```powershell
.\Start-Claude-Via-AzureOpenAI.ps1
```

### 제한망에서 기능별 기대 동작

| 기능 | 기대 동작 |
| --- | --- |
| 코드 읽기/수정 | 정상 동작 |
| Bash/PowerShell 도구 | 로컬 PC 권한 범위에서 동작 |
| Claude Code status line / claude-hud | 해당 플러그인이 내부망에 설치되어 있으면 동작 |
| WebSearch/WebFetch | 외부 인터넷 차단 시 실패 가능 |
| Plugin marketplace 자동 설치 | 차단 권장 |
| GitHub App / 외부 SaaS MCP | 내부망 접근 정책에 따라 실패 가능 |
| Azure OpenAI 모델 호출 | Private Endpoint/Gateway 경로가 있으면 동작 |

### 제한망 운영 체크리스트

- Windows용 Claude Code 설치 artifact를 공식 출처에서 확보했습니다.
- 설치 artifact의 checksum/signature를 검증했습니다.
- Azure OpenAI endpoint가 내부망에서 접근 가능합니다.
- LiteLLM 실행 방식이 정해졌습니다: 로컬 Docker, 로컬 Python, 또는 내부 공용 프록시.
- `ANTHROPIC_BASE_URL`이 LiteLLM 주소를 가리킵니다.
- `ANTHROPIC_AUTH_TOKEN`과 LiteLLM master key가 일치합니다.
- `ANTHROPIC_API_KEY`는 설정하지 않습니다.
- `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`을 설정했습니다.
- `DISABLE_TELEMETRY=1`을 설정했습니다.
- `CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL=1`을 설정했습니다.
- 필요한 플러그인은 내부망에 사전 배포했습니다.

## 참고 문서

- Claude Code LLM Gateway: https://code.claude.com/docs/en/llm-gateway
- Claude Code Settings: https://docs.anthropic.com/en/docs/claude-code/settings
- LiteLLM Docs: https://docs.litellm.ai/
