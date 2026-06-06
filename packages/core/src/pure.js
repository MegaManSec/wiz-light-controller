// Browser/JavaScriptCore-safe surface of the engine: only the pure, Node-free
// modules. Bundled by `scripts/build-jscore.mjs` into an IIFE (global `WizCore`)
// that the macOS app loads into a JSContext — the single, tested source of
// truth for colour maths and the light-state model, shared with the CLI.

export * from './color.js';
export * from './validate.js';
export * from './model.js';
export * from './scenes.js';
