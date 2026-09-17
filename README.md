# planeai.nvim

Queue selected Neovim code as feedback and send it to the PlaneAI session that launched Neovim.

## Requirements

- Neovim 0.10 or later
- `planeai-cli` on `PATH` (use PlaneAI’s **Install CLI** action)
- Neovim launched by PlaneAI with its session context

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "nicolegros/planeai.nvim",
  opts = {},
}
```

The plugin has no runtime dependencies and defines no keymaps. Add mappings that fit your configuration.

## PlaneAI configuration

PlaneAI uses its Neovim preset to provide `g:planeai_session_id`. For custom editor settings, configure Neovim with the generic `{session_id}` launch template:

```jsonc
{
  "editor": {
    "mode": "terminal",
    "command": "nvim",
    "args": [
      "--cmd",
      "let g:planeai_session_id = '{session_id}'",
      "{file}"
    ]
  }
}
```

`{session_id}` is supplied by PlaneAI for editor arguments. The plugin remains inert when this context is unavailable, so it is safe to include in a shared Neovim setup.

## Commands

- `:PlaneAIAddFeedback` — in characterwise or linewise visual mode, prompt for a comment and queue the selected code.
- `:PlaneAIFeedback` — inspect queued feedback and edit or remove an item.
- `:PlaneAISendFeedback` — asynchronously send all queued feedback to PlaneAI.
- `:PlaneAIClearFeedback` — discard all queued feedback.

The queue belongs to the current Neovim process and is discarded when Neovim exits. A selection is limited to 200 lines or 12 KiB. Each queued note includes the file and selected line range, language, up to two surrounding lines of context, and whether the buffer has unsaved changes.

Delivery runs `planeai-cli session prompt <session-id> <text>`, which uses PlaneAI’s backend-aware delivery and session prompt lock. A failed delivery—including a busy lock—keeps the queue intact for retry. To use a nonstandard executable location:

```lua
require("planeai").setup({ cli_path = "/custom/path/planeai-cli" })
```

## Development

Run the dependency-free headless test suite:

```sh
make test
```

## License

AGPL-3.0-or-later. See [LICENSE](LICENSE).
