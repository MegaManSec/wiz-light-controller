# wiz-light-cli

The `wiz` command-line interface for [WiZ Light Controller](../../README.md) — control Philips WiZ bulbs over the LAN from your terminal. Dependency-free, built on the [`wiz-light-core`](../core/README.md) engine.

## Install

```bash
pnpm add -g wiz-light-cli      # or, from a checkout: pnpm --filter wiz-light-cli start -- <command>
```

Requires Node 24+.

## Usage

```
wiz discover                       find WiZ bulbs on your LAN
wiz status [ip]                    show a bulb's current state
wiz on [ip]                        turn a bulb on
wiz off [ip]                       turn a bulb off
wiz color <#rrggbb | r g b> [ip]   set an RGB colour
wiz temp <kelvin> [ip]             set white temperature
wiz brightness <0-100> [ip]        set brightness
wiz presets                        list the saved presets
wiz preset <name> [ip]             apply a preset
wiz lights                         list saved lights
wiz save <name> [ip]               save the current light under a name
```

`[ip]` is optional and falls back to the last-used bulb. Run `wiz --help`, or `wiz <command> --help`, for details.

## Example

```bash
wiz discover
wiz color "#ff0080" 192.168.1.50
wiz temp 2700
wiz brightness 60
```
