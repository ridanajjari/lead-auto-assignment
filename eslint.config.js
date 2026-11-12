const { defineConfig } = require('eslint/config');
const eslintJs = require('@eslint/js');
const globals = require('globals');

// The standard Salesforce template lints Aura/LWC sources. This repo has no
// Aura or LWC code yet, so only plain JavaScript (tooling files) is linted.
module.exports = defineConfig([
    {
        ignores: ['node_modules/**', '.sf/**', '.sfdx/**', 'coverage/**']
    },
    {
        files: ['**/*.js'],
        languageOptions: {
            sourceType: 'commonjs',
            ecmaVersion: 'latest',
            globals: {
                ...globals.node
            }
        },
        plugins: {
            eslintJs
        },
        extends: ['eslintJs/recommended']
    }
]);
