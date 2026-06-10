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
wiz color [ip] <#rrggbb | r g b>   set an RGB colour
wiz temp [ip] <kelvin>             set white temperature
wiz brightness [ip] <0-100>        set brightness
wiz presets                        list the saved presets
wiz preset [ip] <name>             apply a preset
wiz scenes [ip]                    list the bulb's dynamic scenes
wiz scene [ip] <name|id>           run a dynamic scene
wiz lights                         list saved lights
wiz save [ip] <name>               save the current light under a name
```

A leading `[ip]` is optional everywhere and falls back to the last-used bulb. Run `wiz --help`, or `wiz <command> --help`, for details.

## Example

```bash
wiz discover
wiz color 192.168.1.50 "#ff0080"
wiz temp 2700
wiz brightness 60
wiz scene party --speed 120
```
