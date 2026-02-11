# Fish Market

This is a WIP Elixir/Phoenix application acting as a front-end to OpenClaw.

## Configuration

The application should be run with the following envars:

- `OPENCLAW_GATEWAY_URL`
- `OPENCLAW_GATEWAY_TOKEN` or `OPENCLAW_GATEWAY_PASSWORD`

The application should be hosted behind Cloudflare Zero Trust, as there is no authentication support currently.

## TODO

- Linking
- Packaging via Mix Release and testing with systemd unit, etc
- More Session Management stuff
- Refinement
