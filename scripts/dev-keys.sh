#!/bin/zsh
# Map API keys already in your shell environment to OpenClicky's per-credential overrides
# (OPENCLICKY_KEY_<NAME>), for local testing without writing them to the Keychain. Prints names only.
#   source ~/.config/zsh/secrets.zsh && source scripts/dev-keys.sh
typeset -A _oc_map
_oc_map=(
  OPENAI_API_KEY openai
  ANTHROPIC_API_KEY anthropic
  OPENROUTER_API_KEY openrouter
  DEEPSEEK_API_KEY deepseek
  GEMINI_API_KEY gemini
  ELEVENLABS_API_KEY elevenlabs
  DEEPGRAM_API_KEY deepgram
  BRAVE_SEARCH_API_KEY brave
  EXA_API_KEY exa
  TAVILY_API_KEY tavily
  COMPOSIO_API_KEY composio
)
_oc_found=()
for _env _name in ${(kv)_oc_map}; do
  if [[ -n "${(P)_env}" ]]; then
    export "OPENCLICKY_KEY_${(U)_name}=${(P)_env}"
    _oc_found+=($_name)
  fi
done
print -r -- "OpenClicky test keys available: ${(j:, :)${(o)_oc_found}}"
unset _oc_map _oc_found _env _name
