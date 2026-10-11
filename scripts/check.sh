#!/usr/bin/env bash
# Static verification shared by local development and GitHub Actions.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

printf '%s\n' 'Checking shell syntax'
for script in scripts/*.sh; do
    bash -n "$script"
done

printf '%s\n' 'Checking whitespace'
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git diff --check "$(git hash-object -t tree /dev/null)"
else
    python3 - <<'PY'
from pathlib import Path
import sys

skip = {'.git'}
for path in sorted(Path('.').rglob('*')):
    if not path.is_file() or any(part in skip for part in path.parts):
        continue
    data = path.read_bytes()
    if b'\0' in data:
        continue
    text = data.decode('utf-8')
    if text.endswith('\n\n'):
        sys.exit(f'{path}: blank line at end of file')
    for number, line in enumerate(text.splitlines(), 1):
        if line.endswith((' ', '\t')):
            sys.exit(f'{path}:{number}: trailing whitespace')
        if line.startswith(('<<<<<<< ', '>>>>>>> ')):
            sys.exit(f'{path}:{number}: conflict marker')
PY
fi

printf '%s\n' 'Checking dotenv loader'
loader_sample="$(mktemp)"
cat > "$loader_sample" <<'EOF'
SAMPLE_TOKEN=$(printf pwned)
SAMPLE_QUOTED="hash#value"
EOF
literal="$(bash --noprofile --norc -c '
    set -euo pipefail
    source scripts/load_env.sh
    load_env_file "$1"
    printf "%s\n%s" "$SAMPLE_TOKEN" "$SAMPLE_QUOTED"
' bash "$loader_sample")"
expected="$(printf '%s\n%s' '$(printf pwned)' 'hash#value')"
preset="$(SAMPLE_TOKEN=from-env bash --noprofile --norc -c '
    set -euo pipefail
    source scripts/load_env.sh
    load_env_file "$1"
    printf "%s" "$SAMPLE_TOKEN"
' bash "$loader_sample")"
rm -f "$loader_sample"
if [ "$literal" != "$expected" ]; then
    printf '%s\n' 'Error: dotenv loader evaluated a value.' >&2
    exit 1
fi
if [ "$preset" != "from-env" ]; then
    printf '%s\n' 'Error: dotenv loader overrode the environment.' >&2
    exit 1
fi

printf '%s\n' 'Checking Compose and credential boundaries with synthetic values'
python3 - <<'PY'
import json
import os
from pathlib import Path
import subprocess
import tempfile

# Do not read an operator's .env or print rendered credentials.
env = {key: value for key, value in os.environ.items()
       if key in ('PATH', 'HOME', 'DOCKER_CONFIG')}
for line in Path('.env.example').read_text().splitlines():
    if line and not line.startswith('#') and '=' in line:
        key, value = line.split('=', 1)
        env[key] = value
for key in ('LITELLM_MASTER_KEY', 'POSTGRES_PASSWORD', 'RAG_DB_PASSWORD',
            'LITELLM_ADMIN_PASSWORD'):
    env[key] = 'sk-synthetic-check-only' if key == 'LITELLM_MASTER_KEY' else 'synthetic-check-only'
env['HF_TOKEN'] = ''
command = ['docker', 'compose', '--env-file', '/dev/null', 'config', '--format', 'json']

def render(values):
    return subprocess.run(command, env=values, capture_output=True, text=True)

result = render(env)
if result.returncode:
    raise SystemExit('Compose validation failed; run with a synthetic environment to diagnose.')
services = json.loads(result.stdout)['services']
assert set(services) == {'vllm', 'litellm', 'litellm-db', 'redis', 'rag-db'}
for name in ('vllm', 'litellm', 'rag-db'):
    assert all(port['host_ip'] == '127.0.0.1' for port in services[name]['ports']), name
assert services['litellm']['environment']['LITELLM_MASTER_KEY'] == env['LITELLM_MASTER_KEY']
assert services['litellm-db']['environment']['POSTGRES_PASSWORD'] == env['POSTGRES_PASSWORD']
assert services['rag-db']['environment']['POSTGRES_PASSWORD'] == env['RAG_DB_PASSWORD']
assert 'master_key: os.environ/LITELLM_MASTER_KEY' in Path('config/litellm_config.yaml').read_text()
config = Path('config/litellm_config.yaml').read_text()
assert 'model_name: os.environ/VLLM_MODEL' in config
assert 'model: os.environ/VLLM_LITELLM_MODEL' in config
assert services['litellm']['environment']['VLLM_MODEL'] == env['VLLM_MODEL']
assert services['litellm']['environment']['VLLM_LITELLM_MODEL'] == 'openai/' + env['VLLM_MODEL']
vllm_command = services['vllm']['command']
if isinstance(vllm_command, list):
    vllm_command = ' '.join(str(part) for part in vllm_command)
assert env['VLLM_MODEL'] in str(vllm_command)
assert int(services['rag-db']['shm_size']) == 2 * 1024 ** 3
assert 'healthcheck' in services['litellm-db']
depends = services['litellm']['depends_on']
assert depends['litellm-db']['condition'] == 'service_healthy'
assert depends['redis']['condition'] == 'service_healthy'
assert depends['vllm']['condition'] == 'service_started'
for key in ('LITELLM_MASTER_KEY', 'POSTGRES_PASSWORD', 'RAG_DB_PASSWORD'):
    missing = dict(env)
    missing.pop(key)
    assert render(missing).returncode != 0, f'{key} must be required'
custom = dict(env, LITELLM_BIND_ADDRESS='192.0.2.1', RAG_DB_BIND_ADDRESS='192.0.2.2')
result = render(custom)
assert result.returncode == 0
custom_services = json.loads(result.stdout)['services']
assert custom_services['litellm']['ports'][0]['host_ip'] == '192.0.2.1'
assert custom_services['rag-db']['ports'][0]['host_ip'] == '192.0.2.2'
assert custom_services['vllm']['ports'][0]['host_ip'] == '127.0.0.1'

# Exercise scripts outside the checkout to prove missing credentials fail before
# any network or Docker access, even when a developer has an operator .env.
with tempfile.TemporaryDirectory() as directory:
    scripts = Path(directory) / 'scripts'
    scripts.mkdir()
    for name in ('load_env.sh', 'bootstrap_admin.sh', 'test_inference.sh', 'test_rag.sh'):
        (scripts / name).write_bytes((Path('scripts') / name).read_bytes())
    for name in ('bootstrap_admin.sh', 'test_inference.sh', 'test_rag.sh'):
        result = subprocess.run(['bash', str(scripts / name)], env={'PATH': os.environ['PATH']},
                                capture_output=True, text=True)
        assert result.returncode != 0 and 'LITELLM_MASTER_KEY' in result.stderr, (
            name, result.returncode, result.stderr)
print('Compose validation, required credentials, port bindings, and fail-fast checks passed.')
PY
