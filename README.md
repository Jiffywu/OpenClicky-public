# OpenClicky

A clean-room, working rebuild of the HeyClicky macOS assistant: a voice buddy that sees your screen, points and draws on it, builds 3D figures while it talks, and hands longer jobs to a background agent.

Parts that HeyClicky builds into the app are rebuilt as fixed code. Parts where HeyClicky gets a model through its own server become **typed model slots**: each slot accepts only models of the right kind (speech-to-text, voice output, multimodal brain, agent harness), configured as bring-your-own-key / provider / harness.

Status: under construction. This public repository starts from a cleaned development snapshot with fresh history. The original development archive remains private. See the [status and remaining work](docs/parity-status.md), [parity inventory](docs/parity.md), and [integration record](docs/integration.md). Historical PR numbers in those documents refer to the private archive.

Read the [security notes](SECURITY.md) and [data handling notes](PRIVACY.md) before connecting providers or enabling computer control. Generated evidence stays local and is ignored by Git. Reviewed test inputs live in [Tests/Fixtures](Tests/Fixtures/README.md).

OpenClicky's original code is available under the [MIT license](LICENSE). Bundled third-party components retain their [own licenses](THIRD_PARTY_NOTICES.md).

## Get the source

```sh
git clone https://github.com/Jiffywu/OpenClicky-public.git
cd OpenClicky-public
```

Build on macOS with Swift 6 and a recent macOS SDK. [Contributor credit](AUTHORS.md) and the [public import manifest](docs/public-source.json) preserve attribution without importing private Git objects.

## Clean-room rule

OpenClicky reimplements observed behavior. It does not contain HeyClicky code, prompts, sounds, videos or icons. Third-party code that HeyClicky itself vendors under open licenses (three.js, MIT; Barlow and Patrick Hand fonts, OFL) may be used under those licenses from their upstream sources.

## Model slots

| Slot | Accepts | HeyClicky default |
|---|---|---|
| `stt` | speech-to-text models (audio in, text out) | Deepgram nova-3, Apple Speech fallback |
| `voice` | text-to-speech or realtime speech models (text in, audio out) | OpenAI gpt-realtime-2.1-mini, voice `cedar` |
| `brain` | language models with tool calling and streaming; vision preferred | GPT-6.1 Sol (medium) |
| `agent` | an agent harness (Codex CLI or Claude Code) plus a language model it can talk to | Codex CLI + gpt-6-luna |

Config lives at `~/Library/Application Support/OpenClicky/config.json` and only names credentials; keys stay in the Keychain.

```sh
swift build
.build/debug/occtl init                 # HeyClicky-like defaults
.build/debug/occtl key set openai       # paste the key; stored in the Keychain
.build/debug/occtl models brain         # what the brain slot accepts, per provider dialect
.build/debug/occtl validate             # every slot checked; exit 1 on errors
.build/debug/occtl engines              # which adapter each slot resolves to (no network)
.build/debug/occtl say --apple "Hello"  # speak a line through the voice slot (--apple: the on-device voice)
.build/debug/occtl tools list           # local app tools the brain can call; tools call --dry-run <name> <json> runs nothing
```
