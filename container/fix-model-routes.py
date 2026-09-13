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
    # Two different situations, and only one of them is a failure.
    #
    # No `model_routes:` at all is the ordinary state of a gateway that has not been given a
    # provider yet - and of every config.yaml adopted from the compose deployment. There is
    # nothing to add a route into, so there is nothing to do. The compose-era deploy.sh said the
    # same thing with `|| echo "(model routes: no model_routes section yet)"`; in the image this
    # script is the last command of woow-provision, so a non-zero exit here fails
    # hermes-provision.service and, through it, scripts/install.sh.
    if not any('model_routes:' in line for line in lines):
        print("No model_routes section yet: nothing to add "
              "(the gateway writes one once a provider is configured)")
        sys.exit(0)
    # A model_routes section that carries no api_key: line is not a state this script understands,
    # and guessing an insertion point in someone's config is worse than stopping.
    print("ERROR: model_routes exists but has no api_key: line to insert after")
    sys.exit(1)

lines.insert(insert_idx + 1, insertion)

with open(CONFIG, 'w') as f:
    f.write('\n'.join(lines))

print(f"Added {added} model routes ({added // len(MODELS)} prefixes x {len(MODELS)} models)")
