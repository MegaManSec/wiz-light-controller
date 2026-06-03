import js from '@eslint/js';
import globals from 'globals';
import prettier from 'eslint-config-prettier';

/** Flat config shared across the workspace. */
export default [
  {
    ignores: [
      '**/node_modules/**',
      '**/dist/**',
      '**/out/**',
      '**/release/**',
      'apps/**',
      'legacy/**',
      'pnpm-lock.yaml',
    ],
  },
  js.configs.recommended,
  {
    languageOptions: {
      ecmaVersion: 'latest',
      sourceType: 'module',
    },
    rules: {
      eqeqeq: ['error', 'always', { null: 'ignore' }],
      'no-var': 'error',
      'prefer-const': 'error',
      'no-unused-vars': ['error', { argsIgnorePattern: '^_', varsIgnorePattern: '^_' }],
      'no-console': 'off',
    },
  },
  // Everything lintable is Node ESM: the engine, the CLI, and repo scripts.
  {
    files: ['packages/**/*.js', '**/*.config.{js,mjs}', 'scripts/**/*.{js,mjs}'],
    languageOptions: { globals: { ...globals.node } },
  },
  prettier,
];
