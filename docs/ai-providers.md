# AI providers

Magdobe 0.8 supports your own API keys and existing sign-ins through supported CLIs. These connections are optional: drawing, editing, saving, exporting, and vectorizing local images work without an AI provider.

## Choose an image provider

Open **Magdobe Illustrator → Settings…** with **Command-Comma**, or click **Providers…** in **Draw with AI**. Choose the **Image generation** provider:

| Connection | Authentication | What it does |
| --- | --- | --- |
| Codex (default) | Installed Codex CLI with an existing ChatGPT sign-in | Generates one image through Codex, then traces it locally into editable paths. No API key is required. |
| OpenAI | Your OpenAI API key | Uses the Images API, including an optional reference image. |
| Google Gemini | Your Google Gemini API key | Uses an image-capable Gemini model with an optional reference image. |
| OpenRouter | Your OpenRouter API key | Uses an image-capable model available to your OpenRouter account. |
| OpenAI-compatible | Your API base URL, image model, and key when required | Uses `/images/generations` and `/images/edits`. The endpoint must implement the Images API; a chat-only endpoint is insufficient. Local loopback services may omit the key. |

For an API connection, enter the **Model**, **API base URL**, and **API key**, then click **Save Connection** and **Check Connection**. Defaults are supplied for the named services, and model IDs remain editable. Use the API root including its version path, such as `https://api.openai.com/v1`.

Check Connection verifies the provider's response or existing CLI authentication without generating an image. A successful check does not guarantee access to every model or prompt. Image generation uses the chosen provider's account, billing, and usage limits. A ChatGPT or Claude subscription does not automatically include API credits.

With Codex, install the Codex CLI and sign in using its normal ChatGPT sign-in flow before checking the connection. Magdobe uses that existing sign-in rather than asking you to copy credentials.

## Optional Claude prompt assistant

Under **Prompt assistant · optional**, select **Claude API** or **Claude Code**. Claude refines the artwork brief; the selected image provider generates the illustration.

- **Claude API:** save an Anthropic API key, API base URL, and supported text-model ID.
- **Claude Code:** install Claude Code and run `claude auth login` through its normal sign-in flow. Magdobe uses the installed CLI's existing authentication.

In Draw with AI, enter your brief and click **Improve Prompt**. The **Review Prompt** window lets you edit the suggestion. **Keep Original** leaves the original brief intact; **Use This Prompt** accepts the reviewed text. Generation is a separate action, so you can inspect the final brief before sending it to your image provider.

The Claude Code request receives the brief through standard input. Its tools, MCP servers, local setting sources, and session persistence are disabled for this prompt-only operation. Checking the CLI connection runs `claude auth status` rather than starting a billed model conversation.

## Credentials and data

API keys are stored in macOS Keychain, scoped to the provider and full saved API endpoint. Models and endpoint URLs are stored separately in local preferences. Keys are not included in native projects, profile JSON, job requests, prompts, logs, or command-line arguments. For an operation, only the selected connection's key is passed to its worker in a transient environment value; the Python worker removes that value before launching a CLI child.

Changing the API base URL selects a different Keychain scope. Save a key for that endpoint when needed. **Remove Key** removes the credential for the current saved connection. Magdobe does not copy Codex or Claude Code login credentials into its own settings.

API endpoints require HTTPS. HTTP is permitted only for local loopback services. Authenticated redirects are rejected, and downloading a provider's returned image URL does not forward the API authorization header.

Your artwork prompt and optional reference image are sent to the image provider you select. Improve Prompt sends your written brief to the chosen Claude connection. Magdobe does not fall back to a different provider after a failure. Source images and artwork job files remain on your Mac in the application's Artwork folder; conversion into editable paths runs locally.

A provider can reject a prompt, enforce a usage limit, or return no image. Magdobe reports these outcomes without treating every failure as missing account access. It does not bypass provider safeguards. Rebuild Last Image and Vectorize an Existing Image request no new AI image.

## Compatibility

OpenAI uses its Images generation/edit endpoints. Gemini's current Nano Banana model uses the Interactions API, with older model IDs supported through GenerateContent. OpenRouter uses its image endpoint and accepts the documented image response formats. Compatible services must support the OpenAI Images API response contract. PNG is imported directly; JPEG/WebP outputs are normalized with macOS image utilities before tracing. Native SVG/model-specific vector output is not imported through these image adapters.

Current reference documentation: [OpenAI Images](https://developers.openai.com/api/reference/resources/images/methods/generate), [Gemini image generation](https://aistudio.google.com/docs/image-generation), [OpenRouter image generation](https://openrouter.ai/docs/guides/overview/multimodal/image-generation), and [Claude Messages](https://platform.claude.com/docs/en/api/messages/create). Provider model availability and account requirements can change; use a model accessible to your own account.

## Validation

The final local suites passed **69 native tests** and **43 Python tests**. Provider tests cover saved settings, Keychain boundaries through injected stores, endpoint validation, credential routing, HTTP request and response shapes, reference images, rejected redirects, key redaction, malformed image data, and preserving an existing source on failure. Offline CLI tests verify standard-input prompts, restricted tools/MCP/settings, auth-only connection checks, missing CLI errors, and separate prompt suggestions.

Native UI testing used a local fixture image API with a temporary dummy Keychain entry and produced **3,835 editable objects**. A fixture Claude Messages response completed **Improve Prompt → Review Prompt → Use This Prompt**. The dummy keys were removed afterward. These were local integration checks, not live tests of billed provider accounts.

Codex was exercised through the signed-in app-server with successful image generation and a separate actual safety rejection. Keyed OpenAI, Gemini, OpenRouter, compatible, and Claude API adapters were validated with mocked or local fixture responses; live account/model access was not verified. Claude Code was not installed in the development environment, so its live CLI authentication and prompt request were not verified.

The optimized application build passed. This release adds provider configuration to the source-built app. It does not add a notarized installer, claim a verified public binary download, or establish Adobe Illustrator interoperability.
