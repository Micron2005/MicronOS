# Bring your own assistant

Micron OS is an operating system. It ships with NO assistant. Whoever you
install -- Alfred, or one you wrote yourself -- plugs into one published
socket, and the OS hosts it.

## The whole contract

1. Implement `assistant_api.AssistantProvider` (see that file: `name`,
   `chat` required; `status`, actions, speech optional -- the OS degrades
   those surfaces honestly if you skip them).
2. Expose `create_provider(loop)` in your module.
3. Name your module in `configs/micron.toml`:

       [assistant]
       module = "yourai.provider"
       path = "~/YourAI"        # where your code lives

4. `sudo systemctl restart micronos@$USER` -- the OS hosts YOUR assistant:
   your name in the bar, your replies in the window.

No assistant configured or found: Micron OS runs standalone, completely.

Alfred is the reference implementation (`alfred/provider.py` in his own
repository, installed by HIS installer, never by the OS).

## Verified

Tested three ways: no assistant (standalone, honest 503 on chat); Alfred as
provider; and a 25-line third-party dummy assistant -- the OS hosted it
without containing one line of its code.
