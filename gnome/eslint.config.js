import js from '@eslint/js';

export default [
    {
        ignores: ['**/node_modules/**'],
    },
    js.configs.recommended,
    {
        files: ['gnome/extension/**/*.js', 'gnome/scripts/**/*.js', 'gnome/tests/**/*.js'],
        languageOptions: {
            ecmaVersion: 'latest',
            sourceType: 'module',
            globals: {
                ARGV: 'readonly',
                print: 'readonly',
            },
        },
        rules: {
            'no-unused-vars': ['error', {argsIgnorePattern: '^_'}],
        },
    },
];
