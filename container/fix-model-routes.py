#!/usr/bin/env python3
"""Add @openai: and @openai-api: prefixed model_routes to Hermes Gateway config.yaml.

Problem: WebUI sends model IDs like @openai:gpt-4o-mini (new sessions) or
@openai-api:gpt-4o-mini (old sessions) but Gateway's model_routes only have
bare keys (gpt-4o-mini), so _resolve_route() returns None and falls back to
default MiniMax-M1.

Fix: Add both @openai:* and @openai-api:* prefixed routes pointing to OpenRouter.

Usage (inside container):
  python3 /tmp/fix-model-routes.py [/opt/data/config.yaml]
"""
import os, sys

CONFIG = sys.argv[1] if len(sys.argv) > 1 else '/opt/data/config.yaml'
OPENROUTER_KEY = os.environ.get('OPENROUTER_API_KEY', '__OPENROUTER_API_KEY__')

# All OpenAI models visible in the WebUI picker
MODELS = [
    'gpt-5.5', 'gpt-5.5-pro', 'gpt-5.5-mini', 'gpt-5.4-mini', 'gpt-5.4',
    'gpt-5.4-nano', 'gpt-5-mini', 'gpt-5.3-codex', 'gpt-5.2-codex',
    'gpt-4.1', 'gpt-4o', 'gpt-4o-mini'
]

# ZhipuAI GLM models (bare name routes only, no @openai: prefix needed)
GLM_MODELS = [
    'glm-4.5', 'glm-4.5-flash', 'glm-4.7',
    'glm-5', 'glm-5-turbo', 'glm-5.1'
]

# Both prefixes: @openai: (new catalog IDs) and @openai-api: (old session IDs)
PREFIXES = ['@openai:', '@openai-api:']

with open(CONFIG, 'r') as f:
    content = f.read()

# Build YAML block for missing prefixes
route_lines = []
added = 0
for prefix in PREFIXES:
    if prefix in content:
        print(f"Skipping {prefix} routes (already exist)")
        continue
    for m in MODELS:
        route_lines.append(f'          "{prefix}{m}":')
        route_lines.append(f'            model: openai/{m}')
        route_lines.append(f'            base_url: https://openrouter.ai/api/v1')
        route_lines.append(f'            api_key: {OPENROUTER_KEY}')
        added += 1

# Add GLM bare-name routes
for m in GLM_MODELS:
    key = m
    if key not in content:
        route_lines.append(f'          "{key}":')
        route_lines.append(f'            model: z-ai/{m}')
        route_lines.append(f'            base_url: https://openrouter.ai/api/v1')
        route_lines.append(f'            api_key: {OPENROUTER_KEY}')
        added += 1

if added == 0:
    print("Already patched — both @openai: and @openai-api: routes exist")
    sys.exit(0)

insertion = '\n'.join(route_lines)

# Find insertion point: after last existing route's api_key line in model_routes
lines = content.split('\n')
insert_idx = None
in_model_routes = False

for i, line in enumerate(lines):
    if 'model_routes:' in line:
        in_model_routes = True
    if in_model_routes and line.strip().startswith('api_key:'):
        insert_idx = i

if insert_idx is None:
    print("ERROR: No model_routes section found in config")
    sys.exit(1)

lines.insert(insert_idx + 1, insertion)

with open(CONFIG, 'w') as f:
    f.write('\n'.join(lines))

print(f"Added {added} model routes ({added // len(MODELS)} prefixes x {len(MODELS)} models)")
