# Providers

Checked against the official documentation on 2026-10-30. Recheck before changing defaults.

| | Groq (default) | OpenAI |
| --- | --- | --- |
| Endpoint | `https://api.groq.com/openai/v1/audio/transcriptions` | `https://api.openai.com/v1/audio/transcriptions` |
| Default model | `whisper-large-v3` (also offered: `whisper-large-v3-turbo`) | `gpt-transcribe` (`whisper-1` and the `gpt-4o-*-transcribe` models are deprecated, shutting down 2027-02-26) |
| Fields sent | `file` (`audio.m4a`), `model`, `response_format=json`, `temperature=0`, optional `language` | `file` (`audio.m4a`), `model`, optional `languages[]` (`gpt-transcribe` replaces the singular `language`) |
| Upload cap | 25 MB on the free tier (100 MB on the dev tier; not assumed) | 25 MB |
| Ramble Flow target | 20 MB and 30 minutes per request | 20 MB and 20 minutes per request (no duration limit documented) |
| Key check | `GET /openai/v1/models` | `GET /v1/models` |

- Hosts are fixed in code over HTTPS. There is no configurable base URL.
- The installer's key check lists models. It proves the key is accepted, not that you have quota
  or billing set up; the first real recording does that. No audio is sent by the check.
- Any model id can be entered at the installer's sixth question. If the provider rejects it, the
  recording is marked "needs attention" (`ramble-flow list`) and no other provider or model is
  tried.
- Language: automatic by default. The hint is an ISO 639-1 code. Speech is never translated.
- Error bodies are reduced to the provider's machine-readable code; messages (which can echo part of
  a key) are not stored or shown.
- Free-tier limits, prices and terms change: [Groq rate limits](https://console.groq.com/docs/rate-limits),
  [OpenAI rate limits](https://platform.openai.com/docs/guides/rate-limits).

References: [Groq speech-to-text](https://console.groq.com/docs/speech-to-text),
[OpenAI speech-to-text](https://developers.openai.com/api/docs/guides/speech-to-text).
