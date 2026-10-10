#!/usr/bin/env bash
# Static verification shared by local development and GitHub Actions.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

printf '%s\n' 'Checking shell syntax'
for script in scripts/*.sh; do
    bash -n "$script"
done

printf '%s\n' 'Checking whitespace'
git diff --check

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
    for name in ('bootstrap_admin.sh', 'test_inference.sh', 'test_rag.sh'):
        script = scripts / name
        script.write_bytes((Path('scripts') / name).read_bytes())
        result = subprocess.run(['bash', str(script)], env={'PATH': os.environ['PATH']},
                                capture_output=True, text=True)
        assert result.returncode != 0 and 'LITELLM_MASTER_KEY' in result.stderr, name
print('Compose validation, required credentials, port bindings, and fail-fast checks passed.')
PY
